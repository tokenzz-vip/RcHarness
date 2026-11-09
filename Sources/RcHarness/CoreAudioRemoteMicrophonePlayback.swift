import AVFoundation
import AudioExceptionGuard
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Custom property understood by Drivers/RcHarnessMicrophone (`FlushProperty`
/// in Driver.c). Setting it discards audio already written to the loopback.
enum RcHarnessMicrophoneProtocol {
    static let flushProperty: AudioObjectPropertySelector = 0x6a68666c // 'jhfl'
}

/// AVAudioEngine playback into the selected loopback device. All engine work
/// runs on `engineQueue`; callbacks are delivered on the main queue.
final class CoreAudioRemoteMicrophonePlayback: RemoteMicrophonePlayback {
    private let engineQueue = DispatchQueue(label: "vip.tokenzz.rcharness.audio-output")
    private let outputUID: String
    private var selectedDevice: AudioDeviceID?
    private var usesOwnDriver = false
    private let makeEngine: @Sendable () throws -> AVAudioEngine
    // Construct and release AVFoundation objects only on engineQueue. Even
    // AVAudioEngine.init can block during the first CoreAudio connection.
    private var engine: AVAudioEngine!
    private var player: AVAudioPlayerNode!
    private var format: AVAudioFormat!
    private var configurationObserver: NSObjectProtocol?
    private var started = false
    /// Checked by pending startup work so cancellation can return immediately.
    private let stopRequested = OSAllocatedUnfairLock(initialState: false)
    private let graphStarted = OSAllocatedUnfairLock(initialState: false)
    var onInterruption: (() -> Void)?
    var isInterrupted: Bool {
        guard graphStarted.withLock({ $0 }) else { return false }
        return engineQueue.sync { started && !healthy }
    }
    var isReady: Bool {
        guard graphStarted.withLock({ $0 }) else { return false }
        return engineQueue.sync { healthy }
    }

    init(outputUID: String, makeEngine: @escaping @Sendable () throws -> AVAudioEngine = { AVAudioEngine() }) throws {
        self.outputUID = outputUID
        self.makeEngine = makeEngine
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    private var isStopRequested: Bool { stopRequested.withLock { $0 } }

    func prepare(completion: @escaping (Result<Void, Error>) -> Void) {
        engineQueue.async { [self] in
            guard !isStopRequested else { return }
            do {
                let createdEngine = try makeEngine()
                guard !isStopRequested else { return }
                engine = createdEngine
                player = AVAudioPlayerNode()
                format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                configurationObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: createdEngine, queue: nil
                ) { [weak self] _ in
                    // Do not query the engine queue while it is still preparing.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isInterrupted else { return }
                        self.onInterruption?()
                    }
                }
                try selectOutputDevice()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                // AUHAL dispatches format changes after selecting a device.
                // Yield this queue so they can settle before starting the graph.
                engineQueue.asyncAfter(deadline: .now() + 0.1) { [self] in
                    guard !isStopRequested else { return }
                    let result = Result { try start() }
                    DispatchQueue.main.async { completion(result) }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private var healthy: Bool {
        guard started, engine.isRunning, player.isPlaying,
              let selectedDevice, let unit = engine.outputNode.audioUnit else { return false }
        var actualDevice: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &actualDevice, &size) == noErr && actualDevice == selectedDevice
    }

    func checkHealth(completion: @escaping (Bool) -> Void) {
        engineQueue.async { [self] in
            let result = healthy
            DispatchQueue.main.async { completion(result) }
        }
    }

    func start() throws {
        try RemoteMicrophoneOutput.requireRecordingAuthorization()
        engine.prepare()
        try engine.start()
        guard RCAudioTryPlay(player) else {
            engine.stop()
            throw RemoteMicrophoneOutput.outputError("遥控器音频播放图启动失败，请刷新音频设备后重试。")
        }
        guard !isStopRequested else {
            player.stop()
            engine.stop()
            return
        }
        started = true
        graphStarted.withLock { $0 = true }
    }

    private func selectOutputDevice() throws {
        // Permission can be revoked after the engine was prepared, so recovery
        // must also fail before accessing the HAL output unit.
        try RemoteMicrophoneOutput.requireRecordingAuthorization()
        guard let device = AudioDeviceCatalog.shared.device(uid: outputUID), device.isLoopback else {
            throw RemoteMicrophoneOutput.outputError("所选回环音频设备不可用，请在连接与语音中选择兼容麦克风。")
        }
        guard let unit = engine.outputNode.audioUnit else { throw RemoteMicrophoneOutput.outputError("音频输出不可用") }
        var deviceID = device.id
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else { throw RemoteMicrophoneOutput.outputError("无法打开 RcHarness 麦克风（\(result)）") }
        selectedDevice = device.id
        usesOwnDriver = outputUID == RemoteMicrophoneOutput.deviceUID
    }

    func schedule(_ pcm: [Int16], completion: @escaping () -> Void) -> Bool {
        guard graphStarted.withLock({ $0 }) else { return false }
        return engineQueue.sync {
            guard healthy,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)),
                  let samples = buffer.floatChannelData?[0] else { return false }
            buffer.frameLength = AVAudioFrameCount(pcm.count)
            for (index, value) in pcm.enumerated() { samples[index] = Float(value) / 32768 }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
            return true
        }
    }

    func stop() {
        stopRequested.withLock { $0 = true }
        let wasStarted = graphStarted.withLock { value in
            let previous = value
            value = false
            return previous
        }
        // Cancellation must not wait on a cold engine constructor. Its queued
        // work observes stopRequested and cannot re-open a cancelled session.
        let cleanup = { [self] in
            started = false
            player?.stop()
            engine?.stop()
            // A preparing graph has never scheduled audio. Do not let its
            // delayed teardown flush audio belonging to a newer graph.
            if wasStarted {
                do { try flushOnEngineQueue() }
                catch { AudioDiagnostics.log("[RcHarness] Xiaomi voice output stop flush failure=\(error.localizedDescription)") }
            }
            if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
            configurationObserver = nil
            player = nil
            engine = nil
            format = nil
        }
        if wasStarted { engineQueue.sync(execute: cleanup) }
        else { engineQueue.async(execute: cleanup) }
    }

    func flush() throws {
        guard graphStarted.withLock({ $0 }), !isStopRequested else { return }
        try engineQueue.sync { try flushOnEngineQueue() }
    }

    private func flushOnEngineQueue() throws {
        guard usesOwnDriver, let selectedDevice else { return }
        // Match the HAL's CFPropertyList contract; raw integers are rejected.
        var address = AudioObjectPropertyAddress(mSelector: RcHarnessMicrophoneProtocol.flushProperty,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(selectedDevice, &address) else { return }
        let token = NSNumber(value: 0)
        var reference = Unmanaged.passUnretained(token).toOpaque()
        let result = withExtendedLifetime(token) {
            AudioObjectSetPropertyData(selectedDevice, &address, 0, nil,
                UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &reference)
        }
        guard result == noErr else { throw RemoteMicrophoneOutput.outputError("无法清空遥控器音频（\(result)）") }
    }
}
