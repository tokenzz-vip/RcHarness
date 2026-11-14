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
        XCTAssertEqual(model.effectiveMapping[.power, .double].action, .disabled)
        XCTAssertEqual(model.effectiveMapping[.power, .long].action, .switchToNativeMode)

        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var actions: [RemoteAction] = []
        gestures.onOutput = { value, pressed, _ in if pressed { actions.append(value.action) } }
        gestures.handle(.power, pressed: true, mapping: model.effectiveMapping)
        gestures.handle(.power, pressed: false, mapping: model.effectiveMapping)
        XCTAssertEqual(actions, [.openHarnessSwitcher], "Without a double binding, release executes the single click")
        clock.advance(RemoteGestureController.doubleTapWindow)
        XCTAssertEqual(actions, [.openHarnessSwitcher])
        for _ in 0..<2 {
            gestures.handle(.power, pressed: true, mapping: model.effectiveMapping)
            gestures.handle(.power, pressed: false, mapping: model.effectiveMapping)
        }
        clock.advance(RemoteGestureController.doubleTapWindow)
        XCTAssertEqual(actions, [.openHarnessSwitcher, .openHarnessSwitcher, .openHarnessSwitcher])
        gestures.handle(.power, pressed: true, mapping: model.effectiveMapping)
        clock.advance(RemoteGestureController.longPressDelay)
        gestures.handle(.power, pressed: false, mapping: model.effectiveMapping)
        clock.advance(RemoteGestureController.doubleTapWindow)
        XCTAssertEqual(actions, [.openHarnessSwitcher, .openHarnessSwitcher, .openHarnessSwitcher, .switchToNativeMode])

        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.globalButtons, model.globalButtons)
    }

    func testSavedDisabledGlobalGesturesAreNotReplacedByNewDefaults() {
        let saved = GlobalButtonSettings(single: ButtonMapping(action: .disabled),
                                         double: ButtonMapping(action: .disabled),
                                         long: ButtonMapping(action: .disabled))
        SettingsStorage.save(saved, SettingsKeys.Stored.globalButtons, defaults: defaults)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(Array(model.globalButtons.buttons.prefix(saved.buttons.count)), saved.buttons)
        XCTAssertEqual(model.globalButtons.buttons.count, 3)
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
        model.update(ButtonMapping(action: .copy), for: .home, trigger: .single)
        model.update(ButtonMapping(action: .fn), for: .options, trigger: .single)
        model.voiceFnTap = true
        let globals = model.globalButtons
        XCTAssertEqual(output, model.effectiveMapping)
        XCTAssertEqual(model.profiles.first(where: { $0.id == work })?.mapping[.power].action, .disabled)
        model.activateProfile(nil)
        XCTAssertEqual(output?[.power, .double].action, .paste)
        XCTAssertEqual(output?[.home].action, .copy)
        XCTAssertEqual(output?[.options].action, .fn)
        model.matchApplication(nil, bundleIdentifier: "com.openai.codex")
        XCTAssertEqual(model.selectedProfileID, work)
        XCTAssertEqual(output?[.power, .long].action, .openHarnessSwitcher)
        XCTAssertEqual(output?[.home].action, .copy)
        model.resetMapping()
        XCTAssertEqual(model.globalButtons, globals)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.globalButtons, globals)
        XCTAssertEqual(restored.effectiveMapping[.home].action, .copy)
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
        model.setGlobalInput(nil, at: 1)
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
        gestures.onOutput = { value, pressed, _ in if pressed { actions.append(value.action) } }
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

    func testExtraGlobalButtonsAllowEmptyRowsAndApplyEveryAssignedMapping() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.globalButtons.buttons.count, 3)
        model.addGlobalButton()
        XCTAssertEqual(model.globalButtons.buttons.count, 4)
        XCTAssertNil(model.globalButtons.buttons[3].input)

        model.setGlobalInput(.menu, at: 3)
        model.update(ButtonMapping(action: .copy), for: .menu, trigger: .single)
        model.update(ButtonMapping(action: .paste), for: .menu, trigger: .double)
        XCTAssertEqual(model.effectiveMapping[.menu, .single].action, .copy)
        XCTAssertEqual(model.effectiveMapping[.menu, .double].action, .paste)
        XCTAssertTrue(model.isGlobalInput(.menu))

        model.removeGlobalButton(at: 3)
        XCTAssertEqual(model.globalButtons.buttons.count, 3)
        XCTAssertFalse(model.isGlobalInput(.menu))
        XCTAssertEqual(model.effectiveMapping[.menu], model.mapping[.menu])
    }

    func testMultipleGlobalButtonsRejectDuplicatesAndNormalizeImportedRows() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let original = model.globalButtons
        model.setGlobalInput(.home, at: 0)
        model.setGlobalInput(.home, at: 2)
        XCTAssertEqual(model.globalButtons, original)
        XCTAssertFalse(model.globalInputChoices(at: 0).contains(.home))
        XCTAssertTrue(model.globalInputChoices(at: 1).contains(.home))
        model.addGlobalButton()
        model.setGlobalInput(.home, at: 3)
        XCTAssertNil(model.globalButtons.buttons[3].input)

        let duplicate = GlobalButtonSettings(additionalButtons: [
            GlobalButtonEntry(input: .power), GlobalButtonEntry(input: .home), GlobalButtonEntry(input: .home),
            GlobalButtonEntry(input: .options)
        ])
        let normalized = duplicate.normalized(for: RemoteProfiles.xiaomiRC003)
        XCTAssertEqual(normalized.buttons.compactMap(\.input), [.power, .home])

        model.setGlobalButtons(duplicate)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.globalButtons.buttons.compactMap(\.input), [.power, .home])
    }

    func testNewRemotesSeedThreeOrderedGlobalKeysAndRestoreIndependentEdits() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for remote in RemoteProfiles.all {
            model.selectRemoteProfile(remote.id)
            let third: ControllerInput = remote.adapter == .chromecast ? .inputSource : .buttonY
            XCTAssertEqual(model.globalButtons.buttons.map(\.input), [.power, .home, third])
            XCTAssertEqual(model.effectiveMapping[.home].action, .showDesktop)
            XCTAssertEqual(model.effectiveMapping[.home, .double].action, .escape)
            XCTAssertEqual(model.effectiveMapping[.home, .long].action, .disabled)
            XCTAssertEqual(model.effectiveMapping[third].action, .switchApplications)
            XCTAssertEqual(model.effectiveMapping[third, .double].action, .showAllWindows)
            XCTAssertEqual(model.effectiveMapping[third, .long].action, .showDesktop)
            model.update(ButtonMapping(action: .paste), for: third, trigger: .double)
        }
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        try model.applyConfiguration(backup)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for remote in RemoteProfiles.all {
            restored.selectRemoteProfile(remote.id)
            let third: ControllerInput = remote.adapter == .chromecast ? .inputSource : .buttonY
            XCTAssertEqual(restored.globalButtons.buttons.map(\.input), [.power, .home, third])
            XCTAssertEqual(restored.effectiveMapping[third, .double].action, .paste)
        }
    }

    func testFirstThreeRowsCannotBeRemovedAndOnlyTheFirstIsRequired() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        var expected: [String: GlobalButtonSettings] = [:]
        for remote in RemoteProfiles.all {
            model.selectRemoteProfile(remote.id)
            let original = model.globalButtons
            for index in [-1, 0, 1, 2, 3] { model.removeGlobalButton(at: index) }
            model.setGlobalInput(nil, at: 0)
            XCTAssertEqual(model.globalButtons, original)
            model.setGlobalInput(nil, at: 1)
            model.setGlobalInput(nil, at: 2)
            XCTAssertEqual(model.globalButtons.buttons.map(\.input), [.power, nil, nil])
            XCTAssertEqual(model.globalButtons.buttons[1].single.action, .showDesktop)
            XCTAssertEqual(model.effectiveMapping[.home], model.mapping[.home])
            expected[remote.id] = model.globalButtons
        }
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        try model.applyConfiguration(backup)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for remote in RemoteProfiles.all {
            restored.selectRemoteProfile(remote.id)
            XCTAssertEqual(restored.globalButtons, expected[remote.id])
            for index in 0..<3 { restored.removeGlobalButton(at: index) }
            XCTAssertEqual(restored.globalButtons, expected[remote.id])
        }
    }

    func testExistingSingleGlobalBindingGetsEmptyPermanentRowsWithoutChangingGestures() {
        let saved = GlobalButtonSettings(input: .home, single: ButtonMapping(action: .copy))
        SettingsStorage.save(saved, SettingsKeys.Stored.globalButtons, defaults: defaults)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.globalButtons.buttons.map(\.input), [.home, nil, nil])
        XCTAssertEqual(model.globalButtons.buttons[0], saved.buttons[0])
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.globalButtons, model.globalButtons)
    }

    func testPreviousTwoKeyDefaultsGainHomeBetweenExistingBindingsOnLoadAndImport() throws {
        for remote in RemoteProfiles.all {
            let third: ControllerInput = remote.adapter == .chromecast ? .inputSource : .buttonY
            let old = GlobalButtonSettings(single: ButtonMapping(action: .copy), additionalButtons: [
                GlobalButtonEntry(input: third, single: ButtonMapping(action: .paste))
            ])
            let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults, remoteProfile: remote)
            var backup = model.configurationBackup()
            backup.remoteKeyConfigurations?[remote.id]?.globalButtons = old
            try model.applyConfiguration(backup)
            XCTAssertEqual(model.globalButtons.buttons.map(\.input), [.power, .home, third])
            XCTAssertEqual(model.globalButtons.buttons[0], old.buttons[0])
            XCTAssertEqual(model.globalButtons.buttons[2], old.buttons[1])
            let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults, remoteProfile: remote)
            XCTAssertEqual(restored.globalButtons, model.globalButtons)
        }
    }

    func testCustomTwoKeyConfigurationKeepsItsRowsAndExplicitlyClearedKeysStayEmpty() {
        for inputs: [ControllerInput?] in [[.power, nil], [.menu, .home], [.home, .buttonY]] {
            let saved = GlobalButtonSettings(buttons: inputs.map { GlobalButtonEntry(input: $0) })
            let normalized = saved.normalized()
            XCTAssertEqual(normalized.buttons.map(\.input), inputs + [nil])
            XCTAssertEqual(Array(normalized.buttons.prefix(2)), saved.buttons)
            XCTAssertEqual(normalized.normalized(), normalized)
        }
        let emptyFirst = GlobalButtonSettings(buttons: [GlobalButtonEntry(), GlobalButtonEntry(input: .power)])
            .normalized()
        XCTAssertEqual(emptyFirst.buttons.map(\.input), [.power, nil, nil])
    }
}
