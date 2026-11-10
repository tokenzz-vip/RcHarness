import Foundation
import IOKit.hid

struct XiaomiRemoteParsedEvent: Equatable {
    let input: ControllerInput
    let isPressed: Bool
}

/// Scalar usages are shared by parsing and native-key suppression. Hat reports
/// carry several directions and have their own stateful decoding below.
enum RemoteHIDUsages {
    struct Binding {
        let page: UInt32
        let usage: UInt32
        let input: ControllerInput
        var source: UInt64 { UInt64(page) << 32 | UInt64(usage) }
    }

    static let xiaomi: [Binding] = bindings(page: 0x01, [
        (0x81, .power), (0x84, .menu), (0x86, .menu), (0x88, .buttonB), (0x89, .buttonA),
        (0x90, .dpadUp), (0x91, .dpadDown), (0x92, .dpadRight), (0x93, .dpadLeft), (0x85, .home)
    ]) + bindings(page: 0x0C, [
        (0x30, .power), (0x40, .menu), (0x41, .buttonA), (0xCD, .buttonA), (0x42, .buttonB),
        (0x224, .buttonB), (0x223, .home), (0xCF, .options), (0xE9, .rightShoulder), (0xEA, .leftShoulder),
        (0x194, .buttonY), (0x80, .buttonY), (0x6F, .buttonY)
    ]) + bindings(page: 0x07, [
        (0x66, .power), (0x52, .dpadUp), (0x51, .dpadDown), (0x50, .dpadLeft), (0x4F, .dpadRight),
        (0x28, .buttonA), (0x29, .buttonB), (0x2A, .buttonB), (0xF1, .buttonB), (0x65, .menu),
        (0x81, .leftShoulder), (0x80, .rightShoulder), (0x35, .buttonY), (0x4A, .home), (0x3E, .options)
    ]) + bindings(page: 0x09, [(1, .buttonA), (2, .buttonB), (3, .options), (4, .buttonY)])

    static let google: [Binding] = bindings(page: 0x0C, [
        (0x41, .buttonA), (0x42, .dpadUp), (0x43, .dpadDown), (0x44, .dpadLeft), (0x45, .dpadRight),
        (0x224, .buttonB), (0x223, .home), (0xE9, .rightShoulder), (0xEA, .leftShoulder), (0xE2, .mute),
        (0x19E, .power), (0x89, .inputSource), (0x189, .inputSource),
        (0x77, .youtube), (0x78, .netflix)
    ])

    static func bindings(for profile: RemoteProfile) -> [Binding] {
        let candidates: [Binding]
        switch profile.adapter {
        case .xiaomi: candidates = xiaomi
        case .chromecast: candidates = google
        }
        return candidates.filter { profile.inputs.contains($0.input) }
    }

    private static func bindings(page: UInt32, _ entries: [(UInt32, ControllerInput)]) -> [Binding] {
        entries.map { Binding(page: page, usage: $0.0, input: $0.1) }
    }
}

final class XiaomiRemoteHIDParser {
    private let profile: RemoteProfile
    private let bindings: [UInt64: ControllerInput]
    private var active: [UInt64: Set<ControllerInput>] = [:]

    init(profile: RemoteProfile = RemoteProfiles.xiaomiRC003) {
        self.profile = profile
        bindings = Dictionary(uniqueKeysWithValues: RemoteHIDUsages.bindings(for: profile).map { ($0.source, $0.input) })
    }

    func parse(usagePage: UInt32, usage: UInt32, value: Int) -> [XiaomiRemoteParsedEvent] {
        let source = UInt64(usagePage) << 32 | UInt64(usage)
        if profile.adapter == .xiaomi, usagePage == 0x01, usage == 0x39 {
            let directions: [[ControllerInput]] = [
                [.dpadUp], [.dpadUp, .dpadRight], [.dpadRight], [.dpadDown, .dpadRight],
                [.dpadDown], [.dpadDown, .dpadLeft], [.dpadLeft], [.dpadUp, .dpadLeft]
            ]
            let previous = Set(active.values.flatMap { $0 })
            active[source] = directions.indices.contains(value) ? Set(directions[value]) : []
            let next = Set(active.values.flatMap { $0 })
            return ordered(previous.subtracting(next)).map { .init(input: $0, isPressed: false) }
                + ordered(next.subtracting(previous)).map { .init(input: $0, isPressed: true) }
        }
        guard let input = bindings[source] else { return [] }
        if value != 0 {
            active[source] = [input]
            return [.init(input: input, isPressed: true)]
        }
        active.removeValue(forKey: source)
        // Firmware can report the same physical key through multiple aliases.
        // A release on one usage must not release another active usage.
        guard !active.values.contains(where: { $0.contains(input) }) else { return [] }
        return [.init(input: input, isPressed: false)]
    }

    func reset() -> [XiaomiRemoteParsedEvent] {
        let events = ordered(Set(active.values.flatMap { $0 })).map { XiaomiRemoteParsedEvent(input: $0, isPressed: false) }
        active.removeAll()
        return events
    }

    private func ordered(_ inputs: Set<ControllerInput>) -> [ControllerInput] {
        inputs.sorted { $0.rawValue < $1.rawValue }
    }
}

/// Aggregate ownership at the device boundary. A duplicated down, stale up or
/// removal of one device cannot release the same input held by another device.
struct RemoteInputState<Source: Hashable> {
    private var inputs: [Source: Set<ControllerInput>] = [:]

    mutating func update(_ event: XiaomiRemoteParsedEvent, source: Source) -> XiaomiRemoteParsedEvent? {
        let wasPressed = inputs.values.contains { $0.contains(event.input) }
        if event.isPressed { inputs[source, default: []].insert(event.input) }
        else { inputs[source]?.remove(event.input) }
        let isPressed = inputs.values.contains { $0.contains(event.input) }
        return wasPressed == isPressed ? nil : .init(input: event.input, isPressed: isPressed)
    }

    mutating func remove(_ source: Source) -> [ControllerInput] {
        let removed = inputs.removeValue(forKey: source) ?? []
        return removed.filter { input in !inputs.values.contains { $0.contains(input) } }
            .sorted { $0.rawValue < $1.rawValue }
    }

    mutating func reset() { inputs.removeAll() }
}

@MainActor
final class XiaomiRemoteHIDManager {
    private let traceInputs = ProcessInfo.processInfo.environment["RC_HARNESS_REMOTE_TRACE"] == "1"
    private let profiles: [RemoteProfile]
    private var manager: IOHIDManager?
    private var parsers: [ObjectIdentifier: XiaomiRemoteHIDParser] = [:]
    private(set) var isConnected = false
    private(set) var connectedProfileIDs: Set<String> = []
    private var connectedDevices: Set<ObjectIdentifier> = []
    private var inputState = RemoteInputState<ObjectIdentifier>()
    private var modelNumber: String?
    private let volumeGuard: any RemoteVolumeGuarding
    private var operationMode: ControllerOperationMode = .mapping

    init(profiles: [RemoteProfile] = RemoteProfiles.all,
         volumeGuard: (any RemoteVolumeGuarding)? = nil,
         makeVolumeGuard: @MainActor ([RemoteProfile]) -> any RemoteVolumeGuarding = { RemoteVolumeGuard(profiles: $0) }) {
        self.profiles = profiles
        // Native HID keys must stay suppressed while mapping mode is active,
        // even before the selected profile has confirmed the remote model.
        // Use each physical device's model for full suppression; inactive
        // Xiaomi devices receive only system voice-key protection.
        self.volumeGuard = volumeGuard ?? makeVolumeGuard(profiles)
    }

    func setOperationMode(_ mode: ControllerOperationMode) {
        operationMode = mode
        volumeGuard.update(mapping: mode == .mapping)
    }

    var onConnectionChange: ((Bool) -> Void)?
    var onProfileConnectionsChange: ((Set<String>) -> Void)?
    var onButtonInput: ((ControllerInput, Bool) -> Void)?
    var onButtonCancelled: ((ControllerInput) -> Void)?
    var onSuppressionFailure: ((String) -> Void)? {
        didSet { volumeGuard.onFailure = onSuppressionFailure }
    }

    func updateModelNumber(_ modelNumber: String?) {
        guard self.modelNumber != modelNumber else { return }
        self.modelNumber = modelNumber
        refreshDevices()
    }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Observe every supported model for menu presence. Only the selected
        // profiles may own input; the guard also protects inactive voice keys.
        let observedProfiles = presenceProfiles
        let matching = observedProfiles.flatMap(\.hidMatching)
        guard !matching.isEmpty else { return }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, xiaomiRemoteDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, xiaomiRemoteDeviceRemoved, context)
        IOHIDManagerRegisterInputValueCallback(manager, xiaomiRemoteInputValueChanged, context)
        if traceInputs {
            IOHIDManagerRegisterInputReportCallback(manager, xiaomiRemoteInputReportReceived, context)
        }

        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        // Monitor this keyboard/consumer device using Input Monitoring consent.
        // Seizing it can fail with kIOReturnNotPrivileged even after consent.
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            let code = String(format: "0x%08x", UInt32(bitPattern: result))
            Log.hid.error("HID manager open failed: \(result) (\(code, privacy: .public))")
            return
        }

        self.manager = manager
        volumeGuard.update(mapping: operationMode == .mapping)
        // IOHIDManager may not replay a matching callback for devices that were
        // already connected before the manager was opened. Register those
        // devices explicitly so launch order does not affect detection.
        refreshDevices()
        Log.hid.info("HID discovery started")
    }

    func stop() {
        volumeGuard.stop()
        closeManager()
    }

    /// Reopen HID discovery without restarting the suppression guard. The
    /// guard restores and reapplies mappings through several `hidutil` calls;
    /// recycling it here would make every rescan slow and churn system state.
    func rescan() {
        closeManager()
        start()
        if operationMode == .native { volumeGuard.update(mapping: false) }
    }

    private func closeManager() {
        guard let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        updateConnectedProfiles([])
        connectedDevices.removeAll()
        inputState.reset()
        parsers.removeAll()
        if isConnected {
            isConnected = false
            onConnectionChange?(false)
        }
    }

    fileprivate func deviceMatched(_ device: IOHIDDevice) {
        refreshDevices()
    }

    private func refreshDevices() {
        guard let manager else { return }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        let snapshot = devices.map { device in
            RemoteHIDPresence.Device(
                vendorID: (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue,
                productID: (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue,
                name: IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String,
                modelNumber: RemoteHIDIdentity.modelNumber(entry: IOHIDDeviceGetService(device)),
                physicalID: (IOHIDDeviceGetProperty(device, "PhysicalDeviceUniqueID" as CFString) as? String)
                    ?? (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.stringValue
                    ?? String(describing: ObjectIdentifier(device)))
        }
        updateConnectedProfiles(RemoteHIDPresence.connectedProfiles(devices: snapshot, profiles: presenceProfiles,
                                                                   confirmedModelNumber: modelNumber))
        for device in devices { updateDevice(device, candidates: devices) }
        volumeGuard.update(mapping: operationMode == .mapping)
    }

    private var presenceProfiles: [RemoteProfile] {
        profiles + RemoteProfiles.all.filter { candidate in !profiles.contains { $0.id == candidate.id } }
    }

    private func updateConnectedProfiles(_ ids: Set<String>) {
        guard connectedProfileIDs != ids else { return }
        connectedProfileIDs = ids
        onProfileConnectionsChange?(ids)
    }

    private func updateDevice(_ device: IOHIDDevice, candidates: Set<IOHIDDevice>) {
        let id = ObjectIdentifier(device)
        let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        let deviceModel = RemoteHIDIdentity.modelNumber(entry: IOHIDDeviceGetService(device))
        let physicalCandidates = Set(candidates.filter {
            (IOHIDDeviceGetProperty($0, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue == vendor
                && (IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue == product
        }.map {
            (IOHIDDeviceGetProperty($0, "PhysicalDeviceUniqueID" as CFString) as? String)
                ?? (IOHIDDeviceGetProperty($0, kIOHIDLocationIDKey as CFString) as? NSNumber)?.stringValue
                ?? String(describing: ObjectIdentifier($0))
        })
        guard let profile = profiles.first(where: {
            $0.matchesHIDDevice(vendorID: vendor, productID: product, name: name,
                                confirmedModelNumber: modelNumber, deviceModelNumber: deviceModel,
                                isOnlyCandidate: physicalCandidates.count == 1)
        }) else {
            removeDevice(device)
            return
        }
        guard connectedDevices.insert(id).inserted else { return }
        parsers[id] = XiaomiRemoteHIDParser(profile: profile)
        Log.hid.info("Remote HID accepted model=\(deviceModel ?? "BLE confirmed", privacy: .public) profile=\(profile.id, privacy: .public)")
        volumeGuard.update(mapping: operationMode == .mapping)
        // The guard keeps retrying until the corresponding event service is ready.
        if !isConnected {
            isConnected = true
            Log.hid.info("Remote connected")
            onConnectionChange?(true)
        }
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        removeDevice(device)
        refreshDevices()
    }

    private func removeDevice(_ device: IOHIDDevice) {
        let id = ObjectIdentifier(device)
        _ = parsers.removeValue(forKey: id)?.reset()
        connectedDevices.remove(id)
        for input in inputState.remove(id) {
            onButtonCancelled?(input)
            onButtonInput?(input, false)
        }
        if connectedDevices.isEmpty && isConnected {
            // Keep native keys consumed while mapping mode is active. A
            // disconnected or mismatched shared Xiaomi HID device can still
            // emit the system voice shortcut before BLE identity settles.
            volumeGuard.update(mapping: operationMode == .mapping)
            isConnected = false
            Log.hid.info("Remote disconnected")
            onConnectionChange?(false)
        }
    }

    fileprivate func handleValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intVal = IOHIDValueGetIntegerValue(value)

        let device = IOHIDElementGetDevice(element)
        guard let parser = parsers[ObjectIdentifier(device)] else { return }
        let events = parser.parse(usagePage: usagePage, usage: usage, value: intVal)
        // Keyboard array payloads and rollover elements duplicate the individual
        // key values. Keep diagnostics focused on actual button usages.
        if traceInputs && usage != UInt32.max && !(usagePage == 0x07 && usage <= 0x03) {
            let usageDescription = String(format: "page=0x%02x usage=0x%02x", usagePage, usage)
            let mappedInputs = events.map { "\($0.input.rawValue):\($0.isPressed ? "down" : "up")" }.joined(separator: ",")
            Log.hid.notice("\(usageDescription, privacy: .public) value=\(intVal) mapped=\(mappedInputs, privacy: .public)")
        }
        for event in events {
            if let edge = inputState.update(event, source: ObjectIdentifier(device)) {
                onButtonInput?(edge.input, edge.isPressed)
            }
        }
    }
}

private func xiaomiRemoteDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    // The manager is scheduled on the main run loop, so callbacks arrive on the main thread.
    MainActor.assumeIsolated {
        let manager = Unmanaged<XiaomiRemoteHIDManager>.fromOpaque(context).takeUnretainedValue()
        manager.deviceMatched(device)
    }
}

private func xiaomiRemoteDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    // The manager is scheduled on the main run loop, so callbacks arrive on the main thread.
    MainActor.assumeIsolated {
        let manager = Unmanaged<XiaomiRemoteHIDManager>.fromOpaque(context).takeUnretainedValue()
        manager.deviceRemoved(device)
    }
}

private func xiaomiRemoteInputValueChanged(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    // The manager is scheduled on the main run loop, so callbacks arrive on the main thread.
    MainActor.assumeIsolated {
        let manager = Unmanaged<XiaomiRemoteHIDManager>.fromOpaque(context).takeUnretainedValue()
        manager.handleValue(value)
    }
}

private func xiaomiRemoteInputReportReceived(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard result == kIOReturnSuccess, reportLength > 0 else { return }
    let prefix = UnsafeBufferPointer(start: report, count: min(reportLength, 16))
        .map { String(format: "%02x", $0) }.joined(separator: " ")
    Log.hid.notice("report id=\(reportID) length=\(reportLength) prefix=\(prefix, privacy: .public)")
}
