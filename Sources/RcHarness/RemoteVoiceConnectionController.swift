import Foundation

/// Owns discovery, connection deadlines and retry policy. The BLE adapter
/// supplies UUIDs and performs I/O; tests exercise these same transitions with
/// TestClock, without constructing CoreBluetooth objects or using real waits.
@MainActor
final class RemoteVoiceConnectionController {
    struct Candidate {
        let id: UUID
        let name: String?
    }
    struct Transport {
        let retrieve: (UUID) -> Bool
        let connected: () -> [Candidate]
        let scan: () -> Void
        let stopScan: () -> Void
        let connect: (UUID) -> Void
        let disconnect: (UUID) -> Void
    }

    private let profile: RemoteProfile
    private let defaults: UserDefaults
    private let transport: Transport
    private let schedule: RemoteVoiceSessionController.Scheduler
    private let now: () -> TimeInterval
    private var wanted = false
    private var poweredOn = false
    private var ready = false
    private var rememberedFailures = 0
    private var connectingRemembered = false
    private var retryAttempt = 0
    private var excludedUntil: [UUID: TimeInterval] = [:]
    private var attemptedCandidates: Set<UUID> = []
    private var timeout: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var revision = 0
    private(set) var remoteID: UUID?
    private(set) var phase = "未连接"
    private(set) var lastFailure: String?
    var onReset: (() -> Void)?
    var onStatus: ((String) -> Void)?

    init(profile: RemoteProfile, defaults: UserDefaults, transport: Transport,
         schedule: @escaping RemoteVoiceSessionController.Scheduler = RemoteVoiceSessionController.mainQueue,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.profile = profile
        self.defaults = defaults
        self.transport = transport
        self.schedule = schedule
        self.now = now
    }

    func start() {
        guard !wanted else { return }
        wanted = true
        rememberedFailures = 0
        retryAttempt = 0
        excludedUntil.removeAll()
        attemptedCandidates.removeAll()
        discover()
    }

    func stop() {
        wanted = false
        poweredOn = false
        phase = "未连接"
        cancelWork()
        transport.stopScan()
        clearRemote()
    }

    func setPoweredOn(_ poweredOn: Bool) {
        guard self.poweredOn != poweredOn else { return }
        self.poweredOn = poweredOn
        cancelWork()
        if poweredOn {
            rememberedFailures = 0
            discover()
        } else {
            phase = "蓝牙不可用"
            clearRemote()
        }
    }

    var rememberedID: UUID? {
        let key = SettingsKeys.voicePeripheralUUID(profileID: profile.id)
        return (defaults.string(forKey: key) ?? defaults.string(forKey: SettingsKeys.voicePeripheralUUID))
            .flatMap(UUID.init(uuidString:))
    }

    private func eligible(_ id: UUID) -> Bool { excludedUntil[id].map { $0 <= now() } ?? true }

    private func discover() {
        guard wanted, poweredOn, remoteID == nil else { return }
        excludedUntil = excludedUntil.filter { $0.value > now() }
        let remembered = rememberedID
        let candidates = transport.connected().filter {
            eligible($0.id) && ($0.name == nil || profile.matchesBluetoothName($0.name))
        }
        // A cached UUID can remain retrievable after re-pairing. Prefer live
        // candidates so an obsolete identity cannot consume two deadlines.
        // A connected remembered device resolves ambiguity, but must still
        // yield to other Xiaomi candidates after an unsuccessful model probe.
        if let candidate = candidates.first(where: { $0.id == remembered }),
           !profile.requiresHIDModelConfirmation || !attemptedCandidates.contains(candidate.id) {
            connect(candidate.id)
            return
        }
        if candidates.count > 1, profile.requiresHIDModelConfirmation {
            // Xiaomi models share their name and VID/PID. Probe Device
            // Information instead of requiring the other model to disconnect.
            // Rotate candidates so one unresponsive remote cannot starve others.
            if candidates.allSatisfy({ attemptedCandidates.contains($0.id) }) {
                attemptedCandidates.removeAll()
            }
            if let candidate = candidates.first(where: { !attemptedCandidates.contains($0.id) }) {
                connect(candidate.id)
            }
        } else if candidates.count == 1, let candidate = candidates.first {
            connect(candidate.id)
        } else if candidates.isEmpty, rememberedFailures < 2,
                  let id = remembered, eligible(id), transport.retrieve(id) {
            connect(id, remembered: true)
        } else {
            if candidates.isEmpty {
                phase = "寻找设备"
                transport.scan()
                onStatus?("正在寻找遥控器语音服务")
            } else {
                phase = "等待候选唯一"
                onStatus?("发现多个匹配的遥控器，无法确定语音设备")
            }
            // Connected remotes may no longer advertise. Recheck both zero
            // and multiple candidates, including expiry of rejected identities.
            scheduleDiscovery(after: 10, resetRememberedFailures: true)
        }
    }

    func discovered(_ candidate: Candidate, hasVoiceService: Bool) {
        guard profile.matchesBluetoothName(candidate.name) || (candidate.name == nil && hasVoiceService) else { return }
        connect(candidate.id)
    }

    private func connect(_ id: UUID, remembered: Bool = false) {
        guard wanted, poweredOn, remoteID == nil, eligible(id) else { return }
        cancelWork()
        transport.stopScan()
        remoteID = id
        attemptedCandidates.insert(id)
        phase = "连接与协商"
        connectingRemembered = remembered
        ready = false
        let current = revision
        timeout = schedule(20) { [weak self] in
            guard let self, self.revision == current, self.remoteID == id, !self.ready else { return }
            self.failed(id, message: "遥控器麦克风连接超时；请按键唤醒")
        }
        transport.connect(id)
    }

    func handshakeSucceeded(_ id: UUID) {
        guard wanted, remoteID == id else { return }
        ready = true
        phase = "已连接"
        timeout?.cancel()
        timeout = nil
        retryAttempt = 0
        rememberedFailures = 0
        connectingRemembered = false
        defaults.set(id.uuidString, forKey: SettingsKeys.voicePeripheralUUID(profileID: profile.id))
        defaults.removeObject(forKey: SettingsKeys.voicePeripheralUUID)
    }

    func rejected(_ id: UUID, message: String) {
        guard remoteID == id else { return }
        excludedUntil[id] = now() + 30
        failed(id, message: message)
    }

    func failed(_ id: UUID, message: String = "遥控器麦克风已断开，等待重连") {
        guard wanted, remoteID == id else { return }
        lastFailure = message
        phase = "等待重连"
        if connectingRemembered, !ready { rememberedFailures += 1 }
        cancelWork()
        clearRemote()
        onStatus?(message)
        let delay = min(pow(2, Double(retryAttempt)), 16)
        retryAttempt = min(retryAttempt + 1, 4)
        scheduleDiscovery(after: delay)
    }

    private func clearRemote() {
        let previous = remoteID
        remoteID = nil
        ready = false
        connectingRemembered = false
        onReset?()
        if let previous { transport.disconnect(previous) }
    }

    private func cancelWork() {
        revision += 1
        timeout?.cancel()
        timeout = nil
        retry?.cancel()
        retry = nil
    }

    private func scheduleDiscovery(after delay: TimeInterval, resetRememberedFailures: Bool = false) {
        guard wanted, poweredOn else { return }
        retry?.cancel()
        let current = revision
        retry = schedule(delay) { [weak self] in
            guard let self, self.wanted, self.poweredOn, self.revision == current, self.remoteID == nil else { return }
            self.retry = nil
            self.transport.stopScan()
            if resetRememberedFailures { self.rememberedFailures = 0 }
            self.discover()
        }
    }
}
