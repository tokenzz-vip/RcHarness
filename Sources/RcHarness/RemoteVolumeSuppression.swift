import Darwin
import Foundation

struct RemoteKeyMapping: Codable, Hashable {
    let source: UInt64
    let destination: UInt64
}

/// Filter mapped keyboard usages and standard power usages while mappings are active.
/// Raw IOHID input and BLE microphone notifications remain available.
enum RemoteVolumeSuppression {
    // Keep the existing guard/journal name so prior installations can restore
    // their mappings. Native keys must not accompany the mapped action.
    static let sources: [UInt64] = Set(RemoteProfiles.all.flatMap { RemoteHIDUsages.bindings(for: $0) }.map(\.source)).sorted()

    /// Inactive Xiaomi remotes still send a system F5/voice shortcut. Consume
    /// only its aliases; their other native keys keep working.
    static func inactiveVoiceSources(for profile: RemoteProfile) -> [UInt64] {
        guard profile.adapter == .xiaomi else { return [] }
        return RemoteHIDUsages.bindings(for: profile).filter { $0.input == .options }.map(\.source).sorted()
    }

    static func suppress(_ original: [RemoteKeyMapping], sources: [UInt64] = sources) -> [RemoteKeyMapping] {
        original.filter { !sources.contains($0.source) }
            + sources.map { RemoteKeyMapping(source: $0, destination: 0) }
    }

    static func restore(_ current: [RemoteKeyMapping], original: [RemoteKeyMapping],
                        sources: [UInt64] = sources) -> [RemoteKeyMapping] {
        // Another utility may have edited mappings while we owned the keys.
        // Restore only entries that still contain our suppression value.
        let owned = sources.filter { source in
            current.filter { $0.source == source } == [.init(source: source, destination: 0)]
        }
        return current.filter { !owned.contains($0.source) }
            + original.filter { owned.contains($0.source) }
    }
}

/// A separate process owns the temporary system mapping. Closing stdin (including
/// when the GUI crashes or is killed during a rebuild) restores the saved mapping.
@MainActor
protocol RemoteVolumeGuarding: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func update(mapping: Bool)
    func stop()
}

@MainActor
final class RemoteVolumeGuard: RemoteVolumeGuarding {
    private var process: Process?
    private var input: FileHandle?
    private let profiles: [RemoteProfile]
    var onFailure: ((String) -> Void)?

    init(profiles: [RemoteProfile] = RemoteProfiles.all) {
        self.profiles = profiles
    }

    func update(mapping: Bool) {
        do {
            if process?.isRunning != true {
                try input?.close()
                let child = Process()
                child.executableURL = Bundle.main.executableURL
                child.arguments = ["--remote-volume-guard", "--remote-profiles"] + profiles.map(\.id)
                let pipe = Pipe()
                child.standardInput = pipe
                child.terminationHandler = { [weak self] child in
                    let status = child.terminationStatus
                    DispatchQueue.main.async { [weak self, weak child] in
                        guard let self, let child, self.process === child else { return }
                        self.process = nil
                        try? self.input?.close()
                        self.input = nil
                        self.onFailure?("遥控器原生按键保护进程已退出（\(status)），请立即重新连接。")
                    }
                }
                try child.run()
                try pipe.fileHandleForReading.close()
                _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                process = child
                input = pipe.fileHandleForWriting
            }
            try input?.write(contentsOf: Data((mapping ? "mapping\n" : "native\n").utf8))
        } catch {
            onFailure?("遥控器原生按键保护失败，请立即重新连接。")
            Log.suppression.error("Suppression guard failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Closing stdin is the restore signal; the guard finishes on its own even
    /// after this process exits. Never wait here: restoring runs several
    /// `hidutil` commands and would freeze the main thread.
    func stop() {
        try? input?.close()
        input = nil
        process = nil
    }

    deinit { try? input?.close() }
}

private struct RemoteVolumeSnapshot: Codable {
    let registryID: UInt64
    let matching: [String: UInt64]
    var original: [RemoteKeyMapping]
    /// Missing in old journals, which always suppressed the full source set.
    var sources: [UInt64]? = nil
}

/// Uses the system utility instead of private IOHIDEventSystem APIs or root access.
final class RemoteVolumeGuardWorker {
    struct DeviceIdentity {
        let modelNumber: (UInt64) -> String?
        static let system = DeviceIdentity(modelNumber: RemoteHIDIdentity.modelNumber(registryID:))
    }
    struct RetryTiming {
        let pause: (TimeInterval) -> Void
        static let system = RetryTiming(pause: { Thread.sleep(forTimeInterval: $0) })
    }
    private let directory: URL
    private let input: FileHandle
    private let hidutil: ([String]) throws -> Data
    private let retryMilliseconds: Int32
    private let maximumRetryMilliseconds: Int32
    private let profiles: [RemoteProfile]
    private let pause: (TimeInterval) -> Void
    private let modelNumber: (UInt64) -> String?

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RcHarness"),
        input: FileHandle = .standardInput,
        retryMilliseconds: Int32 = 500,
        maximumRetryMilliseconds: Int32 = 30_000,
        profiles: [RemoteProfile] = RemoteProfiles.all,
        retryTiming: RetryTiming = .system,
        identity: DeviceIdentity = .system,
        hidutil: @escaping ([String]) throws -> Data = RemoteVolumeGuardWorker.executeHidutil
    ) {
        self.directory = directory
        self.input = input
        self.retryMilliseconds = retryMilliseconds
        self.maximumRetryMilliseconds = max(retryMilliseconds, maximumRetryMilliseconds)
        self.profiles = profiles
        self.hidutil = hidutil
        self.pause = retryTiming.pause
        self.modelNumber = identity.modelNumber
    }

    @discardableResult
    func run() -> Bool {
        // A replacement GUI may start before the previous guard finishes
        // restoring. The GUI no longer waits for that restore, so allow it
        // enough time to complete several hidutil calls.
        var lock: SingleInstanceLock?
        for _ in 0..<500 {
            lock = try? SingleInstanceLock(path: directory.appendingPathComponent("remote-volume.lock").path)
            if lock != nil { break }
            pause(0.02)
        }
        guard let lock else {
            Log.suppression.notice("Suppression guard already running")
            return false
        }
        return withExtendedLifetime(lock) {
            let journal = directory.appendingPathComponent("remote-volume-restore.json")
            do {
                var snapshots: [RemoteVolumeSnapshot] = []
                if FileManager.default.fileExists(atPath: journal.path) {
                    snapshots = try JSONDecoder().decode([RemoteVolumeSnapshot].self, from: Data(contentsOf: journal))
                }
                // Recover even if both the previous GUI and guard were interrupted.
                guard restoreWithRetry(&snapshots, journal: journal) else { return false }
                var mapping = false
                var needsRetry = false
                var retryDelay = retryMilliseconds
                var pendingInput = Data()
                while true {
                    // Retry late HID event services without blocking mode changes
                    // or EOF (the GUI may have exited/crashed). Back off while a
                    // service stays unready so an unmatched device cannot keep
                    // running hidutil twice a second forever.
                    var descriptor = pollfd(fd: input.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    let result = poll(&descriptor, 1, needsRetry ? retryDelay : -1)
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    if result == 0 {
                        retryDelay = min(retryDelay * 2, maximumRetryMilliseconds)
                    } else {
                        let data = input.availableData
                        if data.isEmpty { break }
                        pendingInput.append(data)
                        while let newline = pendingInput.firstIndex(of: 0x0A) {
                            let command = String(decoding: pendingInput[..<newline], as: UTF8.self)
                            pendingInput.removeSubrange(...newline)
                            if command == "mapping" { mapping = true }
                            else if command == "native" { mapping = false }
                            // A new command (e.g. after reconnecting) deserves a prompt retry.
                            retryDelay = retryMilliseconds
                        }
                    }
                    do {
                        if mapping {
                            needsRetry = !(try suppress(&snapshots, journal: journal))
                            if !needsRetry { retryDelay = retryMilliseconds }
                        } else {
                            guard restoreWithRetry(&snapshots, journal: journal) else { return false }
                            needsRetry = false
                        }
                    } catch {
                        Log.suppression.error("Native key suppression failed: \(error.localizedDescription, privacy: .public)")
                        guard restoreWithRetry(&snapshots, journal: journal) else { return false }
                        needsRetry = mapping
                    }
                }
                return restoreWithRetry(&snapshots, journal: journal)
            } catch {
                Log.suppression.error("Native key restore failed (recovery journal retained): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    private static func executeHidutil(_ arguments: [String]) throws -> Data {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        command.arguments = arguments
        let output = Pipe()
        command.standardOutput = output
        try command.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else {
            throw NSError(domain: "RemoteVolumeHID", code: Int(command.terminationStatus))
        }
        return data
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
    }

    static func serviceMatchingJSON(_ matching: [String: UInt64]) throws -> String {
        // hidutil reports Bluetooth service LocationID as a signed number.
        // Preserve that value for matching, including when restoring old journals
        // that stored its UInt64 bit pattern. A widened value matches no service.
        try json(matching.mapValues { Int64(bitPattern: $0) })
    }

    private func services(profiles: [RemoteProfile]? = nil, includeNonSuppressible: Bool = false) throws -> [[String: Any]] {
        var seenRegistryIDs: Set<UInt64> = []
        var seenMatches: Set<String> = []
        return try (profiles ?? self.profiles).flatMap(\.hidMatching).flatMap { match -> [[String: Any]] in
            let query = try Self.json(match)
            guard seenMatches.insert(query).inserted else { return [] }
            let output = try hidutil(["list", "--ndjson", "--matching", query])
            return try String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { line -> [String: Any]? in
                let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                guard let record, record["type"] as? String == "service" else { return nil }
                // A VID/PID match can include a mouse or another composite HID
                // service. Limit temporary key mappings to keyboard/consumer
                // services; pointer services must keep their native input.
                guard includeNonSuppressible || Self.isSuppressibleService(record) else { return nil }
                // RC001 and RC003 share a HID match. Count each actual service
                // once, or the uniqueness check below rejects valid devices.
                if let id = record["IORegistryEntryID"] as? NSNumber,
                   !seenRegistryIDs.insert(id.uint64Value).inserted { return nil }
                return record
            }
        }
    }

    private static func isSuppressibleService(_ service: [String: Any]) -> Bool {
        guard let usagePage = (service["PrimaryUsagePage"] as? NSNumber)?.uint32Value,
              let usage = (service["PrimaryUsage"] as? NSNumber)?.uint32Value else { return false }
        return (usagePage == 0x01 && usage == 0x06)
            || (usagePage == 0x07 && usage == 0x06)
            || (usagePage == 0x0C && usage == 0x01)
    }

    private func mappingsByService() throws -> [UInt64: [RemoteKeyMapping]] {
        let data = try hidutil(["dump", "services", "-f", "xml"])
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let records = plist?["ServiceRecords"] as? [[String: Any]] else {
            throw NSError(domain: "RemoteVolumeHID.invalidDump", code: 1)
        }
        var result: [UInt64: [RemoteKeyMapping]] = [:]
        for record in records {
            guard let id = record["IORegistryEntryID"] as? NSNumber,
                  let filters = record["ServiceFilterDebug"] as? [[String: Any]],
                  let keyboard = filters.first(where: { $0["name"] as? String == "com.apple.iokit.hid.IOHIDKeyboardFilter" }),
                  let plugin = keyboard["plugin"] as? [String: Any],
                  let entries = plugin["UserKeyMapping"] as? [[String: Any]] else { continue }
            result[id.uint64Value] = try entries.map { entry in
                guard let src = entry["Src"] as? NSNumber, let dst = entry["Dst"] as? NSNumber else {
                    throw NSError(domain: "RemoteVolumeHID.invalidMapping", code: 1)
                }
                return RemoteKeyMapping(source: src.uint64Value, destination: dst.uint64Value)
            }
        }
        return result
    }

    private func write(_ mappings: [RemoteKeyMapping], matching: [String: UInt64]) throws {
        let entries = mappings.map { ["HIDKeyboardModifierMappingSrc": $0.source, "HIDKeyboardModifierMappingDst": $0.destination] }
        _ = try hidutil(["property", "--matching", Self.serviceMatchingJSON(matching), "--set", Self.json(["UserKeyMapping": entries])])
    }

    private func save(_ snapshots: [RemoteVolumeSnapshot], journal: URL) throws {
        try JSONEncoder().encode(snapshots).write(to: journal, options: .atomic)
    }

    private func suppress(_ snapshots: inout [RemoteVolumeSnapshot], journal: URL) throws -> Bool {
        let protectionProfiles = profiles + RemoteProfiles.all.filter { candidate in
            candidate.adapter == .xiaomi && !profiles.contains { $0.id == candidate.id }
        }
        let candidates = try services(profiles: protectionProfiles)
        let targets: [(device: [String: Any], sources: [UInt64])] = candidates.compactMap { device in
            let vendor = (device["VendorID"] as? NSNumber)?.intValue
            let product = (device["ProductID"] as? NSNumber)?.intValue
            let physicalCandidates = Set(candidates.filter {
                ($0["VendorID"] as? NSNumber)?.intValue == vendor
                    && ($0["ProductID"] as? NSNumber)?.intValue == product
            }.compactMap { ($0["LocationID"] as? NSNumber)?.int32Value })
            let deviceModel = (device["IORegistryEntryID"] as? NSNumber).flatMap { modelNumber($0.uint64Value) }
            let selected = profiles.contains {
                $0.matchesHIDDevice(vendorID: vendor, productID: product, name: device["Product"] as? String,
                                    confirmedModelNumber: $0.model, deviceModelNumber: deviceModel,
                                    isOnlyCandidate: physicalCandidates.count == 1)
            }
            if selected { return (device, RemoteVolumeSuppression.sources) }
            // VID/PID identifies the supported Xiaomi family sufficiently to
            // suppress shared voice usages, even while model lookup is pending.
            // It never enables this device's application mappings or BLE audio.
            let voiceSources = Set(protectionProfiles.filter {
                $0.matchesHID(vendorID: vendor, productID: product, name: device["Product"] as? String,
                              modelNumber: $0.model)
            }.flatMap { RemoteVolumeSuppression.inactiveVoiceSources(for: $0) }).sorted()
            return voiceSources.isEmpty ? nil : (device, voiceSources)
        }
        // A newly resolved model or a second physical candidate can revoke an
        // earlier single-device fallback. Restore it before suppressing the target.
        let revoked = snapshots.filter { snapshot in
            !targets.contains { ($0.device["IORegistryEntryID"] as? NSNumber)?.uint64Value == snapshot.registryID }
        }
        if !revoked.isEmpty {
            // Keep one shared journal: successful restores commit against the
            // full snapshot set, including still-owned services.
            let revokedIDs = Set(revoked.map(\.registryID))
            try restore(&snapshots, journal: journal, only: revokedIDs)
        }
        let pending = targets.filter { target in
            guard let id = target.device["IORegistryEntryID"] as? NSNumber else { return false }
            return !snapshots.contains {
                $0.registryID == id.uint64Value && ($0.sources ?? RemoteVolumeSuppression.sources) == target.sources
            }
        }
        guard !pending.isEmpty else { return !targets.isEmpty }
        let mappings = try mappingsByService()
        for target in pending {
            let device = target.device
            guard let id = device["IORegistryEntryID"] as? NSNumber,
                  let current = mappings[id.uint64Value] else { continue }
            let keys = ["VendorID", "ProductID", "LocationID", "PrimaryUsagePage", "PrimaryUsage"]
            var matching: [String: UInt64] = [:]
            for key in keys { matching[key] = (device[key] as? NSNumber)?.uint64Value }
            // Never issue a broad/global write when device identity is incomplete
            // or cannot distinguish multiple services.
            guard matching.count == keys.count,
                  candidates.filter({ candidate in matching.allSatisfy { key, value in
                      (candidate[key] as? NSNumber)?.uint64Value == value
                  }}).count == 1 else { continue }
            let existing = snapshots.firstIndex { $0.registryID == id.uint64Value }
            var baseline = current
            if let existing {
                let previous = snapshots[existing]
                baseline = RemoteVolumeSuppression.restore(current, original: previous.original,
                    sources: previous.sources ?? RemoteVolumeSuppression.sources)
                // Newly acquired usages belong to the current baseline, not
                // the earlier voice-only snapshot. Keep this recovery data
                // even if the following system write fails partway through.
                let acquired = Set(target.sources).subtracting(previous.sources ?? RemoteVolumeSuppression.sources)
                snapshots[existing].original = previous.original.filter { !acquired.contains($0.source) }
                    + baseline.filter { acquired.contains($0.source) }
                // Journal the union before a transition: if writing fails, both
                // the old and new suppression sets must remain recoverable.
                snapshots[existing].sources = Set((previous.sources ?? RemoteVolumeSuppression.sources) + target.sources).sorted()
            } else {
                snapshots.append(RemoteVolumeSnapshot(registryID: id.uint64Value, matching: matching,
                                                     original: current, sources: target.sources))
            }
            try save(snapshots, journal: journal)
            let suppressed = RemoteVolumeSuppression.suppress(baseline, sources: target.sources)
            try write(suppressed, matching: matching)
            guard Set(try mappingsByService()[id.uint64Value] ?? []) == Set(suppressed) else {
                throw NSError(domain: "RemoteVolumeHID.suppressionNotApplied", code: 1)
            }
            if let index = snapshots.firstIndex(where: { $0.registryID == id.uint64Value }) {
                snapshots[index].sources = target.sources
            }
            try save(snapshots, journal: journal)
            Log.suppression.info("Native mapped keys suppressed service=\(id.uint64Value) sources=\(target.sources.count)")
        }
        return targets.allSatisfy { target in
            guard let id = target.device["IORegistryEntryID"] as? NSNumber else { return false }
            return snapshots.contains {
                $0.registryID == id.uint64Value && ($0.sources ?? RemoteVolumeSuppression.sources) == target.sources
            }
        }
    }

    private func restore(_ snapshots: inout [RemoteVolumeSnapshot], journal: URL, only registryIDs: Set<UInt64>? = nil) throws {
        guard !snapshots.isEmpty else { return }
        // A previous guard may have owned another selected model. Recovery
        // must include those devices even though new suppression is scoped.
        let recoveryProfiles = profiles + RemoteProfiles.all.filter { candidate in !profiles.contains { $0.id == candidate.id } }
        // Recovery must still find pointer services touched by older builds.
        let connected = try services(profiles: recoveryProfiles, includeNonSuppressible: true)
        let current = try mappingsByService()
        var firstFailure: Error?
        // Commit one successful restoration at a time, so retries touch only
        // unresolved services. Retain a snapshot unless both write and readback
        // succeed, including hidutil returning success without applying a map.
        for snapshot in snapshots {
            if let registryIDs, !registryIDs.contains(snapshot.registryID) { continue }
            do {
                if connected.contains(where: { ($0["IORegistryEntryID"] as? NSNumber)?.uint64Value == snapshot.registryID }) {
                    guard let mappings = current[snapshot.registryID] else {
                        throw NSError(domain: "RemoteVolumeHID.missingKeyboardFilter", code: 1)
                    }
                    let restored = RemoteVolumeSuppression.restore(mappings, original: snapshot.original,
                        sources: snapshot.sources ?? RemoteVolumeSuppression.sources)
                    try write(restored, matching: snapshot.matching)
                    guard let verified = try mappingsByService()[snapshot.registryID], Set(verified) == Set(restored) else {
                        throw NSError(domain: "RemoteVolumeHID.restoreNotApplied", code: 1)
                    }
                    Log.suppression.info("Native mapped keys restored service=\(snapshot.registryID)")
                }
                let remaining = snapshots.filter { $0.registryID != snapshot.registryID }
                try save(remaining, journal: journal)
                snapshots = remaining
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    /// Restoration runs after the GUI has gone away, so a short Core HID
    /// transition must not strand the remote in a suppressed state. Keep the
    /// journal when all attempts fail; the next guard instance can recover it.
    private func restoreWithRetry(_ snapshots: inout [RemoteVolumeSnapshot], journal: URL) -> Bool {
        guard !snapshots.isEmpty else { return true }
        var delay = retryMilliseconds
        for attempt in 0..<4 {
            do {
                try restore(&snapshots, journal: journal)
                return true
            } catch {
                Log.suppression.error("Native key restore attempt=\(attempt + 1) failed: \(error.localizedDescription, privacy: .public)")
                if attempt < 3 {
                    pause(Double(delay) / 1000)
                    delay = min(delay * 2, maximumRetryMilliseconds)
                }
            }
        }
        return false
    }
}
