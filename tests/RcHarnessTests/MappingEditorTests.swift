import XCTest
@testable import RcHarness

@MainActor
final class MappingEditorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "RcHarness.MappingEditorTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDraftPreservesAllTriggersWithoutChangingRuntimeOrStorageUntilSave() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for input in [ControllerInput.dpadDown, .power] {
            model.openButtonEditor(input, trigger: .long)
            let original = model.effectiveMapping
            var notifications = 0
            model.onMappingChange = { _ in notifications += 1 }
            var draft = MappingEditorDraft(model: model)
            draft.mapping[input, .long] = ButtonMapping(action: .copy)
            draft.trigger = .single
            draft.mapping[input, .single] = ButtonMapping(action: .paste)
            draft.trigger = .double
            draft.mapping[input, .double] = ButtonMapping(action: .disabled)
            XCTAssertEqual(model.effectiveMapping, original)
            model.flushPendingWrites()
            XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).effectiveMapping, original)
            XCTAssertEqual(notifications, 0)

            // Cancel/dismiss leaves the live values intact, and reopening starts fresh.
            model.editorVisible = false
            model.openButtonEditor(input)
            XCTAssertEqual(MappingEditorDraft(model: model).mapping, original)
            XCTAssertTrue(model.saveMappingEditor(draft))
            let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            for trigger in input.supportedTriggers {
                XCTAssertEqual(model.effectiveMapping[input, trigger], draft.mapping[input, trigger])
                XCTAssertEqual(restored.effectiveMapping[input, trigger], draft.mapping[input, trigger])
            }
            XCTAssertEqual(model.effectiveMapping[.buttonA], original[.buttonA])
            XCTAssertGreaterThan(notifications, 0)
        }
    }

    func testVoiceModeAndBothShortcutsOnlyApplyTogetherOnSave() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        model.openButtonEditor(.options)
        let original = model.globalButtons
        var notifications = 0
        model.onVoiceTriggerChange = { notifications += 1 }
        var draft = MappingEditorDraft(model: model)
        draft.voiceMode = .hold
        draft.voiceHoldShortcut = VoiceShortcutChoice.singles[2].shortcut
        draft.voiceTapShortcut = VoiceShortcutChoice.pairs[6].shortcut
        XCTAssertEqual(model.globalButtons, original)
        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).globalButtons, original)
        XCTAssertEqual(notifications, 0)
        XCTAssertTrue(model.saveMappingEditor(draft))
        XCTAssertEqual(notifications, 1)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.voiceMode, .hold)
        XCTAssertEqual(restored.voiceHoldShortcut, draft.voiceHoldShortcut)
        XCTAssertEqual(restored.voiceTapShortcut, draft.voiceTapShortcut)
        XCTAssertEqual(restored.globalButtons.buttons, original.buttons)
    }

    func testStaleDraftCannotWriteIntoAnotherProfileOrRemote() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.openButtonEditor(.dpadDown)
        var draft = MappingEditorDraft(model: model)
        draft.mapping[.dpadDown] = ButtonMapping(action: .copy)
        model.activateHarness("chatgpt")
        let original = model.effectiveMapping
        XCTAssertFalse(model.saveMappingEditor(draft))
        XCTAssertEqual(model.effectiveMapping, original)
        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        let otherRemoteMapping = model.effectiveMapping
        XCTAssertFalse(model.saveMappingEditor(draft))
        XCTAssertEqual(model.effectiveMapping, otherRemoteMapping)
    }

    func testIncompleteShortcutBlocksNewChangesButAllowsLegacyMappings() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let blank = ButtonMapping(action: .recordedShortcut)
        let input = ControllerInput.dpadDown
        model.openButtonEditor(input)
        let original = model.effectiveMapping
        var draft = MappingEditorDraft(model: model)
        draft.mapping[input, .long] = blank
        draft.mapping[input, .single] = ButtonMapping(action: .copy)
        XCTAssertTrue(draft.hasIncompleteShortcut)
        XCTAssertFalse(model.saveMappingEditor(draft))
        XCTAssertEqual(model.effectiveMapping, original)

        model.update(blank, for: input, trigger: .long)
        draft = MappingEditorDraft(model: model)
        draft.mapping[input, .single] = ButtonMapping(action: .copy)
        XCTAssertFalse(draft.hasIncompleteShortcut)
        XCTAssertTrue(model.saveMappingEditor(draft))
        XCTAssertEqual(model.effectiveMapping[input, .long], blank)
    }
}
