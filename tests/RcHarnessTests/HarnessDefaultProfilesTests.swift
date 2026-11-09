import XCTest
@testable import RcHarness

@MainActor
final class HarnessDefaultProfilesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "RcHarness.HarnessDefaultProfilesTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testEveryRemoteHasFiveIndependentHarnessDefaults() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        var configurations: [String: [SavedKeyProfile]] = [:]
        var generatedIDs: Set<UUID> = []
        for remote in RemoteProfiles.all {
            model.selectRemoteProfile(remote.id)
            XCTAssertEqual(model.profiles.count, 6)
            XCTAssertEqual(model.selectedProfileID, SavedKeyProfile.defaultID)
            XCTAssertNil(model.selectedHarnessID)
            XCTAssertEqual(model.defaultMapping, .defaults)
            for builtIn in HarnessConfiguration.defaults {
                let harness = try XCTUnwrap(model.harnesses.first { $0.id == builtIn.id })
                let profile = try XCTUnwrap(model.profiles.first { $0.id == harness.profileID })
                XCTAssertEqual(profile.name, builtIn.name + " 按键方案")
                XCTAssertTrue(harness.didInitializeDefaultProfile)
                XCTAssertTrue(generatedIDs.insert(profile.id).inserted)
                XCTAssertEqual(profile.mapping, builtIn.id == "codex" ? .codexDefaults(macros: model.macros) : .defaults)
                model.activateHarness(harness.id)
                XCTAssertEqual(model.selectedProfileID, profile.id)
                XCTAssertEqual(model.mapping, profile.mapping)
            }
            configurations[remote.id] = model.profiles
        }
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        try restored.applyConfiguration(backup)
        for remote in RemoteProfiles.all {
            restored.selectRemoteProfile(remote.id)
            XCTAssertEqual(restored.profiles, configurations[remote.id])
            XCTAssertEqual(restored.harnesses.compactMap(\.profileID).count, 5)
        }
    }

    func testUpgradeCompletesEveryRemoteWithoutOverwritingCustomizationsOrRepeatingInitialization() throws {
        var oldConfigurations: [String: RemoteKeyConfiguration] = [:]
        for remote in RemoteProfiles.all {
            var customMapping = RemoteMapping.defaults
            customMapping[.buttonA] = ButtonMapping(action: .copy)
            let codex = SavedKeyProfile(name: "我的 Codex", mapping: customMapping)
            let workBuddy = SavedKeyProfile(name: "我的 WorkBuddy", mapping: customMapping)
            let claude = SavedKeyProfile(name: "已有 Claude", mapping: customMapping)
            let conflict = SavedKeyProfile(name: "Cursor 按键方案", mapping: customMapping)
            var globals = GlobalButtonSettings()
            globals.double = ButtonMapping(action: .paste)
            oldConfigurations[remote.id] = RemoteKeyConfiguration(
                profiles: [SavedKeyProfile(id: SavedKeyProfile.defaultID, name: "默认方案", mapping: customMapping),
                           codex, workBuddy, claude, conflict],
                harnessProfileIDs: ["workbuddy": workBuddy.id, "claude": claude.id],
                initializedHarnessIDs: ["codex", "workbuddy"], globalButtons: globals,
                selectedProfileID: claude.id, selectedHarnessID: "claude")
        }
        var harnesses = HarnessConfiguration.defaults
        harnesses[harnesses.firstIndex { $0.id == "cursor" }!].isEnabled = false
        SettingsStorage.save(harnesses, SettingsKeys.Stored.harnesses, defaults: defaults)
        SettingsStorage.save(oldConfigurations, SettingsKeys.Stored.remoteKeyConfigurations, defaults: defaults)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        var upgradedProfiles: [String: [SavedKeyProfile]] = [:]
        for remote in RemoteProfiles.all {
            model.selectRemoteProfile(remote.id)
            let old = try XCTUnwrap(oldConfigurations[remote.id])
            XCTAssertEqual(model.profiles.count, old.profiles.count + 2)
            for profile in old.profiles {
                XCTAssertEqual(model.profiles.first { $0.id == profile.id }, profile)
            }
            XCTAssertEqual(model.selectedProfileID, old.selectedProfileID)
            XCTAssertEqual(model.selectedHarnessID, old.selectedHarnessID)
            XCTAssertEqual(model.mapping[.buttonA].action, .copy)
            XCTAssertEqual(model.globalButtons, old.globalButtons.normalized(for: remote))
            XCTAssertNil(model.harnesses.first { $0.id == "codex" }?.profileID)
            XCTAssertEqual(model.harnesses.first { $0.id == "claude" }?.profileID, old.harnessProfileIDs["claude"])
            XCTAssertEqual(model.harnesses.first { $0.id == "workbuddy" }?.profileID, old.harnessProfileIDs["workbuddy"])
            XCTAssertEqual(model.harnesses.first { $0.id == "cursor" }?.isEnabled, false)
            for (id, name) in [("cursor", "Cursor 按键方案 2"), ("deepseek", "DeepSeek 按键方案")] {
                let harness = try XCTUnwrap(model.harnesses.first { $0.id == id })
                let profile = try XCTUnwrap(model.profiles.first { $0.id == harness.profileID })
                XCTAssertEqual(profile.name, name)
                XCTAssertEqual(profile.mapping, .defaults)
                model.activateProfile(profile.id)
                model.update(ButtonMapping(action: .paste), for: .buttonA, trigger: .single)
            }
            XCTAssertTrue(model.harnesses.allSatisfy(\.didInitializeDefaultProfile))
            for id in ["claude", "cursor", "deepseek"] {
                XCTAssertTrue(model.bindProfile(nil, to: id))
            }
            upgradedProfiles[remote.id] = model.profiles
        }
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for importing in [false, true] {
            if importing { try restored.applyConfiguration(backup) }
            for remote in RemoteProfiles.all {
                restored.selectRemoteProfile(remote.id)
                XCTAssertEqual(restored.profiles, upgradedProfiles[remote.id])
                XCTAssertEqual(restored.harnesses.compactMap(\.profileID).count, 1)
                XCTAssertEqual(restored.harnesses.first { $0.id == "workbuddy" }?.profileID,
                               oldConfigurations[remote.id]?.harnessProfileIDs["workbuddy"])
            }
        }
    }
}
