import XCTest
@testable import RcHarness

@MainActor
final class RemoteKeyConfigurationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "RcHarness.RemoteKeyConfigurationTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testSchemesBindingsAndGlobalsAreIsolatedAndPersistWithoutSwitchingAway() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.saveProfile(name: "工作")
        let xiaomiID = try XCTUnwrap(model.selectedProfileID)
        model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .single)
        model.bindProfile(xiaomiID, to: "codex")
        model.setGlobalInput(.menu)
        model.update(ButtonMapping(action: .paste), for: .menu, trigger: .double)
        model.activateHarness("codex")
        let xiaomiSchemes = model.profiles

        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertFalse(model.profiles.contains { $0.id == xiaomiID })
        XCTAssertNil(model.profileNameError("工作"))
        XCTAssertFalse(model.bindProfile(xiaomiID, to: "codex"))
        XCTAssertNil(model.duplicateProfile(xiaomiID))
        let selected = model.selectedProfileID
        model.activateProfile(xiaomiID)
        XCTAssertEqual(model.selectedProfileID, selected)
        XCTAssertEqual(model.globalButtons.input, .power)
        model.saveProfile(name: "工作")
        let googleID = try XCTUnwrap(model.selectedProfileID)
        model.update(ButtonMapping(action: .paste), for: .buttonA, trigger: .single)
        model.bindProfile(googleID, to: "codex")
        model.setGlobalInput(.youtube)
        model.activateHarness("codex")

        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.remoteProfile, RemoteProfiles.googleG9N9N)
        XCTAssertEqual(restored.selectedProfileID, googleID)
        XCTAssertEqual(restored.selectedHarnessID, "codex")
        XCTAssertEqual(restored.mapping[.buttonA].action, .paste)
        XCTAssertEqual(restored.globalButtons.input, .youtube)
        restored.selectRemoteProfile(RemoteProfiles.xiaomiRC003.id)
        XCTAssertEqual(restored.profiles, xiaomiSchemes)
        XCTAssertEqual(restored.selectedProfileID, xiaomiID)
        XCTAssertEqual(restored.selectedHarnessID, "codex")
        XCTAssertEqual(restored.mapping[.buttonA].action, .copy)
        XCTAssertEqual(restored.globalButtons.input, .menu)
        XCTAssertEqual(restored.effectiveMapping[.menu, .double].action, .paste)
        restored.matchApplication(nil, bundleIdentifier: "com.openai.codex")
        XCTAssertEqual(restored.selectedProfileID, xiaomiID)
        restored.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        restored.matchApplication(nil, bundleIdentifier: "com.openai.codex")
        XCTAssertEqual(restored.selectedProfileID, googleID)
    }

    func testDefaultMappingAndIntentionalUnbindingAreIndependent() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .double)
        model.bindProfile(nil, to: "codex")
        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertEqual(model.mapping[.buttonA, .double].action, .disabled)
        XCTAssertNotNil(model.harnesses.first { $0.id == "codex" }?.profileID)
        model.update(ButtonMapping(action: .paste), for: .buttonA, trigger: .double)
        model.selectRemoteProfile(RemoteProfiles.xiaomiRC003.id)
        XCTAssertEqual(model.mapping[.buttonA, .double].action, .copy)
        XCTAssertNil(model.harnesses.first { $0.id == "codex" }?.profileID)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertNil(restored.harnesses.first { $0.id == "codex" }?.profileID)
        restored.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertEqual(restored.mapping[.buttonA, .double].action, .paste)
    }

    func testLegacySchemesMigrateToSelectedRemoteOnly() throws {
        let legacy = SavedKeyProfile(name: "旧方案", mapping: .defaults)
        var codex = HarnessConfiguration.defaults[0]
        codex.profileID = legacy.id
        SettingsStorage.save([legacy], SettingsKeys.Stored.profiles, defaults: defaults)
        SettingsStorage.save([codex], SettingsKeys.Stored.harnesses, defaults: defaults)
        defaults.set(RemoteProfiles.googleG9N9N.id, forKey: SettingsKeys.selectedRemoteProfileID)
        defaults.set(legacy.id.uuidString, forKey: SettingsKeys.selectedProfileID)
        defaults.set(2, forKey: SettingsKeys.profileBindingsVersion)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.selectedProfileID, legacy.id)
        XCTAssertEqual(model.boundHarnesses(for: legacy.id).map(\.id), ["codex"])
        model.selectRemoteProfile(RemoteProfiles.xiaomiRC003.id)
        XCTAssertFalse(model.profiles.contains { $0.id == legacy.id })
        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertTrue(model.profiles.contains(legacy))
    }

    func testBackupRestoresAllRemoteSchemesRegardlessOfSelectedRemote() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.saveProfile(name: "小米方案")
        let xiaomiID = try XCTUnwrap(model.selectedProfileID)
        model.bindProfile(xiaomiID, to: "cursor")
        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        model.saveProfile(name: "Google 方案")
        let googleID = try XCTUnwrap(model.selectedProfileID)
        model.bindProfile(googleID, to: "cursor")
        model.setGlobalInput(.netflix)
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        XCTAssertEqual(backup.remoteKeyConfigurations?.count, 2)
        model.selectRemoteProfile(RemoteProfiles.xiaomiRC003.id)
        try model.applyConfiguration(backup)
        XCTAssertTrue(model.profiles.contains { $0.id == xiaomiID })
        XCTAssertFalse(model.profiles.contains { $0.id == googleID })
        XCTAssertEqual(model.boundHarnesses(for: xiaomiID).map(\.id), ["cursor"])
        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertTrue(model.profiles.contains { $0.id == googleID })
        XCTAssertFalse(model.profiles.contains { $0.id == xiaomiID })
        XCTAssertEqual(model.boundHarnesses(for: googleID).map(\.id), ["cursor"])
        XCTAssertEqual(model.globalButtons.input, .netflix)
        model.selectRemoteProfile(RemoteProfiles.xiaomiRC001.id)
        try model.applyConfiguration(backup)
        XCTAssertFalse(model.profiles.contains { $0.id == googleID || $0.id == xiaomiID })
    }
}
