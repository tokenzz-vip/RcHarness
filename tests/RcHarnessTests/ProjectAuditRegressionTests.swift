import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class ProjectAuditRegressionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "RcHarness.AuditRegression." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testOneShotChordRetainsHeldKeyWithoutLeakingItsModifiers() {
        for heldShortcut in [RecordedShortcut(keyCode: VirtualKey.returnKey, modifiers: 0, label: "Enter"),
                             RecordedShortcut(keyCode: VirtualKey.returnKey,
                                modifiers: CGEventFlags.maskSecondaryFn.rawValue, label: "Fn Enter")] {
            var events: [CGEvent] = []
            let sender = SystemEventSender(postEvent: { events.append($0) })
            sender.sendShortcut(heldShortcut, pressed: true)
            let action = ButtonMapping(action: .recordedShortcut, shortcut: RecordedShortcut(
                keyCode: VirtualKey.returnKey, modifiers: CGEventFlags.maskCommand.rawValue, label: "Command Enter"))
            for _ in 0..<2 { sender.send(action, pressed: true); sender.send(action, pressed: false) }
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyDown, .keyDown])
            XCTAssertTrue(events[1].flags.contains(.maskCommand))
            XCTAssertEqual(events[0].getIntegerValueField(.eventSourceStateID), events[1].getIntegerValueField(.eventSourceStateID))
            sender.send(ButtonMapping(action: .arrowRight), pressed: true)
            sender.send(ButtonMapping(action: .arrowRight), pressed: false)
            XCTAssertFalse(events[3].flags.contains(.maskCommand), "A one-shot must not retain Command")
            sender.sendShortcut(heldShortcut, pressed: false)
            XCTAssertEqual(events.last?.type, .keyUp)
            XCTAssertEqual(events.first?.getIntegerValueField(.eventSourceStateID), events.last?.getIntegerValueField(.eventSourceStateID))
            XCTAssertFalse(events.last!.flags.contains(.maskSecondaryFn))
        }
    }

    func testIdenticalOneShotStillFiresWhileTheSameNonmodifierIsHeld() {
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        let shortcut = RecordedShortcut(keyCode: VirtualKey.returnKey, modifiers: 0, label: "Enter")
        sender.sendShortcut(shortcut, pressed: true)
        sender.send(ButtonMapping(action: .recordedShortcut, shortcut: shortcut), pressed: true)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyDown])
        sender.sendShortcut(shortcut, pressed: false)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyDown, .keyUp])
    }

    func testOverlappingHeldChordsReleaseOnlyAfterTheFinalOwnerInEitherOrder() {
        let enter = RecordedShortcut(keyCode: VirtualKey.returnKey, modifiers: 0, label: "Enter")
        let commandEnter = RecordedShortcut(keyCode: VirtualKey.returnKey,
            modifiers: CGEventFlags.maskCommand.rawValue, label: "Command Enter")
        for releasingPlainFirst in [false, true] {
            var events: [CGEvent] = []
            let sender = SystemEventSender(postEvent: { events.append($0) })
            sender.sendShortcut(enter, pressed: true)
            sender.sendShortcut(commandEnter, pressed: true)
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyDown])
            XCTAssertTrue(events.last!.flags.contains(.maskCommand))
            sender.sendShortcut(releasingPlainFirst ? enter : commandEnter, pressed: false)
            XCTAssertEqual(events.count, 2)
            sender.sendShortcut(releasingPlainFirst ? commandEnter : enter, pressed: false)
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyDown, .keyUp])
            XCTAssertFalse(events.last!.flags.contains(.maskCommand))
        }
    }

    func testScreenshotDoesNotReleaseAnAlreadyHeldFourKey() {
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        let four = RecordedShortcut(keyCode: VirtualKey.four, modifiers: 0, label: "4")
        sender.sendShortcut(four, pressed: true)
        sender.send(ButtonMapping(action: .screenshot), pressed: true)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyDown])
        XCTAssertTrue(events.last!.flags.contains([.maskCommand, .maskShift]))
        sender.sendShortcut(four, pressed: false)
        XCTAssertEqual(events.last?.type, .keyUp)
        XCTAssertFalse(events.last!.flags.contains(.maskCommand))
    }

    func testV4MigrationPreservesEveryRemotesBindingUnbindingAndSelection() throws {
        var changed = RemoteMapping.defaults
        changed[.buttonA] = ButtonMapping(action: .paste)
        let profile = SavedKeyProfile(name: "自定义旧方案", mapping: changed)
        var retired = HarnessConfiguration(id: "antigravity", name: "Antigravity")
        retired.isEnabled = false
        var configurations: [String: RemoteKeyConfiguration] = [:]
        for (index, remote) in RemoteProfiles.all.enumerated() {
            configurations[remote.id] = RemoteKeyConfiguration(profiles: [profile],
                harnessProfileIDs: index == 0 ? [:] : ["antigravity": profile.id],
                initializedHarnessIDs: ["antigravity"], globalButtons: GlobalButtonSettings(),
                selectedProfileID: profile.id, selectedHarnessID: index == 0 ? nil : "antigravity")
        }
        let backup = SettingsBackup(version: 4, mapping: .defaults, profiles: [], macros: [], phrases: [],
            harnesses: [retired], remoteKeyConfigurations: configurations)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        try model.applyConfiguration(backup)
        for (index, remote) in RemoteProfiles.all.enumerated() {
            model.selectRemoteProfile(remote.id)
            let harness = try XCTUnwrap(model.harnesses.first { $0.id == "deepseek" })
            XCTAssertTrue(harness.didInitializeDefaultProfile)
            XCTAssertFalse(harness.isEnabled)
            XCTAssertEqual(harness.profileID, index == 0 ? nil : profile.id)
            XCTAssertEqual(model.profiles.first { $0.id == profile.id }, profile)
        }
        let restarted = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for (index, remote) in RemoteProfiles.all.enumerated() {
            restarted.selectRemoteProfile(remote.id)
            XCTAssertEqual(restarted.harnesses.first { $0.id == "deepseek" }?.profileID, index == 0 ? nil : profile.id)
        }
    }

    func testV4MigrationRetainsEnabledHarnessSelectionAtStartup() throws {
        let profile = SavedKeyProfile(name: "旧方案", mapping: .defaults)
        let configuration = RemoteKeyConfiguration(profiles: [profile], harnessProfileIDs: ["antigravity": profile.id],
            initializedHarnessIDs: ["antigravity"], globalButtons: GlobalButtonSettings(),
            selectedProfileID: profile.id, selectedHarnessID: "antigravity")
        SettingsStorage.save([HarnessConfiguration(id: "antigravity", name: "Antigravity")], SettingsKeys.Stored.harnesses, defaults: defaults)
        SettingsStorage.save([RemoteProfiles.xiaomiRC003.id: configuration], SettingsKeys.Stored.remoteKeyConfigurations, defaults: defaults)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.selectedHarnessID, "deepseek")
        XCTAssertEqual(model.selectedProfileID, profile.id)
        XCTAssertEqual(model.harnesses.first { $0.id == "deepseek" }?.profileID, profile.id)
    }

    func testExplicitReplacementUnbindingWinsOverRetiredBinding() {
        let configuration = RemoteKeyConfiguration(profiles: [], harnessProfileIDs: ["antigravity": UUID()],
            initializedHarnessIDs: ["antigravity", "deepseek"], globalButtons: GlobalButtonSettings(),
            selectedProfileID: nil, selectedHarnessID: nil).normalized()
        XCTAssertTrue(configuration.harnessProfileIDs.isEmpty)
        XCTAssertEqual(configuration.initializedHarnessIDs, ["deepseek"])
    }

    func testNameRepairsPreserveIDsMappingsBindingsAndReservedSuffixesAcrossRemotes() throws {
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .copy)
        let profiles = [SavedKeyProfile(name: "Work", mapping: mapping),
                        SavedKeyProfile(name: " work ", mapping: .defaults),
                        SavedKeyProfile(name: "Work 2", mapping: .defaults),
                        SavedKeyProfile(name: " \n ", mapping: mapping)]
        let configurations = Dictionary(uniqueKeysWithValues: RemoteProfiles.all.map { remote in
            (remote.id, RemoteKeyConfiguration(profiles: profiles, harnessProfileIDs: ["codex": profiles[1].id],
                initializedHarnessIDs: ["codex"], globalButtons: GlobalButtonSettings(),
                selectedProfileID: profiles[1].id, selectedHarnessID: "codex"))
        })
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        try model.applyConfiguration(SettingsBackup(version: 4, mapping: .defaults, profiles: [], macros: [], phrases: [],
            harnesses: HarnessConfiguration.defaults, remoteKeyConfigurations: configurations))
        let backup = model.configurationBackup()
        for remote in RemoteProfiles.all {
            let configuration = try XCTUnwrap(backup.remoteKeyConfigurations?[remote.id])
            XCTAssertEqual(configuration.profiles.filter { profiles.map(\.id).contains($0.id) }.map(\.name),
                           ["Work", "work 3", "Work 2", "新方案"])
            XCTAssertEqual(configuration.harnessProfileIDs["codex"], profiles[1].id)
            model.selectRemoteProfile(remote.id)
            for profile in profiles {
                XCTAssertEqual(model.profiles.first { $0.id == profile.id }?.mapping, profile.mapping)
            }
        }
        let reloaded = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(reloaded.profiles, model.profiles)
        XCTAssertEqual(SavedKeyProfile.normalizingNames(in: model.profiles), model.profiles, "Repairs must be idempotent")
    }

    func testImportReportsRepairedNamesAlongsideDanglingReferences() throws {
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .phrase, referenceID: UUID().uuidString)
        let profiles = [SavedKeyProfile(name: "Work", mapping: mapping), SavedKeyProfile(name: "work", mapping: .defaults)]
        let backup = SettingsBackup(version: 3, mapping: .defaults, profiles: profiles, macros: [], phrases: [])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(backup).write(to: url)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.importConfiguration(from: url)
        XCTAssertTrue(model.actionMessage.contains("已修复 1 个方案名称"))
        XCTAssertTrue(model.actionMessage.contains("1 处常用语或组合动作引用已失效"))
        XCTAssertEqual(model.profiles.first { $0.id == profiles[1].id }?.name, "work 2")
    }

    func testRepairedBuiltInNamesRetainProtectionAndResetWithoutProtectingCustomSuffixes() throws {
        let profiles = [SavedKeyProfile(name: "Codex", mapping: .defaults),
                        SavedKeyProfile(name: " codex ", mapping: .defaults),
                        SavedKeyProfile(name: "Codex 2", mapping: .defaults)]
        var harnesses = HarnessConfiguration.defaults
        for index in harnesses.indices { harnesses[index].didInitializeDefaultProfile = true }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        try model.applyConfiguration(SettingsBackup(version: 3, mapping: .defaults,
            profiles: profiles, macros: [], phrases: [], harnesses: harnesses))
        let repaired = try XCTUnwrap(model.profiles.first { $0.id == profiles[1].id })
        XCTAssertEqual(repaired.name, "codex 3")
        XCTAssertEqual(repaired.protectedBuiltInID, "codex")
        XCTAssertFalse(model.canDeleteProfile(repaired.id))
        XCTAssertTrue(model.canDeleteProfile(profiles[2].id), "An ordinary custom suffix remains deletable")
        model.activateProfile(repaired.id)
        model.resetMapping()
        XCTAssertEqual(model.mapping, .codexDefaults(macros: model.macros))
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        try model.applyConfiguration(backup)
        let restarted = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertFalse(restarted.canDeleteProfile(repaired.id))
        XCTAssertEqual(restarted.profiles.first { $0.id == repaired.id }?.protectedBuiltInID, "codex")
        XCTAssertTrue(restarted.renameProfile(repaired.id, name: repaired.name))
        XCTAssertFalse(restarted.canDeleteProfile(repaired.id))
        XCTAssertTrue(restarted.renameProfile(repaired.id, name: "我的工作方案"))
        XCTAssertTrue(restarted.canDeleteProfile(repaired.id), "An explicit rename keeps the existing custom-name behavior")
    }

    func testSelectionChangePublishesOneConsistentSnapshotAndNoOpDoesNotPublish() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        var mappings: [RemoteMapping] = []
        model.onMappingChange = { mappings.append($0) }
        model.activateHarness("codex")
        let profileID = try XCTUnwrap(model.harnesses.first { $0.id == "codex" }?.profileID)
        XCTAssertEqual(mappings.count, 1)
        let snapshot = try XCTUnwrap(SettingsStorage.load([String: RemoteKeyConfiguration].self,
            SettingsKeys.Stored.remoteKeyConfigurations, defaults: defaults)?[model.remoteProfile.id])
        XCTAssertEqual(snapshot.selectedHarnessID, "codex")
        XCTAssertEqual(snapshot.selectedProfileID, profileID)
        model.activateHarness("codex")
        XCTAssertEqual(mappings.count, 1)
        model.update(ButtonMapping(action: .paste), for: .buttonA, trigger: .single)
        XCTAssertEqual(mappings.last?[.buttonA].action, .paste)
        let restarted = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restarted.selectedHarnessID, "codex")
        XCTAssertEqual(restarted.selectedProfileID, profileID)
        XCTAssertEqual(restarted.mapping[.buttonA].action, .paste)
    }
}
