import XCTest
@testable import RcHarness

@MainActor
final class HarnessTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "RcHarness.HarnessTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeProfile(_ model: RemoteDashboardModel, name: String = "工作") -> UUID {
        model.saveProfile(name: name)
        return model.selectedProfileID!
    }

    func testWorkBuddyMatchesCurrentAndLegacyAppsAndPreservesBindingAfterRestart() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let harness = try XCTUnwrap(model.harnesses.first { $0.id == "workbuddy" })
        XCTAssertEqual(harness.bundleIdentifier, "com.tencent.workbuddy.mac")
        XCTAssertTrue(harness.isBuiltIn)
        XCTAssertTrue(harness.isEnabled)
        let initialProfileID = try XCTUnwrap(harness.profileID)
        let initialProfile = try XCTUnwrap(model.profiles.first { $0.id == initialProfileID })
        XCTAssertEqual(initialProfile.name, "WorkBuddy 按键方案")
        XCTAssertEqual(initialProfile.mapping, .defaults)
        XCTAssertTrue(harness.didInitializeDefaultProfile)
        XCTAssertEqual(model.selectedProfileID, SavedKeyProfile.defaultID)
        let profile = makeProfile(model)
        model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .single)
        XCTAssertTrue(model.bindProfile(profile, to: harness.id))
        for identifier in ["com.tencent.workbuddy.mac", "COM.WORKBUDDY.WORKBUDDY"] {
            model.matchApplication("/Applications/WorkBuddy.app", bundleIdentifier: identifier)
            XCTAssertEqual(model.selectedHarnessID, harness.id)
            XCTAssertEqual(model.selectedProfileID, profile)
            XCTAssertEqual(model.mapping[.buttonA].action, .copy)
        }
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.harnesses, model.harnesses)
        XCTAssertEqual(restored.selectedHarnessID, harness.id)
        restored.setHarnessEnabled(harness.id, enabled: false)
        restored.matchApplication(nil, bundleIdentifier: "com.tencent.workbuddy.mac")
        XCTAssertNil(restored.selectedHarnessID)
        XCTAssertEqual(restored.harnesses.first { $0.id == harness.id }?.profileID, profile)
        XCTAssertFalse(harness.matches(applicationPath: "/Applications/WorkBuddy.app", bundleIdentifier: "other.app"))
    }

    func testExistingConfigurationAndImportGainWorkBuddyOnlyOnce() throws {
        let profile = SavedKeyProfile(name: "已有方案", mapping: .defaults)
        var previous = HarnessConfiguration.defaults.filter { $0.id != "workbuddy" }
        previous[0].profileID = profile.id
        previous[1].isEnabled = false
        SettingsStorage.save([profile], SettingsKeys.Stored.profiles, defaults: defaults)
        SettingsStorage.save(previous, SettingsKeys.Stored.harnesses, defaults: defaults)
        defaults.set(2, forKey: SettingsKeys.profileBindingsVersion)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        func assertPreviousHarnessesPreserved() throws {
            for original in previous {
                let current = try XCTUnwrap(model.harnesses.first { $0.id == original.id })
                var expected = original
                expected.didInitializeDefaultProfile = true
                if expected.profileID == nil {
                    expected.profileID = try XCTUnwrap(current.profileID)
                    XCTAssertEqual(model.profiles.first { $0.id == current.profileID }?.name, original.name + " 按键方案")
                }
                XCTAssertEqual(current, expected)
            }
        }
        try assertPreviousHarnessesPreserved()
        XCTAssertEqual(model.harnesses.last?.id, "workbuddy")
        let workBuddyProfileID = try XCTUnwrap(model.harnesses.last?.profileID)
        XCTAssertEqual(model.profiles.first { $0.id == workBuddyProfileID }?.name, "WorkBuddy 按键方案")
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.harnesses, model.harnesses)
        try model.applyConfiguration(SettingsBackup(mapping: .defaults, profiles: [profile], macros: [], phrases: [], harnesses: previous))
        try assertPreviousHarnessesPreserved()
        XCTAssertEqual(model.harnesses.last?.id, "workbuddy")
        XCTAssertEqual(model.profiles.filter { $0.name == "WorkBuddy 按键方案" }.count, 1)
        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).harnesses, model.harnesses)
    }

    func testPreviouslyAddedWorkBuddyGainsIndependentDefaultsWithoutChangingGlobalsOrSelection() throws {
        let profile = SavedKeyProfile(name: "我的输入", mapping: .defaults)
        var workBuddy = try XCTUnwrap(HarnessConfiguration.defaults.first { $0.id == "workbuddy" })
        workBuddy.isEnabled = false
        // Encode the previous schema, where WorkBuddy had no default-profile marker.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(workBuddy)) as? [String: Any])
        json.removeValue(forKey: "didInitializeDefaultProfile")
        defaults.set(try JSONSerialization.data(withJSONObject: [json]), forKey: "RcHarness.harnesses")
        SettingsStorage.save([profile], SettingsKeys.Stored.profiles, defaults: defaults)
        var globals = GlobalButtonSettings()
        globals.voice = ButtonMapping(action: .fn)
        globals.voiceFnTap = true
        SettingsStorage.save(globals, SettingsKeys.Stored.globalButtons, defaults: defaults)
        defaults.set(profile.id.uuidString, forKey: SettingsKeys.selectedProfileID)
        defaults.set(2, forKey: SettingsKeys.profileBindingsVersion)

        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let harness = try XCTUnwrap(model.harnesses.first)
        let generated = try XCTUnwrap(model.profiles.first { $0.id == harness.profileID })
        XCTAssertEqual(generated.name, "WorkBuddy 按键方案")
        XCTAssertEqual(generated.mapping, .defaults)
        XCTAssertFalse(harness.isEnabled)
        XCTAssertEqual(model.selectedProfileID, profile.id)
        XCTAssertNil(model.selectedHarnessID)
        XCTAssertEqual(model.globalButtons, globals.normalized())
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.profiles, model.profiles)
        XCTAssertEqual(restored.harnesses, model.harnesses)
    }

    func testWorkBuddyInitializationPreservesExistingBindingAndConflictingProfileNames() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .paste)
        let existing = SavedKeyProfile(name: "WorkBuddy 按键方案", mapping: mapping)
        var harness = try XCTUnwrap(HarnessConfiguration.defaults.first { $0.id == "workbuddy" })
        harness.profileID = existing.id
        try model.applyConfiguration(SettingsBackup(mapping: .defaults, profiles: [existing], macros: [], phrases: [], harnesses: [harness]))
        XCTAssertEqual(model.profiles.count, 6)
        XCTAssertEqual(model.profiles.first { $0.id == existing.id }, existing)
        XCTAssertEqual(model.harnesses.first?.profileID, existing.id)
        XCTAssertEqual(model.harnesses.first?.didInitializeDefaultProfile, true)

        harness.profileID = nil
        try model.applyConfiguration(SettingsBackup(mapping: .defaults, profiles: [existing], macros: [], phrases: [], harnesses: [harness]))
        let generatedID = try XCTUnwrap(model.harnesses.first?.profileID)
        XCTAssertNotEqual(generatedID, existing.id)
        let generated = try XCTUnwrap(model.profiles.first { $0.id == generatedID })
        XCTAssertEqual(generated.name, "WorkBuddy 按键方案 2")
        XCTAssertEqual(generated.mapping, .defaults)
        XCTAssertEqual(model.profiles.first { $0.id == existing.id }, existing)
    }

    func testUnboundWorkBuddyDefaultProfileRemainsProtectedAcrossRestartAndBackup() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profileID = try XCTUnwrap(model.harnesses.first { $0.id == "workbuddy" }?.profileID)
        XCTAssertTrue(model.bindProfile(nil, to: "workbuddy"))
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertNil(restored.harnesses.first { $0.id == "workbuddy" }?.profileID)
        XCTAssertEqual(restored.profiles, model.profiles)
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        try model.applyConfiguration(backup)
        XCTAssertNil(model.harnesses.first { $0.id == "workbuddy" }?.profileID)
        XCTAssertEqual(model.profiles, restored.profiles)

        XCTAssertTrue(model.bindProfile(profileID, to: "workbuddy"))
        XCTAssertFalse(model.canDeleteProfile(profileID))
        model.deleteProfile(profileID)
        XCTAssertEqual(model.harnesses.first { $0.id == "workbuddy" }?.profileID, profileID)
        XCTAssertTrue(model.profiles.contains { $0.id == profileID })
        XCTAssertTrue(model.bindProfile(nil, to: "workbuddy"))
        XCTAssertFalse(model.canDeleteProfile(profileID))
        model.deleteProfile(profileID)
        XCTAssertEqual(model.profiles, restored.profiles)
        let afterUnbinding = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertNil(afterUnbinding.harnesses.first { $0.id == "workbuddy" }?.profileID)
        XCTAssertFalse(afterUnbinding.canDeleteProfile(profileID))
        afterUnbinding.deleteProfile(profileID)
        XCTAssertEqual(afterUnbinding.profiles, restored.profiles)
        try model.applyConfiguration(backup)
        XCTAssertFalse(model.canDeleteProfile(profileID))
        model.deleteProfile(profileID)
        XCTAssertEqual(model.profiles, restored.profiles)
    }

    func testUnboundBuiltInNamesAreProtectedAfterImportAndRestart() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let names = ["Codex", "Claude", "Cursor", "DeepSeek", "WorkBuddy"]
        let profiles = names.flatMap { name in
            [name, name + " 按键方案", " \(name.lowercased()) \n", " \(name.lowercased()) 按键方案 \n"]
                .map { SavedKeyProfile(name: $0, mapping: .defaults) }
        }
        var harnesses = HarnessConfiguration.defaults
        for index in harnesses.indices {
            harnesses[index].isEnabled = false
            harnesses[index].didInitializeDefaultProfile = true
        }
        try model.applyConfiguration(SettingsBackup(mapping: .defaults, profiles: profiles, macros: [], phrases: [], harnesses: harnesses))
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for dashboard in [model, restored] {
            let originalProfiles = dashboard.profiles
            for profile in profiles {
                XCTAssertTrue(dashboard.boundHarnesses(for: profile.id).isEmpty)
                XCTAssertFalse(dashboard.canDeleteProfile(profile.id), profile.name)
                dashboard.deleteProfile(profile.id)
            }
            XCTAssertEqual(dashboard.profiles, originalProfiles)
        }
    }

    func testExistingWorkBuddyEntriesArePreservedWithoutDuplicatesOnImportAndRestart() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profile = SavedKeyProfile(name: "我的方案", mapping: .defaults)
        for identifier in ["com.tencent.workbuddy.mac", "COM.WORKBUDDY.WORKBUDDY"] {
            let existing = HarnessConfiguration(id: "my-workbuddy", name: "我的 WorkBuddy", bundleIdentifier: identifier,
                                                applicationPath: "/Applications/WorkBuddy.app", isEnabled: false, profileID: profile.id)
            try model.applyConfiguration(SettingsBackup(mapping: .defaults, profiles: [profile], macros: [], phrases: [], harnesses: [existing]))
            XCTAssertEqual(model.harnesses.filter { $0.id == existing.id }, [existing])
            XCTAssertFalse(model.harnesses.contains { $0.id == "workbuddy" })
            XCTAssertEqual(model.harnesses.count, 5)
            XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).harnesses, model.harnesses)
        }
    }

    func testRetiredBuiltInMigratesOnRestartAndMatchesDeepSeek() {
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .copy)
        let profile = SavedKeyProfile(name: "Antigravity 按键方案", mapping: mapping)
        let retired = HarnessConfiguration(id: "antigravity", name: "Antigravity",
                                           bundleIdentifier: "com.google.antigravity",
                                           applicationPath: "/Applications/Antigravity.app", profileID: profile.id)
        SettingsStorage.save([profile], SettingsKeys.Stored.profiles, defaults: defaults)
        SettingsStorage.save([retired], SettingsKeys.Stored.harnesses, defaults: defaults)
        defaults.set("antigravity", forKey: SettingsKeys.selectedHarnessID)
        defaults.set(2, forKey: SettingsKeys.profileBindingsVersion)

        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.harnesses.map(\.id), ["deepseek", "codex", "claude", "cursor", "workbuddy"])
        XCTAssertEqual(model.harnesses.first?.name, "DeepSeek")
        XCTAssertTrue(model.harnesses.first!.isBuiltIn)
        XCTAssertNil(model.harnesses.first?.applicationPath)
        XCTAssertEqual(model.selectedHarnessID, "deepseek")
        XCTAssertEqual(model.profiles.first(where: { $0.id == profile.id })?.name, "DeepSeek 按键方案")
        XCTAssertEqual(model.mapping, mapping)
        model.matchApplication(nil, bundleIdentifier: "com.google.antigravity")
        XCTAssertNil(model.selectedHarnessID)
        model.matchApplication(nil, bundleIdentifier: "com.deepseek.dsh")
        XCTAssertEqual(model.selectedHarnessID, "deepseek")
        XCTAssertEqual(model.mapping, mapping)

        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.harnesses, model.harnesses)
        XCTAssertEqual(restored.profiles, model.profiles)
        XCTAssertEqual(restored.selectedHarnessID, "deepseek")
    }

    func testAlreadyMigratedDeepSeekRenamesOnlyItsLegacyProfileAndAvoidsNameConflicts() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .copy)
        let legacy = SavedKeyProfile(name: "Antigravity 按键方案", mapping: mapping)
        let existing = SavedKeyProfile(name: "DeepSeek 按键方案", mapping: .defaults)
        let unbound = SavedKeyProfile(name: "Antigravity 按键方案", mapping: .defaults)
        var harness = try XCTUnwrap(HarnessConfiguration.defaults.first(where: { $0.id == "deepseek" }))
        harness.profileID = legacy.id
        let backup = SettingsBackup(mapping: .defaults, profiles: [legacy, existing, unbound], macros: [], phrases: [], harnesses: [harness])
        try model.applyConfiguration(backup)
        let migrated = try XCTUnwrap(model.profiles.first(where: { $0.id == legacy.id }))
        XCTAssertTrue(migrated.name.hasPrefix("DeepSeek 按键方案"))
        XCTAssertNotEqual(migrated.name, existing.name)
        XCTAssertEqual(migrated.mapping, mapping)
        XCTAssertEqual(model.profiles.first(where: { $0.id == unbound.id }), unbound)
        model.matchApplication(nil, bundleIdentifier: "com.deepseek.dsh")
        XCTAssertEqual(model.selectedProfileID, legacy.id)
        XCTAssertEqual(model.mapping, mapping)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.profiles, model.profiles)

        var custom = legacy
        custom.name = "我的工作方案"
        try model.applyConfiguration(SettingsBackup(mapping: .defaults, profiles: [custom], macros: [], phrases: [], harnesses: [harness]))
        XCTAssertEqual(model.profiles.first(where: { $0.id == legacy.id }), custom)
    }

    func testRetiredBuiltInImportPreservesDisabledStateAndLegacyMapping() throws {
        var mapping = RemoteMapping.defaults
        mapping[.power] = ButtonMapping(action: .paste)
        let retired = HarnessConfiguration(id: "antigravity", name: "Antigravity",
                                           bundleIdentifier: "com.google.antigravity", isEnabled: false,
                                           legacyMapping: mapping, hasLegacyMapping: true)
        let backup = SettingsBackup(version: 1, mapping: .defaults, profiles: [], macros: [], phrases: [], harnesses: [retired])
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        try model.applyConfiguration(backup)
        let harness = try XCTUnwrap(model.harnesses.first)
        XCTAssertEqual(harness.id, "deepseek")
        XCTAssertFalse(harness.isEnabled)
        XCTAssertEqual(model.profiles.first(where: { $0.id == harness.profileID })?.mapping, mapping)
        model.matchApplication(nil, bundleIdentifier: "com.deepseek.dsh")
        XCTAssertNil(model.selectedHarnessID)
    }

    func testSchemeOwnsMappingsAndBindingRestoresAfterRestart() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.update(ButtonMapping(action: .paste), for: .buttonA, trigger: .single)
        let profile = makeProfile(model)
        XCTAssertTrue(model.bindProfile(profile, to: "codex"))
        model.activateHarness("codex")
        model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .single)
        model.update(ButtonMapping(action: .escape), for: .power, trigger: .single)
        XCTAssertEqual(model.profiles.first(where: { $0.id == profile })?.mapping[.power, .single].action, .disabled)
        XCTAssertEqual(model.effectiveMapping[.power, .single].action, .escape)
        // The legacy mapping stored on Harness is no longer edited or used.
        XCTAssertEqual(model.harnesses.first(where: { $0.id == "codex" })?.legacyMapping[.buttonA].action, .enter)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.selectedHarnessID, "codex")
        XCTAssertEqual(restored.selectedProfileID, profile)
        XCTAssertEqual(restored.mapping[.buttonA].action, .copy)
        XCTAssertEqual(restored.effectiveMapping[.power, .single].action, .escape)
        restored.activateProfile(nil)
        XCTAssertEqual(restored.mapping[.buttonA].action, .paste)
    }

    func testSharedBindingAllowsEveryHarnessAndReplacementOrUnbindingIsIndependent() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let first = makeProfile(model, name: "方案一")
        let second = makeProfile(model, name: "方案二")
        for harness in model.harnesses {
            XCTAssertTrue(model.bindProfile(first, to: harness.id))
        }
        XCTAssertEqual(model.boundHarnesses(for: first).map(\.id), model.harnesses.map(\.id))
        model.activateHarness("codex")
        XCTAssertTrue(model.bindProfile(second, to: "codex"))
        XCTAssertEqual(model.selectedProfileID, second)
        XCTAssertEqual(model.boundHarnesses(for: first).map(\.id), ["claude", "cursor", "deepseek", "workbuddy"])
        XCTAssertEqual(model.boundHarnesses(for: second).map(\.id), ["codex"])
        XCTAssertTrue(model.bindProfile(nil, to: "cursor"))
        XCTAssertEqual(model.selectedHarnessID, "codex")
        XCTAssertEqual(model.boundHarnesses(for: first).map(\.id), ["claude", "deepseek", "workbuddy"])
        XCTAssertTrue(model.bindProfile(nil, to: "codex"))
        XCTAssertNil(model.selectedHarnessID)
        XCTAssertEqual(model.selectedProfileID, SavedKeyProfile.defaultID)
        XCTAssertTrue(model.boundHarnesses(for: second).isEmpty)
        XCTAssertTrue(model.bindProfile(SavedKeyProfile.defaultID, to: "codex"))
        XCTAssertTrue(model.bindProfile(SavedKeyProfile.defaultID, to: "claude"))
        XCTAssertFalse(model.bindProfile(UUID(), to: "codex"))
        XCTAssertFalse(model.bindProfile(first, to: "missing-harness"))
        XCTAssertEqual(model.boundHarnesses(for: SavedKeyProfile.defaultID).map(\.id), ["codex", "claude"])
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.harnesses, model.harnesses)
    }

    func testSharedProfileEditsApplyWhenSwitchingBetweenHarnesses() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profile = makeProfile(model)
        model.bindProfile(profile, to: "codex")
        model.bindProfile(profile, to: "cursor")
        model.matchApplication(nil, bundleIdentifier: "com.openai.codex")
        model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .double)
        var applied: RemoteMapping?
        model.onMappingChange = { applied = $0 }
        model.matchApplication(nil, bundleIdentifier: "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(model.selectedHarnessID, "cursor")
        XCTAssertEqual(model.selectedProfileID, profile)
        XCTAssertEqual(applied?[.buttonA, .double].action, .copy)
        model.update(ButtonMapping(action: .paste), for: .power, trigger: .single)
        model.matchApplication(nil, bundleIdentifier: "com.openai.codex")
        XCTAssertEqual(model.selectedHarnessID, "codex")
        XCTAssertEqual(applied?[.power, .single].action, .paste)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.boundHarnesses(for: profile).map(\.id), ["codex", "cursor"])
        restored.activateHarness("cursor")
        XCTAssertEqual(restored.mapping[.buttonA, .double].action, .copy)
        XCTAssertEqual(restored.effectiveMapping[.power, .single].action, .paste)
    }

    func testAutoSwitchUsesOnlyEnabledBoundHarnessAndFallsBackToDefault() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profile = makeProfile(model)
        model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .single)
        XCTAssertTrue(model.bindProfile(profile, to: "codex"))
        model.matchApplication("/Applications/Codex.app", bundleIdentifier: "com.openai.codex")
        XCTAssertEqual(model.selectedHarnessID, "codex")
        XCTAssertEqual(model.selectedProfileID, profile)
        XCTAssertEqual(model.mapping[.buttonA].action, .copy)
        XCTAssertTrue(model.bindProfile(nil, to: "cursor"))
        model.matchApplication("/Applications/Cursor.app", bundleIdentifier: "com.todesktop.230313mzl4w4u92")
        XCTAssertNil(model.selectedHarnessID)
        XCTAssertEqual(model.selectedProfileID, SavedKeyProfile.defaultID)
        model.activateHarness("codex")
        model.setHarnessEnabled("codex", enabled: false)
        model.matchApplication("/Applications/Codex.app", bundleIdentifier: "com.openai.codex")
        XCTAssertEqual(model.selectedProfileID, SavedKeyProfile.defaultID)
        XCTAssertEqual(model.boundHarnesses(for: profile).map(\.id).first, "codex")
        model.setHarnessEnabled("codex", enabled: true)
        model.matchApplication(nil, bundleIdentifier: "com.openai.codex")
        XCTAssertEqual(model.selectedProfileID, profile)
        model.matchApplication(nil, bundleIdentifier: "other.app")
        XCTAssertEqual(model.selectedProfileID, SavedKeyProfile.defaultID)
    }

    func testMappingEditorKeepsTargetStableWhileReceivingRemoteAndAppEvents() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profile = makeProfile(model)
        model.bindProfile(profile, to: "codex")
        model.activateHarness("codex")
        model.selectedInput = .power
        model.selectedTrigger = .single
        model.editorVisible = true
        model.setInput(.buttonA, pressed: true)
        model.matchApplication(nil, bundleIdentifier: "other.app")
        XCTAssertEqual(model.selectedInput, .power)
        XCTAssertEqual(model.selectedTrigger, .single)
        XCTAssertTrue(model.pressedInputs.contains(.buttonA))
        XCTAssertEqual(model.selectedProfileID, profile)
        model.update(ButtonMapping(action: .copy), for: model.selectedInput, trigger: model.selectedTrigger)
        model.editorVisible = false
        model.setInput(.buttonA, pressed: false)
        model.setInput(.dpadUp, pressed: true)
        XCTAssertEqual(model.selectedInput, .dpadUp)
        model.matchApplication(nil, bundleIdentifier: "other.app")
        XCTAssertEqual(model.selectedProfileID, SavedKeyProfile.defaultID)
        model.activateProfile(profile)
        XCTAssertEqual(model.effectiveMapping[.power, .single].action, .copy)
    }

    func testBoundProfileCannotBeDeletedUntilAllHarnessesUnbind() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profile = makeProfile(model)
        model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .single)
        model.bindProfile(profile, to: "codex")
        model.bindProfile(profile, to: "cursor")
        let customID = model.addHarness(applicationURL: URL(fileURLWithPath: "/tmp/RcHarness-Test-Editor.app"))
        model.bindProfile(profile, to: customID)
        model.setHarnessEnabled(customID, enabled: false)
        model.activateHarness("codex")
        let originalProfiles = model.profiles
        let originalHarnesses = model.harnesses
        var mappingChanges = 0
        model.onMappingChange = { _ in mappingChanges += 1 }
        XCTAssertFalse(model.canDeleteProfile(profile))
        model.deleteProfile(profile)
        XCTAssertEqual(model.profiles, originalProfiles)
        XCTAssertEqual(model.harnesses, originalHarnesses)
        XCTAssertEqual(model.selectedProfileID, profile)
        XCTAssertEqual(model.selectedHarnessID, "codex")
        XCTAssertEqual(model.mapping[.buttonA].action, .copy)
        XCTAssertEqual(mappingChanges, 0)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.profiles, originalProfiles)
        XCTAssertEqual(restored.harnesses, originalHarnesses)
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        try restored.applyConfiguration(backup)
        XCTAssertFalse(restored.canDeleteProfile(profile))
        restored.deleteProfile(profile)
        XCTAssertEqual(restored.profiles, originalProfiles)
        XCTAssertEqual(restored.harnesses, originalHarnesses)

        model.bindProfile(nil, to: "codex")
        model.bindProfile(nil, to: "cursor")
        XCTAssertFalse(model.canDeleteProfile(profile))
        model.deleteProfile(profile)
        XCTAssertEqual(model.harnesses.first { $0.id == customID }?.profileID, profile)
        XCTAssertTrue(model.profiles.contains { $0.id == profile })
        model.bindProfile(nil, to: customID)
        XCTAssertTrue(model.canDeleteProfile(profile))
        model.activateProfile(profile)
        model.deleteProfile(profile)
        XCTAssertFalse(model.profiles.contains { $0.id == profile })
        XCTAssertEqual(model.selectedProfileID, SavedKeyProfile.defaultID)
        XCTAssertEqual(model.mapping, model.defaultMapping)
        XCTAssertFalse(RemoteDashboardModel(mapping: .defaults, defaults: defaults).profiles.contains { $0.id == profile })
    }

    func testDefaultProfileIsProtectedAndUnboundDuplicateCanBeDeleted() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let originalProfiles = model.profiles
        XCTAssertFalse(model.canDeleteProfile(SavedKeyProfile.defaultID))
        model.deleteProfile(SavedKeyProfile.defaultID)
        XCTAssertEqual(model.profiles, originalProfiles)
        let boundID = try XCTUnwrap(model.harnesses.first { $0.id == "workbuddy" }?.profileID)
        let copyID = try XCTUnwrap(model.duplicateProfile(boundID))
        XCTAssertTrue(model.canDeleteProfile(copyID))
        model.deleteProfile(copyID)
        XCTAssertEqual(model.profiles, originalProfiles)
        XCTAssertEqual(model.harnesses.first { $0.id == "workbuddy" }?.profileID, boundID)
    }

    func testDuplicateAppPreservesBindingAndRemovalKeepsScheme() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profile = makeProfile(model)
        let url = URL(fileURLWithPath: "/tmp/RcHarness-Test-Editor.app")
        let id = model.addHarness(applicationURL: url)
        model.bindProfile(profile, to: id)
        model.activateHarness(id)
        model.update(ButtonMapping(action: .paste), for: .buttonA, trigger: .long)
        model.setHarnessEnabled(id, enabled: false)
        XCTAssertEqual(model.addHarness(applicationURL: url), id)
        XCTAssertEqual(model.boundHarnesses(for: profile).map(\.id).first, id)
        model.activateHarness(id)
        XCTAssertEqual(model.mapping[.buttonA, .long].action, .paste)
        model.removeHarness(id)
        XCTAssertNil(model.selectedHarnessID)
        XCTAssertTrue(model.boundHarnesses(for: profile).isEmpty)
        XCTAssertEqual(model.profiles.first(where: { $0.id == profile })?.mapping[.buttonA, .long].action, .paste)
        model.removeHarness("codex")
        XCTAssertEqual(model.harnesses.count, HarnessConfiguration.defaults.count)
    }

    func testOldHarnessMappingsMigrateOnceWithoutLosingDefaultOrGestures() throws {
        var legacyDefault = RemoteMapping.defaults
        legacyDefault[.buttonA] = ButtonMapping(action: .paste)
        var harness = HarnessConfiguration.defaults[0]
        harness.legacyMapping[.buttonY, .double] = ButtonMapping(action: .copy)
        var oldHarness = try JSONSerialization.jsonObject(with: JSONEncoder().encode(harness)) as! [String: Any]
        oldHarness["mapping"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(harness.legacyMapping))
        defaults.set(try JSONSerialization.data(withJSONObject: [oldHarness]), forKey: "RcHarness.harnesses")
        SettingsStorage.save(legacyDefault, "baseMapping", defaults: defaults)
        defaults.set(harness.id, forKey: "RcHarness.selectedHarnessID")
        let model = RemoteDashboardModel(mapping: harness.legacyMapping, defaults: defaults)
        let profile = model.selectedProfileID!
        XCTAssertNotEqual(profile, SavedKeyProfile.defaultID)
        XCTAssertEqual(model.boundHarnesses(for: profile).map(\.id).first, harness.id)
        XCTAssertEqual(model.mapping[.buttonY, .double].action, .copy)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.profiles, model.profiles)
        XCTAssertEqual(restored.selectedProfileID, profile)
        restored.activateProfile(nil)
        XCTAssertEqual(restored.mapping, legacyDefault)
    }

    func testLegacyProfileAppRelationshipMigratesToHarness() throws {
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .copy)
        let profile = SavedKeyProfile(name: "旧应用方案", applicationPath: "/Applications/LegacyEditor.app", mapping: mapping)
        let backup = SettingsBackup(version: 1, mapping: .defaults, profiles: [profile], macros: [], phrases: [], harnesses: [])
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        try model.applyConfiguration(backup)
        XCTAssertEqual(model.profiles.first(where: { $0.id == profile.id })?.applicationPath, "")
        XCTAssertFalse(model.boundHarnesses(for: profile.id).isEmpty)
        model.matchApplication(profile.applicationPath)
        XCTAssertEqual(model.mapping, mapping)
    }

    func testBackupRoundTripKeepsBindingsAndProfileMappings() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profile = makeProfile(model)
        model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .double)
        model.bindProfile(profile, to: "codex")
        model.bindProfile(profile, to: "cursor")
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        model.bindProfile(nil, to: "codex")
        model.bindProfile(nil, to: "cursor")
        try model.applyConfiguration(backup)
        XCTAssertEqual(model.boundHarnesses(for: profile).map(\.id), ["codex", "cursor"])
        model.activateHarness("cursor")
        XCTAssertEqual(model.selectedProfileID, profile)
        XCTAssertEqual(model.mapping[.buttonA, .double].action, .copy)
        XCTAssertEqual(backup.version, 4)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as! [String: Any]
        let exportedHarnesses = json["harnesses"] as! [[String: Any]]
        XCTAssertTrue(exportedHarnesses.allSatisfy { $0["mapping"] == nil })
    }

    func testImportPreservesSharedBindingsRepairsDanglingReferencesAndRejectsUnknownVersion() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profile = SavedKeyProfile(name: "共享输入", mapping: .defaults)
        var harnesses = HarnessConfiguration.defaults
        harnesses[0].profileID = profile.id
        harnesses[1].profileID = profile.id
        harnesses[2].profileID = UUID()
        let backup = SettingsBackup(mapping: .defaults, profiles: [profile, profile], macros: [], phrases: [], harnesses: harnesses)
        try model.applyConfiguration(backup)
        XCTAssertEqual(model.harnesses.filter { $0.id == "codex" || $0.id == "claude" }.compactMap(\.profileID), [profile.id, profile.id])
        let cursor = try XCTUnwrap(model.harnesses.first { $0.id == "cursor" })
        let cursorProfile = try XCTUnwrap(model.profiles.first { $0.id == cursor.profileID })
        XCTAssertNotEqual(cursorProfile.id, harnesses[2].profileID)
        XCTAssertEqual(cursorProfile.name, "Cursor 按键方案")
        XCTAssertEqual(cursorProfile.mapping, .defaults)
        let importedHarnesses = model.harnesses
        XCTAssertEqual(model.profiles.filter { $0.id == profile.id }.count, 1)
        var invalid = backup
        invalid.version = 99
        XCTAssertThrowsError(try model.applyConfiguration(invalid))
        XCTAssertEqual(model.harnesses, importedHarnesses)
    }

    func testFirstNamedProfileCopiesCurrentButtonsWithoutChangingSource() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .single)
        let profile = makeProfile(model)
        model.renameProfile(profile, name: "已重命名方案")
        XCTAssertEqual(model.profiles.first(where: { $0.id == profile })?.name, "已重命名方案")
        model.update(ButtonMapping(action: .paste), for: .buttonA, trigger: .single)
        XCTAssertEqual(model.profiles.first(where: { $0.id == profile })?.mapping[.buttonA].action, .paste)
        model.activateProfile(nil)
        XCTAssertEqual(model.mapping[.buttonA].action, .copy)
        let duplicate = model.duplicateProfile(profile)
        XCTAssertNotNil(duplicate)
        XCTAssertEqual(model.profiles.first(where: { $0.id == duplicate })?.name, "已重命名方案的复制")
        XCTAssertTrue(model.boundHarnesses(for: duplicate!).isEmpty)
        XCTAssertEqual(model.mapping[.buttonA].action, .paste)
        model.saveProfile(name: "   ")
        XCTAssertEqual(model.profiles.count, 8)
    }

    func testApplicationIdentityPrefersBundleIdentifierOverPath() {
        var harness = HarnessConfiguration.defaults[0]
        harness.applicationPath = "/Applications/Codex.app"
        XCTAssertTrue(harness.matches(applicationPath: "/Other/Codex.app", bundleIdentifier: "com.openai.codex"))
        XCTAssertFalse(harness.matches(applicationPath: harness.applicationPath, bundleIdentifier: "other.codex"))
        XCTAssertTrue(harness.matches(applicationPath: harness.applicationPath, bundleIdentifier: nil))
        XCTAssertFalse(harness.matches(applicationPath: nil, bundleIdentifier: nil))
    }

    func testDisabledHarnessEditorOpensItsBoundProfileWithoutEnablingIt() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profile = makeProfile(model)
        model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .single)
        model.bindProfile(profile, to: "codex")
        model.setHarnessEnabled("codex", enabled: false)
        model.activateProfile(nil)
        model.page = .harness
        model.editHarnessProfile("codex")
        XCTAssertEqual(model.page, .mapping)
        XCTAssertEqual(model.selectedProfileID, profile)
        XCTAssertEqual(model.mapping[.buttonA].action, .copy)
        XCTAssertFalse(model.harnesses.first(where: { $0.id == "codex" })!.isEnabled)
        XCTAssertNil(model.selectedHarnessID)
    }

    func testLegacyProfileMatchesBuiltInHarnessWhenBackupHasNoHarnesses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let application = directory.appendingPathComponent("Codex.app")
        let contents = application.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = ["CFBundleIdentifier": "com.openai.codex", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .copy)
        let profile = SavedKeyProfile(name: "旧 Codex 方案", applicationPath: application.path, mapping: mapping)
        let backup = SettingsBackup(version: 1, mapping: .defaults, profiles: [profile], macros: [], phrases: [])
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        try model.applyConfiguration(backup)
        model.matchApplication(application.path, bundleIdentifier: "com.openai.codex")
        XCTAssertEqual(model.selectedProfileID, profile.id)
        XCTAssertEqual(model.mapping, mapping)
        XCTAssertEqual(model.harnesses.first(where: { $0.id == "codex" })?.profileID, profile.id)
    }

    func testOldBackupStillDecodesWithoutBindingFields() throws {
        let data = Data(#"{"version":1,"mapping":{"buttons":{}},"profiles":[],"macros":[],"phrases":[]}"#.utf8)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        try model.applyConfiguration(JSONDecoder().decode(SettingsBackup.self, from: data))
        XCTAssertEqual(model.selectedProfileID, SavedKeyProfile.defaultID)
        XCTAssertFalse(model.profiles.isEmpty)
    }
}
