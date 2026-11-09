import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class ProjectAuditBoundaryTests: XCTestCase {
    private final class CountingDefaults: UserDefaults {
        var configurationWrites = 0
        override func set(_ value: Any?, forKey defaultName: String) {
            if defaultName == "RcHarness." + SettingsKeys.Stored.remoteKeyConfigurations { configurationWrites += 1 }
            super.set(value, forKey: defaultName)
        }
    }

    func testUnchangedForegroundMatchingDoesNotRewriteAllRemoteConfigurations() {
        let suite = "RcHarness.ProjectAudit." + UUID().uuidString
        let defaults = CountingDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.activateProfile(nil)
        defaults.configurationWrites = 0
        for _ in 0..<100 { model.matchApplication(nil) }
        XCTAssertEqual(defaults.configurationWrites, 0,
                       "Repeatedly resolving the already-active default must not encode every remote configuration")
    }

    func testHarnessSelectionCommitsOnceAndRepeatedMatchingDoesNotWrite() throws {
        let suite = "RcHarness.ProjectAudit." + UUID().uuidString
        let defaults = CountingDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        defaults.configurationWrites = 0
        model.activateHarness("codex")
        XCTAssertEqual(defaults.configurationWrites, 1)
        let snapshot = try XCTUnwrap(SettingsStorage.load([String: RemoteKeyConfiguration].self,
            SettingsKeys.Stored.remoteKeyConfigurations, defaults: defaults)?[model.remoteProfile.id])
        XCTAssertEqual(snapshot.selectedHarnessID, "codex")
        XCTAssertEqual(snapshot.selectedProfileID, model.selectedProfileID)
        for _ in 0..<100 { model.matchApplication(nil, bundleIdentifier: "com.openai.codex") }
        XCTAssertEqual(defaults.configurationWrites, 1)
        model.activateHarness("claude")
        XCTAssertEqual(defaults.configurationWrites, 2)
        let restarted = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restarted.selectedHarnessID, "claude")
        XCTAssertEqual(restarted.selectedProfileID, model.selectedProfileID)
    }

    func testDistinctChordMustNotDisappearBehindHeldKey() {
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        sender.send(ButtonMapping(action: .enter), pressed: true)
        sender.send(ButtonMapping(action: .recordedShortcut, shortcut: RecordedShortcut(
            keyCode: VirtualKey.returnKey, modifiers: CGEventFlags.maskCommand.rawValue, label: "Command Enter")), pressed: true)
        XCTAssertTrue(events.contains { $0.type == .keyDown && $0.flags.contains(.maskCommand) },
                      "Holding Enter must not silently swallow a separate Command Enter action")
        sender.send(ButtonMapping(action: .enter), pressed: false)
    }

    func testRetiredHarnessMigrationPreservesIntentionalUnbinding() throws {
        let suite = "RcHarness.ProjectAudit." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        var retired = HarnessConfiguration(id: "antigravity", name: "Antigravity")
        retired.didInitializeDefaultProfile = true
        let backup = SettingsBackup(version: 3, mapping: .defaults, profiles: [], macros: [], phrases: [], harnesses: [retired])
        try model.applyConfiguration(backup)
        XCTAssertNil(model.harnesses.first { $0.id == "deepseek" }?.profileID,
                     "A migrated app must preserve a user's previous unbinding")
    }

    func testImportEnforcesProfileNameUniqueness() throws {
        let suite = "RcHarness.ProjectAudit." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let backup = SettingsBackup(version: 3, mapping: .defaults,
            profiles: [SavedKeyProfile(name: "Work", mapping: .defaults),
                       SavedKeyProfile(name: " work ", mapping: .defaults)], macros: [], phrases: [])
        try model.applyConfiguration(backup)
        let names = model.profiles.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        XCTAssertEqual(Set(names).count, names.count, "Import must not leave indistinguishable profile names")
    }
}

final class ProjectAuditSuppressionTests: XCTestCase {
    func testExpandingOwnershipPreservesLatestOrdinaryMapping() throws {
        try verifyExpansion(failingWrite: 0, removingMapping: false)
    }

    func testExpansionFailureBeforeAndAfterWriteKeepsLatestRecoveryBaseline() throws {
        for failure in [1, 2] { try verifyExpansion(failingWrite: failure, removingMapping: false) }
    }

    func testExpandingOwnershipDoesNotResurrectMappingDeletedBeforeAcquisition() throws {
        try verifyExpansion(failingWrite: 0, removingMapping: true)
    }

    private func verifyExpansion(failingWrite: Int, removingMapping: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("mapping\n".utf8))
        let profile = RemoteProfiles.xiaomiRC003
        let up: UInt64 = 0x700000052
        let first = RemoteKeyMapping(source: up, destination: 0x700000004)
        let latest = RemoteKeyMapping(source: up, destination: 0x700000005)
        var current = [1: [first], 2: [first]]
        var resolved = false
        var expanded = false
        var changedByOtherTool = false
        let worker = RemoteVolumeGuardWorker(directory: directory, input: pipe.fileHandleForReading,
            profiles: [profile], retryTiming: .init(pause: { _ in }),
            identity: .init(modelNumber: { id in resolved ? (id == 1 ? "RC003" : "RC001") : nil })) { arguments in
            switch arguments.first {
            case "list":
                return try [1, 2].reduce(into: Data()) { data, id in
                    let record: [String: Any] = ["type": "service", "IORegistryEntryID": id,
                        "VendorID": profile.vendorID!, "ProductID": profile.productID!, "LocationID": id,
                        "PrimaryUsagePage": 1, "PrimaryUsage": 6]
                    data.append(try JSONSerialization.data(withJSONObject: record))
                    data.append(0x0A)
                }
            case "dump":
                // Both services have voice-only protection. Before a later model
                // lookup expands ownership, another utility remaps an ordinary key.
                if !changedByOtherTool,
                   current.values.allSatisfy({ $0.contains { $0.source == 0x70000003E && $0.destination == 0 } }) {
                    current[1]?.removeAll { $0.source == up }
                    if !removingMapping { current[1]?.append(latest) }
                    changedByOtherTool = true
                    resolved = true
                    try pipe.fileHandleForWriting.write(contentsOf: Data("mapping\n".utf8))
                }
                let records: [[String: Any]] = current.map { id, mappings in
                    ["IORegistryEntryID": id, "ServiceFilterDebug": [[
                        "name": "com.apple.iokit.hid.IOHIDKeyboardFilter",
                        "plugin": ["UserKeyMapping": mappings.map { ["Src": $0.source, "Dst": $0.destination] }]]]]
                }
                return try PropertyListSerialization.data(fromPropertyList: ["ServiceRecords": records], format: .xml, options: 0)
            case "property":
                let match = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as? [String: Int])
                let id = try XCTUnwrap(match["LocationID"])
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[4].utf8)) as? [String: [[String: UInt64]]])
                let requested = try XCTUnwrap(body["UserKeyMapping"]).map {
                    RemoteKeyMapping(source: $0["HIDKeyboardModifierMappingSrc"]!, destination: $0["HIDKeyboardModifierMappingDst"]!)
                }
                let isExpansion = id == 1 && requested.contains(.init(source: up, destination: 0)) && !expanded
                if isExpansion {
                    expanded = true
                    try pipe.fileHandleForWriting.close()
                    let data = try Data(contentsOf: directory.appendingPathComponent("remote-volume-restore.json"))
                    let snapshots = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                    let original = try XCTUnwrap(snapshots.first { ($0["registryID"] as? NSNumber)?.intValue == 1 }?["original"] as? [[String: UInt64]])
                    XCTAssertEqual(original.first { $0["source"] == up }?["destination"], removingMapping ? nil : latest.destination,
                                   "The new baseline must be journaled before writing to HID")
                    if failingWrite == 1 { throw NSError(domain: "injectedBeforeWrite", code: 1) }
                }
                current[id] = requested
                if isExpansion, failingWrite == 2 { throw NSError(domain: "injectedAfterWrite", code: 2) }
                return Data()
            default: throw NSError(domain: "unexpectedCommand", code: 1)
            }
        }
        XCTAssertTrue(worker.run())
        XCTAssertTrue(expanded)
        XCTAssertEqual(current[1], removingMapping ? [] : [latest], "Restore must retain the mapping that existed when ordinary-key ownership began")
    }
}
