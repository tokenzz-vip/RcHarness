import XCTest
@testable import RcHarness

@MainActor
final class GlobalButtonTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "RcHarness.GlobalButtonTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testFreshInstallUsesTheDefaultGlobalGesturesAndRetainsThemAfterRestart() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.globalButtons.input, .power)
        XCTAssertEqual(model.effectiveMapping[.power, .single].action, .openHarnessSwitcher)
        XCTAssertEqual(model.effectiveMapping[.power, .double].action, .screenshot)
        XCTAssertEqual(model.effectiveMapping[.power, .long].action, .switchToNativeMode)

        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var actions: [RemoteAction] = []
        gestures.onOutput = { if $1 { actions.append($0.action) } }
        gestures.handle(.power, pressed: true, mapping: model.effectiveMapping)
        gestures.handle(.power, pressed: false, mapping: model.effectiveMapping)
        XCTAssertTrue(actions.isEmpty, "Single click waits for the double-click window")
        clock.advance(RemoteGestureController.doubleTapWindow)
        XCTAssertEqual(actions, [.openHarnessSwitcher])
        for _ in 0..<2 {
            gestures.handle(.power, pressed: true, mapping: model.effectiveMapping)
            gestures.handle(.power, pressed: false, mapping: model.effectiveMapping)
        }
        clock.advance(RemoteGestureController.doubleTapWindow)
        XCTAssertEqual(actions, [.openHarnessSwitcher, .screenshot])
        gestures.handle(.power, pressed: true, mapping: model.effectiveMapping)
        clock.advance(RemoteGestureController.longPressDelay)
        gestures.handle(.power, pressed: false, mapping: model.effectiveMapping)
        clock.advance(RemoteGestureController.doubleTapWindow)
        XCTAssertEqual(actions, [.openHarnessSwitcher, .screenshot, .switchToNativeMode])

        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.globalButtons, model.globalButtons)
    }

    func testSavedDisabledGlobalGesturesAreNotReplacedByNewDefaults() {
        let saved = GlobalButtonSettings(single: ButtonMapping(action: .disabled),
                                         double: ButtonMapping(action: .disabled),
                                         long: ButtonMapping(action: .disabled))
        SettingsStorage.save(saved, SettingsKeys.Stored.globalButtons, defaults: defaults)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.globalButtons, saved)
    }

    func testGlobalsOverrideEveryProfileAndHarnessAndSurviveResetAndRestart() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.saveProfile(name: "工作")
        let work = model.selectedProfileID!
        model.bindProfile(work, to: "codex")
        var output: RemoteMapping?
        model.onMappingChange = { output = $0 }
        model.update(ButtonMapping(action: .copy), for: .power, trigger: .single)
        model.update(ButtonMapping(action: .paste), for: .power, trigger: .double)
        model.update(ButtonMapping(action: .openHarnessSwitcher), for: .power, trigger: .long)
        model.update(ButtonMapping(action: .fn), for: .options, trigger: .single)
        model.voiceFnTap = true
        let globals = model.globalButtons
        XCTAssertEqual(output, model.effectiveMapping)
        XCTAssertEqual(model.profiles.first(where: { $0.id == work })?.mapping[.power].action, .disabled)
        model.activateProfile(nil)
        XCTAssertEqual(output?[.power, .double].action, .paste)
        XCTAssertEqual(output?[.options].action, .fn)
        model.matchApplication(nil, bundleIdentifier: "com.openai.codex")
        XCTAssertEqual(model.selectedProfileID, work)
        XCTAssertEqual(output?[.power, .long].action, .openHarnessSwitcher)
        model.resetMapping()
        XCTAssertEqual(model.globalButtons, globals)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.globalButtons, globals)
        XCTAssertEqual(restored.effectiveMapping[.options].action, .fn)
        XCTAssertFalse(restored.voiceFnTap)
    }

    func testMigrationUsesThePreviouslyActiveProfileAndDoesNotReviveRetiredGestures() {
        var mapping = RemoteMapping.defaults
        mapping[.power] = ButtonMapping(action: .copy)
        mapping[.power, .double] = ButtonMapping(action: .paste)
        mapping[.power, .long] = ButtonMapping(action: .screenshot)
        mapping[.options] = ButtonMapping(action: .fn)
        let profile = SavedKeyProfile(name: "原有方案", mapping: mapping)
        SettingsStorage.save([profile], SettingsKeys.Stored.profiles, defaults: defaults)
        defaults.set(profile.id.uuidString, forKey: SettingsKeys.selectedProfileID)
        defaults.set(true, forKey: SettingsKeys.voiceFnTap)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.globalButtons.input, .power)
        XCTAssertEqual(model.effectiveMapping[.power].action, .copy)
        XCTAssertEqual(model.effectiveMapping[.power, .double].action, .disabled)
        XCTAssertEqual(model.effectiveMapping[.power, .long].action, .disabled)
        XCTAssertEqual(model.effectiveMapping[.options].action, .fn)
        XCTAssertFalse(model.voiceFnTap)
        model.activateProfile(nil)
        XCTAssertEqual(model.effectiveMapping[.options].action, .fn)
        XCTAssertEqual(model.effectiveMapping[.power].action, .copy)
    }

    func testBackupRestoresGlobalsAndOldBackupsMigrateTheirDefaultMapping() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.update(ButtonMapping(action: .macro, referenceID: "missing"), for: .power, trigger: .long)
        model.update(ButtonMapping(action: .fn), for: .options, trigger: .single)
        model.voiceFnTap = true
        model.setGlobalInput(.home)
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        model.update(ButtonMapping(action: .disabled), for: .power, trigger: .long)
        model.voiceFnTap = false
        XCTAssertEqual(try model.applyConfiguration(backup), 1)
        XCTAssertEqual(model.globalButtons, backup.globalButtons)
        var legacy = RemoteMapping.defaults
        legacy[.power] = ButtonMapping(action: .escape)
        legacy[.options] = ButtonMapping(action: .leftOption)
        try model.applyConfiguration(SettingsBackup(version: 2, mapping: legacy, profiles: [], macros: [], phrases: []))
        XCTAssertEqual(model.effectiveMapping[.power].action, .escape)
        XCTAssertEqual(model.effectiveMapping[.options].action, .leftOption)
        XCTAssertEqual(model.effectiveMapping[.power, .long].action, .disabled)
    }

    func testChangingGlobalInputRestoresTheOldKeysProfileMappingAndOverridesTheNewKey() {
        var mapping = RemoteMapping.defaults
        mapping[.power] = ButtonMapping(action: .screenshot)
        mapping[.home, .double] = ButtonMapping(action: .copy)
        let model = RemoteDashboardModel(mapping: mapping, defaults: defaults)
        model.update(ButtonMapping(action: .paste), for: .power, trigger: .single)
        var applied: RemoteMapping?
        model.onMappingChange = { applied = $0 }
        model.setGlobalInput(.home)
        XCTAssertEqual(applied?[.power].action, .screenshot)
        XCTAssertEqual(applied?[.home].action, .paste)
        XCTAssertEqual(applied?[.home, .double].action, .disabled)
        XCTAssertEqual(model.mapping[.home, .double].action, .copy)
        model.setGlobalInput(.options)
        XCTAssertEqual(model.globalButtons.input, .home)
        model.update(ButtonMapping(action: .escape), for: .power, trigger: .long)
        XCTAssertEqual(model.mapping[.power, .long].action, .escape)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.globalButtons.input, .home)
        XCTAssertEqual(restored.effectiveMapping[.home].action, .paste)
        model.setGlobalInput(.power)
        XCTAssertEqual(model.effectiveMapping[.home].action, .escape)
        XCTAssertEqual(model.effectiveMapping[.home, .double].action, .copy)
    }

    func testPendingGlobalGestureKeepsItsMappingAcrossProfileSwitchAndEdit() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.update(ButtonMapping(action: .copy), for: .power, trigger: .single)
        model.update(ButtonMapping(action: .paste), for: .power, trigger: .double)
        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var actions: [RemoteAction] = []
        gestures.onOutput = { if $1 { actions.append($0.action) } }
        gestures.handle(.power, pressed: true, mapping: model.effectiveMapping)
        gestures.handle(.power, pressed: false, mapping: model.effectiveMapping)
        model.saveProfile(name: "另一个方案")
        model.update(ButtonMapping(action: .escape), for: .power, trigger: .single)
        clock.advance(0.4)
        XCTAssertEqual(actions, [.copy])
        gestures.handle(.power, pressed: true, mapping: model.effectiveMapping)
        gestures.handle(.power, pressed: false, mapping: model.effectiveMapping)
        clock.advance(0.4)
        XCTAssertEqual(actions, [.copy, .escape])
    }

    func testLegacyMovableVoiceInputIsIgnoredOnLoadAndImport() throws {
        var mapping = RemoteMapping.defaults
        mapping[.home] = ButtonMapping(action: .paste)
        mapping[.options] = ButtonMapping(action: .copy)
        let profile = SavedKeyProfile(id: SavedKeyProfile.defaultID, name: "默认方案", mapping: mapping)
        SettingsStorage.save([profile], SettingsKeys.Stored.profiles, defaults: defaults)
        let globals = GlobalButtonSettings(voice: ButtonMapping(action: .fn), voiceFnTap: true)
        var oldGlobals = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(globals)) as? [String: Any])
        oldGlobals["voiceInput"] = ControllerInput.home.rawValue
        let oldData = try JSONSerialization.data(withJSONObject: oldGlobals)
        let decoded = try JSONDecoder().decode(GlobalButtonSettings.self, from: oldData)
        SettingsStorage.save(decoded, SettingsKeys.Stored.globalButtons, defaults: defaults)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.effectiveMapping[.options].action, .fn)
        XCTAssertEqual(model.effectiveMapping[.home].action, .paste)
        XCTAssertFalse(model.voiceFnTap)
        XCTAssertFalse(model.isGlobalInput(.options))
        XCTAssertTrue(model.isGlobalInput(.power))

        var oldBackup = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model.configurationBackup())) as? [String: Any])
        oldGlobals["input"] = ControllerInput.options.rawValue
        oldBackup["globalButtons"] = oldGlobals
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONSerialization.data(withJSONObject: oldBackup))
        try model.applyConfiguration(backup)
        XCTAssertEqual(model.globalButtons.input, .power)
        XCTAssertEqual(model.effectiveMapping[.power].action, .openHarnessSwitcher)
        XCTAssertEqual(model.effectiveMapping[.options].action, .fn)
        XCTAssertEqual(model.effectiveMapping[.home].action, .paste)
        XCTAssertFalse(model.globalButtons.voiceFnTap)
        XCTAssertFalse(model.voiceFnTap)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.globalButtons, model.globalButtons)
        let exportedGlobals = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.globalButtons)) as? [String: Any])
        XCTAssertNil(exportedGlobals["voiceInput"])
        XCTAssertEqual(exportedGlobals["voiceFnTap"] as? Bool, false)
    }

    func testXiaomiVoiceTapCannotBeEnabledOrRestoredFromSavedGlobals() throws {
        let saved = GlobalButtonSettings(voice: ButtonMapping(action: .fn), voiceFnTap: true)
        SettingsStorage.save(saved, SettingsKeys.Stored.globalButtons, defaults: defaults)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertFalse(model.voiceFnTap)
        XCTAssertFalse(model.globalButtons.voiceFnTap)
        model.voiceFnTap = true
        XCTAssertFalse(model.voiceFnTap)
        XCTAssertEqual(model.globalButtons.voice.action, .fn)
        let persisted = try XCTUnwrap(SettingsStorage.load(GlobalButtonSettings.self, SettingsKeys.Stored.globalButtons, defaults: defaults))
        XCTAssertFalse(persisted.voiceFnTap)
        XCTAssertFalse(model.configurationBackup().globalButtons?.voiceFnTap ?? true)
    }

    func testVoiceKeyRejectsOrdinaryActionsAndAdditionalGestures() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for action in RemoteAction.voiceTriggerActions {
            model.update(ButtonMapping(action: action), for: .options, trigger: .single)
            XCTAssertEqual(model.effectiveMapping[.options].action, action)
        }
        let voice = model.globalButtons.voice
        for action in RemoteAction.allCases where !RemoteAction.voiceTriggerActions.contains(action) {
            model.update(ButtonMapping(action: action), for: .options, trigger: .single)
            XCTAssertEqual(model.globalButtons.voice, voice)
        }
        model.update(ButtonMapping(action: .copy), for: .options, trigger: .double)
        model.update(ButtonMapping(action: .paste), for: .options, trigger: .long)
        XCTAssertEqual(model.effectiveMapping[.options, .double].action, .disabled)
        XCTAssertEqual(model.effectiveMapping[.options, .long].action, .disabled)
        model.setGlobalInput(.options)
        XCTAssertEqual(model.globalButtons.input, .power)
    }

    func testInvalidSavedAndImportedVoiceActionsFallBackToVoiceTrigger() throws {
        let globals = GlobalButtonSettings(input: .options, voice: ButtonMapping(action: .macro, referenceID: "missing"))
        SettingsStorage.save(globals, SettingsKeys.Stored.globalButtons, defaults: defaults)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.globalButtons.input, .power)
        XCTAssertEqual(model.effectiveMapping[.options].action, .fn)
        var backup = model.configurationBackup()
        backup.globalButtons = GlobalButtonSettings(voice: ButtonMapping(action: .disabled))
        XCTAssertEqual(try model.applyConfiguration(backup), 0)
        XCTAssertEqual(model.effectiveMapping[.options].action, .fn)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.effectiveMapping[.options].action, .fn)
    }
}
