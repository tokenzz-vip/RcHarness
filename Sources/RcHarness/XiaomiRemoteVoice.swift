@preconcurrency import CoreBluetooth
import Foundation

enum RemoteVoiceStreamEvent {
    case started, ended, cancelled
}

/// Runs entirely on the main queue: CoreBluetooth delivers its delegate
/// callbacks there (`CBCentralManager(delegate:queue: .main)`).
@MainActor
final class XiaomiRemoteVoice: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private static let service = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    private static let transmit = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
    private static let audio = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
    private static let control = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")
    private static let information = CBUUID(string: "180A")
    private static let modelNumber = CBUUID(string: "2A24")
    private static let pnpID = CBUUID(string: "2A50")
    private static let battery = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private let profile: RemoteProfile
    private let defaults: UserDefaults
    private var central: CBCentralManager?
    private var remote: CBPeripheral?
    private var transmit: CBCharacteristic?
    private var notifications: Set<CBUUID> = []
    private var capabilities: RemoteVoiceCapabilities?
    private enum TapCapturePhase { case idle, opening, streaming, stopping }
    private var tapPhase: TapCapturePhase = .idle
    private var tapRevision = 0
    private struct TapPress {
        let session: UInt8
        let began: TimeInterval
        let wasOpen: Bool
        let accepted: Bool
    }
    private var tapPress: TapPress?
    private var tapHIDDown = false
    private var tapStartup: DispatchWorkItem?
    private var tapClose: DispatchWorkItem?
    private var tapExtend: DispatchWorkItem?
    private var tapHIDPress: DispatchWorkItem?
    private enum TapSource { case search, hid, native }
    private var lastTapSource: TapSource?
    private var lastTapAt = -Double.infinity
    private(set) var voiceMode: VoiceTriggerMode = .hold
    private var startReason: UInt8?
    private var stopReason: UInt8?
    private var identity: RemoteVoiceIdentity
    private var voiceButton = RemoteVoiceButtonState()
    private var requestedCapabilities = false
    private var wanted = false
    private var microphoneOpen = false
    private var remappedPressReleased = false
    private var sessionGate = RemoteVoiceSessionGate()
    private var implicitRestartBlocked = false
    private lazy var streamWatchdog = RemoteVoiceStreamWatchdog(schedule: schedule) { [weak self] reason in
        self?.expireStream(reason)
    }
    private var streamStartedAt: TimeInterval?
    private var firstPCMAt: TimeInterval?
    private var stream = RemoteVoiceStream()
    private var enhancer = RemoteVoiceEnhancer()
    var gainDB: Float = 0 { didSet { enhancer.setGainDB(gainDB) } }
    private let schedule: RemoteVoiceSessionController.Scheduler
    private let now: () -> TimeInterval
    private let commandWriter: (([UInt8]) -> Void)?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private let injectedConnection: RemoteVoiceConnectionController?
    private lazy var connection: RemoteVoiceConnectionController = {
        let controller = injectedConnection ?? RemoteVoiceConnectionController(profile: profile, defaults: defaults, transport: .init(
            retrieve: { [weak self] id in
                guard let self, let peripheral = self.central?.retrievePeripherals(withIdentifiers: [id]).first else { return false }
                self.peripherals[id] = peripheral
                return true
            },
            connected: { [weak self] in
                guard let self else { return [] }
                return (self.central?.retrieveConnectedPeripherals(withServices: [Self.service]) ?? []).map {
                    self.peripherals[$0.identifier] = $0
                    return .init(id: $0.identifier, name: $0.name)
                }
            },
            scan: { [weak self] in self?.central?.scanForPeripherals(withServices: [Self.service]) },
            stopScan: { [weak self] in self?.central?.stopScan() },
            connect: { [weak self] id in
                guard let self, let peripheral = self.peripherals[id] else { return }
                self.remote = peripheral
                peripheral.delegate = self
                self.central?.connect(peripheral)
            },
            disconnect: { [weak self] id in
                guard let self, let peripheral = self.peripherals.removeValue(forKey: id) else { return }
                peripheral.delegate = nil
                self.central?.cancelPeripheralConnection(peripheral)
            }), schedule: schedule, now: now)
        controller.onReset = { [weak self] in
            self?.remote?.delegate = nil
            self?.remote = nil
            self?.clearConnection()
        }
        controller.onStatus = { [weak self] in self?.report($0) }
        return controller
    }()
    var enabled = true {
        didSet { if !enabled { closeMicrophone() } }
    }
    var onStatus: (() -> Void)?
    var onSamples: (([Int16]) -> Void)?
    var onStreamEvent: ((RemoteVoiceStreamEvent) -> Void)?
    var onVoiceButtonInput: ((Bool) -> Void)?
    var onCaptureFailure: ((String) -> Void)?
    var canStartCapture: (() -> Bool)?
    private(set) var isReady = false
    private(set) var status = "遥控器麦克风未连接"
    private(set) var batteryLevel: Float?
    var detectedModelNumber: String? { identity.model }
    var identityRejected: Bool { identity.rejected }
    private var lastDetectedModelNumber: String?

    var diagnostics: String {
        "SelectedRemote=\(profile.id)\nDetectedModel=\(detectedModelNumber ?? "unknown")\nLastDetectedModel=\(lastDetectedModelNumber ?? "unknown")\nConnectionPhase=\(connection.phase)\nATVVFrameBytes=\(capabilities.map { String($0.frameBytes) } ?? "unknown")\nVoiceMode=\(voiceMode.rawValue)\nATVVInteractionModel=\(capabilities?.interactionModel.map { String($0) } ?? "unknown")\nATVVStartReason=\(startReason.map { String($0) } ?? "unknown")\nATVVStopReason=\(stopReason.map { String($0) } ?? "unknown")\nVoiceStatus=\(status)\nLastConnectionFailure=\(connection.lastFailure ?? "none")"
    }

    init(profile: RemoteProfile = RemoteProfiles.xiaomiRC003, defaults: UserDefaults = .standard,
         schedule: @escaping RemoteVoiceSessionController.Scheduler = RemoteVoiceSessionController.mainQueue,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         connection: RemoteVoiceConnectionController? = nil,
         commandWriter: (([UInt8]) -> Void)? = nil) {
        self.profile = profile
        self.identity = RemoteVoiceIdentity(profile: profile)
        self.defaults = defaults
        self.schedule = schedule
        self.now = now
        self.injectedConnection = connection
        self.commandWriter = commandWriter
        super.init()
    }

    func setVoiceMode(_ mode: VoiceTriggerMode) {
        let normalized: VoiceTriggerMode = profile.supportsVoiceTap ? mode : .hold
        guard voiceMode != normalized else { return }
        let restart = wanted
        if restart { stop() } else { closeMicrophone() }
        voiceMode = normalized
        if restart { start() }
    }

    private func report(_ text: String) {
        status = text
        AudioDiagnostics.log("[RcHarness] \(profile.model) voice: \(text)")
        onStatus?()
    }

    func start() {
        guard !wanted, profile.supportsBLEVoice else { return }
        wanted = true
        connection.start()
        report("正在连接遥控器麦克风")
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func stop() {
        wanted = false
        closeMicrophone()
        connection.stop()
        peripherals.removeAll()
        central?.delegate = nil
        central = nil
        clearConnection()
        report("遥控器麦克风未连接")
    }

    /// Stop an in-progress voice stream while keeping the BLE session alive.
    /// HID removal is transient on macOS, so tearing down the BLE central here
    /// would make the next button press depend on a full rediscovery.
    func cancelActiveStream() {
        closeMicrophone()
    }

    func prepareForPress(requestMicrophone: Bool = false) {
        sessionGate.prepareForPress()
        implicitRestartBlocked = false
        remappedPressReleased = false
        // A remapped physical key does not produce the firmware's START_SEARCH.
        // Use the same ATVV MIC_OPEN request as the normal handshake.
        if requestMicrophone { openMicrophone() }
    }

    func releaseRemappedPress() {
        remappedPressReleased = true
        if voiceMode == .tap {
            guard tapPhase == .opening || tapPhase == .streaming else { return }
            tapPhase = .stopping
            tapStartup?.cancel()
            tapExtend?.cancel()
            write([0x0D, stream.session ?? 0])
            microphoneOpen = false
            let revision = tapRevision
            // Missing STOP must not leave the target input method recording.
            tapClose = schedule(0.5) { [weak self] in
                guard let self, self.tapRevision == revision, self.tapPhase == .stopping else { return }
                self.sessionGate.stop(cancelled: true, at: self.now())
                self.implicitRestartBlocked = true
                self.finishStream(cancelled: false)
            }
            return
        }
        guard microphoneOpen else { return }
        write([0x0D, stream.session ?? 0])
        microphoneOpen = false
        // The remote's STOP notification completes the stream and preserves
        // trailing packets; the output controller bounds missing STOP replies.
    }

    /// BLE native START/STOP owns the gesture when available. HID-only
    /// devices complete their click on release; defer it to merge BLE reports.
    func receiveTapButton(pressed: Bool) {
        guard voiceMode == .tap, enabled, isReady else { return }
        if pressed { tapHIDDown = true; return }
        guard tapHIDDown else { return }
        tapHIDDown = false
        tapHIDPress?.cancel()
        let revision = tapRevision
        tapHIDPress = schedule(0.05) { [weak self] in
            guard let self, self.tapRevision == revision else { return }
            self.receiveTap(source: .hid)
        }
    }

    private func openMicrophone() {
        guard enabled, isReady, !microphoneOpen else { return }
        microphoneOpen = true
        // Both trigger modes feed a live virtual microphone. ATVV playback
        // mode preserves real-time delivery; capture mode may buffer audio.
        write([0x0C, 0x00])
    }

    private func clearConnection() {
        isReady = false
        transmit = nil
        notifications.removeAll()
        capabilities = nil
        identity = RemoteVoiceIdentity(profile: profile)
        requestedCapabilities = false
        microphoneOpen = false
        implicitRestartBlocked = false
        lastTapAt = -Double.infinity
        lastTapSource = nil
        startReason = nil
        stopReason = nil
        batteryLevel = nil
        finishStream(cancelled: true)
    }

    nonisolated static func matchesName(_ name: String?, profile: RemoteProfile = RemoteProfiles.xiaomiRC003) -> Bool {
        profile.matchesBluetoothName(name)
    }

    /// Also feeds HID identity: the Xiaomi models share their USB identifiers
    /// and localized names, so only this characteristic distinguishes them.
    func receiveModelNumber(_ model: String?) {
        identity.receiveModel(model)
        if let detectedModelNumber { lastDetectedModelNumber = detectedModelNumber }
        updateIdentity()
    }

    private func updateIdentity() {
        guard identity.confirmed else {
            if identity.rejected {
                let message = "检测到遥控器型号 \(detectedModelNumber ?? "未知")，与当前选择的 \(profile.model) 不符"
                if let peripheral = remote {
                    connection.rejected(peripheral.identifier, message: message)
                } else {
                    report(message)
                }
            } else {
                report("正在确认遥控器型号与 PnP 身份")
            }
            return
        }
        AudioDiagnostics.log("[RcHarness] Remote voice model=\(detectedModelNumber ?? "")")
        report("型号已确认，正在连接遥控器麦克风")
        initialize()
    }

    private func failConnection(_ message: String, peripheral: CBPeripheral) {
        connection.failed(peripheral.identifier, message: message)
    }

    func receiveCommandFailure(_ error: Error, peripheralID: UUID) {
        // Reset through the connection controller. Sending CLOSE on a failed
        // TX characteristic would create another failed-write callback.
        connection.failed(peripheralID, message: "遥控器语音命令失败，正在重新连接：\(error.localizedDescription)")
    }

    func receiveCharacteristicDiscoveryFailure(_ error: Error, service: CBUUID, peripheralID: UUID) {
        guard service != Self.battery else {
            batteryLevel = nil
            onStatus?()
            AudioDiagnostics.log("[RcHarness] Remote battery discovery unavailable: \(error.localizedDescription)")
            return
        }
        connection.failed(peripheralID, message: "读取遥控器特征失败")
    }

    private func write(_ bytes: [UInt8]) {
        if let opcode = bytes.first {
            AudioDiagnostics.log("[RcHarness] Remote voice transmit opcode=\(String(format: "0x%02x", opcode)) argument=\(bytes.dropFirst().map { String(format: "%02x", $0) }.joined(separator: ":")) phase=\(String(describing: tapPhase))")
        }
        if let commandWriter { commandWriter(bytes); return }
        guard let remote, let transmit else { return }
        let type: CBCharacteristicWriteType = transmit.properties.contains(.write) ? .withResponse : .withoutResponse
        remote.writeValue(Data(bytes), for: transmit, type: type)
    }

    private func initialize() {
        guard identity.confirmed, notifications.contains(Self.audio), notifications.contains(Self.control),
              transmit != nil, !requestedCapabilities else { return }
        requestCapabilities()
    }

    /// Called after identity and notification setup; separated from GATT I/O
    /// so protocol tests can exercise the production receive path.
    func requestCapabilities() {
        requestedCapabilities = true
        write(profile.voiceCapabilitiesRequest(mode: voiceMode))
    }

    private func closeMicrophone() {
        sessionGate.stop(cancelled: true, at: now())
        if microphoneOpen { write([0x0D, stream.session ?? 0]) }
        microphoneOpen = false
        finishStream(cancelled: true)
    }

    private func finishStream(cancelled: Bool) {
        streamWatchdog.stop()
        let hadTapCapture = tapPhase != .idle
        resetTapCapture()
        updateVoiceButton(pressed: false)
        guard stream.session != nil else {
            if cancelled { onStreamEvent?(.cancelled) }
            else if hadTapCapture { onStreamEvent?(.ended) }
            return
        }
        logStreamSummary(cancelled: cancelled)
        stream.stop()
        enhancer.reset()
        onStreamEvent?(cancelled ? .cancelled : .ended)
        if isReady { report("遥控器麦克风已连接") }
    }

    private func logStreamSummary(cancelled: Bool) {
        let now = now()
        let firstMS = firstPCMAt.map { Int(($0 - (streamStartedAt ?? $0)) * 1000) } ?? -1
        let durationMS = Int((now - (streamStartedAt ?? now)) * 1000)
        AudioDiagnostics.log("[RcHarness] Remote voice capture session=\(stream.session ?? 0) cancelled=\(cancelled) packets=\(stream.receivedPackets) bytes=\(stream.receivedBytes) frames=\(stream.decodedFrames) samples=\(stream.sampleCount) peak=\(stream.peak) partial_bytes=\(stream.pendingBytes) sync_discarded_bytes=\(stream.synchronizationDiscardedBytes) first_pcm_ms=\(firstMS) duration_ms=\(durationMS)")
    }

    private func retireTapStream() {
        streamWatchdog.stop()
        if stream.session != nil { logStreamSummary(cancelled: false) }
        stream.stop()
        enhancer.reset()
    }

    /// Receives a validated ATVV start independently of GATT discovery.
    func startStream(session: UInt8, implicit: Bool = false) {
        if !implicit { implicitRestartBlocked = false }
        microphoneOpen = true
        stream.start(session: session, implicit: implicit)
        streamStartedAt = now()
        firstPCMAt = nil
        enhancer.reset()
        updateVoiceButton(pressed: true)
        // The input router can reject this press (permissions or an open
        // switcher) and synchronously cancel the stream.
        guard stream.session != nil else { return }
        AudioDiagnostics.log("[RcHarness] Remote voice capture start session=\(session) implicit=\(implicit)")
        report("正在接收遥控器麦克风")
        onStreamEvent?(.started)
        if profile.adapter.usesATVVVoiceButton, stream.session != nil {
            streamWatchdog.start()
        }
        // MIC_OPEN can be acknowledged after a short press has already ended.
        // Repeat CLOSE with the actual session ID so capture cannot stay open.
        if remappedPressReleased {
            write([0x0D, session])
            microphoneOpen = false
        }
    }

    private func expireStream(_ reason: RemoteVoiceStreamWatchdog.Expiry) {
        guard stream.session != nil else { return }
        implicitRestartBlocked = true
        sessionGate.stop(cancelled: true, at: now())
        if microphoneOpen { write([0x0D, stream.session ?? 0]) }
        microphoneOpen = false
        // Generate the missing release/STOP and drain the received tail before
        // releasing the target shortcut, just as a normal physical release.
        finishStream(cancelled: false)
        let retry = voiceMode == .tap ? "请重新点按语音键" : "请重新按住语音键"
        report(reason == .idle
            ? "遥控器语音数据超时，已结束收音；\(retry)"
            : "单次语音已达 \(Int(RemoteVoiceStreamWatchdog.maximumDuration)) 秒，已结束收音；\(retry)")
    }

    private func updateVoiceButton(pressed: Bool) {
        guard voiceMode != .tap, profile.adapter.usesATVVVoiceButton,
              let edge = voiceButton.update(pressed: pressed) else { return }
        onVoiceButtonInput?(edge)
    }

    func receiveControl(_ data: Data) {
        let bytes = Array(data)
        guard let opcode = bytes.first else { return }
        // Sync packets contain the codec's PCM predictor. Log only the
        // lifecycle/capability fields, never sync state or unknown payloads.
        let lifecycle = [UInt8(0x00), 0x04, 0x08, 0x0B, 0x0C].contains(opcode)
        let argument = lifecycle ? bytes.dropFirst().prefix(8).map { String(format: "%02x", $0) }.joined(separator: ":") : "omitted"
        AudioDiagnostics.log("[RcHarness] Remote voice control opcode=\(String(format: "0x%02x", opcode)) bytes=\(bytes.count) argument=\(argument) phase=\(String(describing: tapPhase))")
        if opcode == 0x0B {
            guard requestedCapabilities, !isReady, let caps = RemoteVoiceCapabilities(data) else {
                report("遥控器语音协议不受支持")
                return
            }
            capabilities = caps
            // The reply describes supported interaction levels, not an echo
            // of our selection. PTT/HTT support also includes on-request.
            guard voiceMode != .tap || caps.interactionModel.map({ $0 <= 3 }) == true else {
                captureFailed("此遥控器固件未接受点按收音，请切回长按模式。")
                return
            }
            isReady = true
            if let remote { connection.handshakeSucceeded(remote.identifier) }
            report("遥控器麦克风已连接")
            AudioDiagnostics.log("[RcHarness] Remote voice ATVV version=\(caps.version) frame=\(caps.frameBytes) rate=16000 model=\(caps.interactionModel.map { String($0) } ?? "unknown")")
            return
        }
        guard isReady else { return }
        switch opcode {
        case 0x08 where enabled:
            if voiceMode == .tap { receiveTap(source: .search); return }
            guard !microphoneOpen else { return }
            implicitRestartBlocked = false
            sessionGate.prepareForPress()
            openMicrophone()
        case 0x04 where enabled:
            guard bytes.count >= 4, bytes[2] == 2 else {
                closeMicrophone()
                report("遥控器返回了不受支持的语音格式")
                return
            }
            if voiceMode == .tap {
                receiveTapStart(reason: bytes[1], session: bytes[3])
                return
            }
            guard sessionGate.acceptsStart(at: now()) else {
                write([0x0D, bytes[3]])
                AudioDiagnostics.log("[RcHarness] Remote voice capture rejected_start reason=cancelled session=\(bytes[3])")
                return
            }
            startReason = bytes[1]
            if stream.isImplicit {
                stream.confirmImplicitSession(bytes[3])
                return
            }
            guard stream.session != bytes[3] else { return }
            // Starting the replacement output clears old buffers/completions;
            // do not cancel a new HID press that may already have arrived.
            if stream.session != nil { finishStream(cancelled: false) }
            // Xiaomi RC001/RC003 can initiate AUDIO_START directly on a
            // physical voice press, without sending START_SEARCH or waiting
            // for a host MIC_OPEN.
            startStream(session: bytes[3])
        case 0x00:
            stopReason = bytes.count > 1 ? bytes[1] : nil
            if voiceMode == .tap { receiveTapStop(); return }
            microphoneOpen = false
            sessionGate.stop(cancelled: voiceMode == .tap, at: now())
            finishStream(cancelled: false)
        case 0x0A where stream.session != nil:
            guard bytes.count >= 7, bytes[6] <= 88 else { closeMicrophone(); return }
            let bits = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
            stream.synchronize(sample: Int16(bitPattern: bits), index: Int(bytes[6]))
            enhancer.reset()
        case 0x0C where voiceMode == .tap:
            captureFailed("遥控器无法开启点按收音，请切回长按模式。")
        default:
            break
        }
    }

    private func resetTapCapture() {
        tapPress = nil
        tapHIDDown = false
        tapRevision += 1
        tapPhase = .idle
        tapStartup?.cancel()
        tapClose?.cancel()
        tapExtend?.cancel()
        tapHIDPress?.cancel()
        tapStartup = nil
        tapClose = nil
        tapExtend = nil
        tapHIDPress = nil
    }

    private func captureFailed(_ message: String) {
        closeMicrophone()
        report(message)
        onCaptureFailure?(message)
    }

    /// Native HTT capture is left running until release. A second native
    /// press may replace a host-opened stream without ending the input method.
    private func receiveTapStart(reason: UInt8, session: UInt8) {
        startReason = reason
        if reason == 3 {
            guard tapPress?.session != session else { return }
            guard tapPhase != .stopping else { write([0x0D, session]); return }
            let wasOpen = tapPhase != .idle
            let accepted = wasOpen || beginTapCapture()
            tapPress = TapPress(session: session, began: now(), wasOpen: wasOpen, accepted: accepted)
            lastTapAt = now()
            lastTapSource = .native
            guard accepted else { write([0x0D, session]); return }
            tapStartup?.cancel()
            tapExtend?.cancel()
            retireTapStream()
            tapPhase = .streaming
            startStream(session: session)
            if tapPhase == .streaming { extendTapCapture() }
            return
        }
        guard reason == 0 else {
            write([0x0D, session])
            captureFailed("遥控器未进入点按收音，请切回长按模式。")
            return
        }
        guard tapPhase != .idle, tapPress == nil, sessionGate.acceptsStart(at: now()) else {
            write([0x0D, session])
            return
        }
        guard stream.session != session else { return }
        retireTapStream()
        if tapPhase == .opening { tapPhase = .streaming }
        startStream(session: session)
        if tapPhase == .streaming { extendTapCapture() }
    }

    private func receiveTapStop() {
        if stopReason == 2 {
            if let press = tapPress {
                tapPress = nil
                lastTapAt = now()
                lastTapSource = .native
                microphoneOpen = false
                guard press.accepted else { return }
                if !press.wasOpen, tapPhase == .streaming, now() - press.began < 0.55 {
                    // The physical HTT stream has actually ended. Keep the
                    // target session and its queued PCM while opening the
                    // persistent stream only now, after key release.
                    retireTapStream()
                    tapExtend?.cancel()
                    tapPhase = .opening
                    armTapStartup()
                    openMicrophone()
                    return
                }
            } else if tapPhase == .opening || (tapPhase == .streaming && stream.session == 0) {
                // Some firmware emits release notifications for unrelated
                // keys. Without a tracked native press they cannot end the
                // host-opened stream or postpone its first-frame deadline.
                return
            }
        }
        microphoneOpen = false
        sessionGate.stop(cancelled: true, at: now())
        finishStream(cancelled: false)
    }

    @discardableResult
    private func beginTapCapture() -> Bool {
        guard canStartCapture?() != false else { return false }
        sessionGate.prepareForPress()
        implicitRestartBlocked = false
        remappedPressReleased = false
        tapPhase = .opening
        // The router checks permissions and can synchronously cancel.
        onVoiceButtonInput?(true)
        onVoiceButtonInput?(false)
        return tapPhase != .idle
    }

    private func armTapStartup() {
        tapStartup?.cancel()
        let revision = tapRevision
        tapStartup = schedule(1) { [weak self] in
            guard let self, self.tapRevision == revision,
                  self.tapPhase == .opening || self.tapPhase == .streaming else { return }
            self.captureFailed("点按开麦后未收到音频，请切回长按模式。")
        }
    }

    private func receiveTap(source: TapSource) {
        guard tapPress == nil, tapPhase != .stopping else { return }
        let elapsed = now() - lastTapAt
        if lastTapSource != source, elapsed < 0.25 { return }
        guard elapsed >= 0.05 else { return }
        lastTapAt = now()
        lastTapSource = source
        if tapPhase == .idle {
            guard beginTapCapture() else { return }
            armTapStartup()
            openMicrophone()
        } else {
            onVoiceButtonInput?(true)
            onVoiceButtonInput?(false)
        }
    }

    private func extendTapCapture() {
        let revision = tapRevision
        tapExtend = schedule(5) { [weak self] in
            guard let self, self.tapRevision == revision, self.tapPhase == .streaming,
                  let session = self.stream.session else { return }
            self.write([0x0E, session])
            self.extendTapCapture()
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central, wanted else { return }
        connection.setPoweredOn(central.state == .poweredOn)
        if central.state != .poweredOn {
            report(central.state == .unauthorized ? "请允许 RcHarness 使用蓝牙" : "蓝牙暂不可用")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasVoiceService = advertisedServices.contains(Self.service)
        guard self.central === central,
              profile.matchesBluetoothName(advertisedName) || (advertisedName == nil && hasVoiceService) else { return }
        peripherals[peripheral.identifier] = peripheral
        connection.discovered(.init(id: peripheral.identifier, name: advertisedName), hasVoiceService: hasVoiceService)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central, remote === peripheral, wanted else { return }
        peripheral.discoverServices([Self.service, Self.information, Self.battery])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.central === central, remote === peripheral else { return }
        connection.failed(peripheral.identifier)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard remote === peripheral, wanted else { return }
        guard error == nil else {
            failConnection("读取遥控器语音服务失败", peripheral: peripheral)
            return
        }
        for service in peripheral.services ?? [] {
            if service.uuid == Self.service { peripheral.discoverCharacteristics([Self.transmit, Self.audio, Self.control], for: service) }
            if service.uuid == Self.information { peripheral.discoverCharacteristics([Self.modelNumber, Self.pnpID], for: service) }
            if service.uuid == Self.battery { peripheral.discoverCharacteristics([Self.batteryLevel], for: service) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard remote === peripheral, wanted else { return }
        if let error {
            receiveCharacteristicDiscoveryFailure(error, service: service.uuid, peripheralID: peripheral.identifier)
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.transmit:
                guard !characteristic.properties.intersection([.write, .writeWithoutResponse]).isEmpty else { continue }
                transmit = characteristic
            case Self.audio, Self.control:
                peripheral.setNotifyValue(true, for: characteristic)
            case Self.modelNumber, Self.pnpID:
                peripheral.readValue(for: characteristic)
            case Self.batteryLevel:
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            default: break
            }
        }
        initialize()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard remote === peripheral, wanted else { return }
        if characteristic.uuid == Self.batteryLevel {
            if let error { AudioDiagnostics.log("[RcHarness] Remote battery notifications unavailable: \(error.localizedDescription)") }
            return
        }
        guard error == nil, characteristic.isNotifying else {
            failConnection("遥控器语音通知已失效", peripheral: peripheral)
            return
        }
        notifications.insert(characteristic.uuid)
        initialize()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard remote === peripheral, let error else { return }
        receiveCommandFailure(error, peripheralID: peripheral.identifier)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard remote === peripheral, wanted, error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.batteryLevel:
            guard let level = Self.normalizedBatteryLevel(data) else { return }
            if batteryLevel != level {
                batteryLevel = level
                AudioDiagnostics.log("[RcHarness] Remote battery level=\(Int((level * 100).rounded()))%")
                onStatus?()
            }
        case Self.modelNumber:
            receiveModelNumber(String(data: data, encoding: .utf8))
        case Self.pnpID:
            identity.receivePnP(data)
            updateIdentity()
        case Self.control:
            receiveControl(data)
        case Self.audio:
            receiveAudio(data)
        default: break
        }
    }

    func receiveAudio(_ data: Data) {
        guard enabled, isReady, !data.isEmpty, let capabilities else { return }
        if voiceMode == .tap {
            guard tapPhase == .streaming || tapPhase == .stopping, stream.session != nil else { return }
        }
        if stream.session == nil {
            guard !implicitRestartBlocked, sessionGate.acceptsImplicitStart(at: now()) else { return }
            startStream(session: 0, implicit: true)
        }
        streamWatchdog.receivedAudio()
        let pcm = stream.append(data, frameBytes: capabilities.frameBytes)
        // Enhance at decode time; the virtual HAL only forwards these samples.
        if !pcm.isEmpty {
            if voiceMode == .tap { tapStartup?.cancel() }
            if firstPCMAt == nil { firstPCMAt = now() }
            onSamples?(enhancer.processInt16(pcm))
        }
    }

    nonisolated static func normalizedBatteryLevel(_ data: Data) -> Float? {
        guard let raw = data.first, raw <= 100 else { return nil }
        return Float(raw) / 100
    }
}
