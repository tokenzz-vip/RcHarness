import XCTest
@testable import RcHarness

@MainActor
final class CodexDefaultProfileTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "RcHarness.CodexDefaultProfileTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFreshCodexProfileMatchesRequestedButtonsAndExecutableMacros() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let harness = try XCTUnwrap(model.harnesses.first { $0.id == "codex" })
        let profile = try XCTUnwrap(model.profiles.first { $0.id == harness.profileID })
        XCTAssertEqual(profile.name, "Codex 按键方案")
        XCTAssertTrue(harness.didInitializeDefaultProfile)
        XCTAssertEqual(model.selectedProfileID, SavedKeyProfile.defaultID)
        XCTAssertEqual(model.defaultMapping, .defaults)
        model.activateHarness(harness.id)
        let singleActions: [ControllerInput: RemoteAction] = [
            .dpadUp: .arrowUp, .dpadRight: .arrowRight, .dpadDown: .arrowDown,
            .dpadLeft: .arrowLeft, .buttonA: .enter, .buttonB: .backspace,
            .home: .escape, .menu: .copy, .rightShoulder: .volumeUp,
            .leftShoulder: .volumeDown, .buttonY: .paste,
        ]
        for (input, action) in singleActions {
            XCTAssertEqual(model.effectiveMapping[input].action, action, input.rawValue)
            XCTAssertEqual(model.effectiveMapping[input, .long].action, .disabled)
        }
        let recentInputs: [ControllerInput] = [.dpadUp, .dpadRight, .dpadDown, .dpadLeft, .rightShoulder, .leftShoulder]
        for (offset, input) in recentInputs.enumerated() {
            let button = model.mapping[input, .double]
            XCTAssertEqual(button.action, .macro)
            let macro = try XCTUnwrap(model.macros.first { $0.id.uuidString == button.referenceID })
            XCTAssertEqual(macro.name, "Codex-转到最近聊天\(offset + 1)")
            let plan = try MacroExecutionPlan(macro, macros: model.macros)
            XCTAssertEqual(plan.events.count, 1)
            XCTAssertEqual(plan.events.first?.mapping.shortcut?.label, "⌥⌘\(offset + 1)")
        }
        XCTAssertEqual(model.mappingTitle(model.mapping[.buttonA, .double]), "Codex-新建会话")
        for input: ControllerInput in [.buttonB, .home, .menu, .buttonY] {
            XCTAssertEqual(model.mapping[input, .double].action, .disabled)
        }
        XCTAssertEqual(model.effectiveMapping[.power].action, .openHarnessSwitcher)
        XCTAssertEqual(model.effectiveMapping[.power, .double].action, .screenshot)
        XCTAssertEqual(model.effectiveMapping[.power, .long].action, .switchToNativeMode)
        XCTAssertEqual(model.effectiveMapping[.options], model.globalButtons.voice)
        XCTAssertEqual(model.danglingReferenceCount(), 0)
    }

    func testCodexUpgradePreservesExistingBindingMappingSelectionAndGlobals() throws {
        var mapping = RemoteMapping.defaults
        mapping[.dpadLeft] = ButtonMapping(action: .paste)
        mapping[.buttonA, .double] = ButtonMapping(action: .copy)
        let profile = SavedKeyProfile(name: "Codex 按键方案", mapping: mapping)
        var harness = try XCTUnwrap(HarnessConfiguration.defaults.first { $0.id == "codex" })
        harness.profileID = profile.id
        var globals = GlobalButtonSettings()
        globals.voice = ButtonMapping(action: .fn)
        SettingsStorage.save([profile], SettingsKeys.Stored.profiles, defaults: defaults)
        SettingsStorage.save([harness], SettingsKeys.Stored.harnesses, defaults: defaults)
        SettingsStorage.save(globals, SettingsKeys.Stored.globalButtons, defaults: defaults)
        defaults.set(profile.id.uuidString, forKey: SettingsKeys.selectedProfileID)
        defaults.set(2, forKey: SettingsKeys.profileBindingsVersion)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.profiles.first { $0.id == profile.id }, profile)
        XCTAssertEqual(model.harnesses.first?.profileID, profile.id)
        XCTAssertEqual(model.harnesses.first?.didInitializeDefaultProfile, true)
        XCTAssertEqual(model.selectedProfileID, profile.id)
        XCTAssertEqual(model.mapping, mapping)
        XCTAssertEqual(model.globalButtons, globals)
        try model.applyConfiguration(SettingsBackup(mapping: .defaults, profiles: [profile], macros: [], phrases: [], harnesses: [harness], globalButtons: globals))
        XCTAssertEqual(model.profiles.first { $0.id == profile.id }, profile)
        XCTAssertEqual(model.harnesses.first?.profileID, profile.id)
        XCTAssertEqual(model.globalButtons, globals)
    }

    func testUnboundCodexInitializationKeepsConflictingProfileAndDoesNotRepeat() throws {
        let existing = SavedKeyProfile(name: "Codex 按键方案", mapping: .defaults)
        var harness = try XCTUnwrap(HarnessConfiguration.defaults.first { $0.id == "codex" })
        harness.isEnabled = false
        SettingsStorage.save([existing], SettingsKeys.Stored.profiles, defaults: defaults)
        SettingsStorage.save([harness], SettingsKeys.Stored.harnesses, defaults: defaults)
        defaults.set(existing.id.uuidString, forKey: SettingsKeys.selectedProfileID)
        defaults.set(2, forKey: SettingsKeys.profileBindingsVersion)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let generatedID = try XCTUnwrap(model.harnesses.first?.profileID)
        let generated = try XCTUnwrap(model.profiles.first { $0.id == generatedID })
        XCTAssertEqual(generated.name, "Codex 按键方案 2")
        XCTAssertEqual(model.mappingTitle(generated.mapping[.dpadUp, .double]), "Codex-转到最近聊天1")
        XCTAssertEqual(model.profiles.first { $0.id == existing.id }, existing)
        XCTAssertEqual(model.selectedProfileID, existing.id)
        XCTAssertEqual(model.harnesses.first?.isEnabled, false)
        model.activateProfile(generatedID)
        model.update(ButtonMapping(action: .paste), for: .dpadRight, trigger: .single)
        model.resetMapping()
        XCTAssertEqual(model.mapping[.dpadRight].action, .arrowRight)
        XCTAssertEqual(model.mappingTitle(model.mapping[.dpadUp, .double]), "Codex-转到最近聊天1")
        model.update(ButtonMapping(action: .copy), for: .dpadUp, trigger: .double)
        model.bindProfile(nil, to: harness.id)
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.profiles, model.profiles)
        XCTAssertNil(restored.harnesses.first?.profileID)
        try restored.applyConfiguration(backup)
        XCTAssertEqual(restored.profiles, model.profiles)
        XCTAssertNil(restored.harnesses.first?.profileID)
        XCTAssertEqual(restored.profiles.first { $0.id == generatedID }?.mapping[.dpadUp, .double].action, .copy)
    }

    func testResetCodexUsesExistingMacroIDsAndPreservesGlobalsAndDeletedMacros() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profileID = try XCTUnwrap(model.harnesses.first { $0.id == "codex" }?.profileID)
        let newChat = try XCTUnwrap(model.macros.first { $0.name == "Codex-新建会话" })
        XCTAssertTrue(model.renameMacro(newChat.id, name: "我的新会话"))
        let firstChat = try XCTUnwrap(model.macros.first { $0.name == "Codex-转到最近聊天1" })
        model.deleteMacro(firstChat.id)
        let replacementID = model.addMacro()
        XCTAssertTrue(model.renameMacro(replacementID, name: "codex-转到最近聊天1"))
        let lastChat = try XCTUnwrap(model.macros.first { $0.name == "Codex-转到最近聊天6" })
        model.deleteMacro(lastChat.id)
        model.bindProfile(nil, to: "codex")
        model.activateProfile(profileID)
        model.update(ButtonMapping(action: .paste), for: .dpadRight, trigger: .single)
        model.update(ButtonMapping(action: .disabled), for: .menu, trigger: .single)
        model.update(ButtonMapping(action: .screenshot), for: .buttonY, trigger: .single)
        model.update(ButtonMapping(action: .fn), for: .options, trigger: .single)
        let globals = model.globalButtons
        let macros = model.macros
        model.resetMapping()
        XCTAssertEqual(model.mapping[.dpadRight].action, .arrowRight)
        XCTAssertEqual(model.mapping[.menu].action, .copy)
        XCTAssertEqual(model.mapping[.buttonY].action, .paste)
        XCTAssertEqual(model.mapping[.buttonA, .double].referenceID, newChat.id.uuidString)
        XCTAssertEqual(model.mapping[.dpadUp, .double].referenceID, replacementID.uuidString)
        XCTAssertEqual(model.mapping[.leftShoulder, .double].action, .disabled)
        XCTAssertEqual(model.macros, macros)
        XCTAssertEqual(model.globalButtons, globals)
        XCTAssertEqual(model.effectiveMapping[.options].action, .fn)
        XCTAssertEqual(model.danglingReferenceCount(), 0)
        model.activateProfile(nil)
        model.resetMapping()
        XCTAssertEqual(model.mapping, .defaults)
        XCTAssertEqual(model.globalButtons, globals)
    }
}
