import CoreAudio
import Foundation

extension Notification.Name {
    /// Posted on the main queue after the CoreAudio device list changes.
    static let rcHarnessAudioDevicesChanged = Notification.Name("vip.tokenzz.rcharness.audioDevicesChanged")
}

struct RemoteAudioDevice: Identifiable, Equatable {
    let id: String
    let name: String

    static func isLoopbackCandidate(uid: String, transport: UInt32, hasInput: Bool, hasOutput: Bool) -> Bool {
        let knownLoopback = [RemoteMicrophoneOutput.deviceUID, "MiRemoteV2ch_UID"].contains(uid)
        return hasInput && hasOutput && (knownLoopback || transport == kAudioDeviceTransportTypeVirtual)
    }
}

/// Cached snapshot of CoreAudio devices. Enumerating devices costs several
/// HAL calls per device, while the list changes rarely; the cache is dropped
/// whenever the HAL reports a device-list change. Thread-safe: playback reads
/// it from its engine queue, the UI from the main queue.
final class AudioDeviceCatalog: @unchecked Sendable {
    struct Device: Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let isLoopback: Bool
    }

    static let shared = AudioDeviceCatalog()

    private let lock = NSLock()
    private var cached: [Device]?
    private var loading = false
    private let listenerQueue = DispatchQueue(label: "vip.tokenzz.rcharness.audio-devices")

    private init() {
        // HAL listener registration can synchronously contact coreaudiod. Do
        // it off the launch thread so a stalled audio service cannot prevent
        // the application from opening.
        listenerQueue.async { [weak self] in
            guard let self else { return }
            var address = Self.devicesAddress
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, self.listenerQueue) { [weak self] _, _ in
                self?.invalidate()
                DispatchQueue.main.async { NotificationCenter.default.post(name: .rcHarnessAudioDevicesChanged, object: nil) }
            }
            if status != noErr { Log.audio.error("Audio device listener unavailable: \(status)") }
        }
    }

    func devices() -> [Device] {
        AudioPerformance.measure("Catalog.devices") {
            lock.lock()
            if let cached {
                lock.unlock()
                return cached
            }
            let shouldLoadAsync = Thread.isMainThread && !loading
            if shouldLoadAsync { loading = true }
            lock.unlock()

            if Thread.isMainThread {
                if shouldLoadAsync {
                    listenerQueue.async { [weak self] in self?.loadSnapshot() }
                }
                return []
            }

            let devices = AudioPerformance.measure("Catalog.enumerate") { Self.enumerate() }
            lock.lock()
            cached = devices
            loading = false
            lock.unlock()
            return devices
        }
    }

    private func loadSnapshot() {
        let devices = AudioPerformance.measure("Catalog.enumerate") { Self.enumerate() }
        lock.lock()
        cached = devices
        loading = false
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .rcHarnessAudioDevicesChanged, object: nil) }
    }

    func device(uid: String) -> Device? { devices().first { $0.uid == uid } }

    /// User initiated refreshes must bypass the cached snapshot even when the
    /// HAL listener was unavailable or a third-party device missed a change
    /// notification.
    func reload() -> [Device] {
        invalidate()
        return devices()
    }

    func invalidate() {
        AudioPerformance.measure("Catalog.invalidate") {
            lock.lock()
            cached = nil
            lock.unlock()
        }
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func enumerate() -> [Device] {
        var address = devicesAddress
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = string(id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(id, selector: kAudioObjectPropertyName) ?? uid
            return Device(id: id, uid: uid, name: name, isLoopback: isLoopback(id, uid: uid))
        }
    }

    private static func string(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func isLoopback(_ device: AudioDeviceID, uid: String) -> Bool {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &transport) == noErr else { return false }
        func hasStream(_ scope: AudioObjectPropertyScope) -> Bool {
            var count: UInt32 = 0
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: scope, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &count) == noErr && count > 0
        }
        return RemoteAudioDevice.isLoopbackCandidate(uid: uid, transport: transport,
            hasInput: hasStream(kAudioDevicePropertyScopeInput), hasOutput: hasStream(kAudioDevicePropertyScopeOutput))
    }
}
