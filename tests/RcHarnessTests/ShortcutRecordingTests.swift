import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class ShortcutRecordingTests: XCTestCase {
    @discardableResult
    private func send(_ session: ShortcutRecordingSession, _ type: CGEventType, code: UInt16 = 63,
                      flags: CGEventFlags = [], repeatKey: Bool = false) throws -> Bool {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown))
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return session.handle(type, event: event)
    }

    func testSingleModifiersCaptureOnReleaseWithoutStartingGlobalProtection() throws {
        for key in VoiceShortcutKey.allCases {
            let session = ShortcutRecordingSession()
            var captured: [RecordedShortcut] = []
            session.onCapture = { captured.append($0) }
            session.start()
            XCTAssertTrue(try send(session, .flagsChanged, code: key.keyCode, flags: key.flags))
            XCTAssertTrue(captured.isEmpty)
            try send(session, .flagsChanged, code: key.keyCode)
            XCTAssertEqual(captured.first?.keyCode, key.keyCode)
            XCTAssertEqual(captured.count, 1)
            XCTAssertFalse(session.isRecording)
            XCTAssertFalse(try send(session, .flagsChanged, code: key.keyCode))
        }
    }

    func testOrdinaryCommandShortcutWaitsForAllReleasesAndIgnoresRepeat() throws {
        let session = ShortcutRecordingSession()
        var captured: [RecordedShortcut] = []
        session.onCapture = { captured.append($0) }
        session.start()
        try send(session, .flagsChanged, code: 55, flags: .maskCommand)
        try send(session, .keyDown, code: 40, flags: .maskCommand)
        try send(session, .keyDown, code: 40, flags: .maskCommand, repeatKey: true)
        try send(session, .keyUp, code: 40, flags: .maskCommand)
        XCTAssertTrue(captured.isEmpty)
        try send(session, .flagsChanged, code: 55)
        XCTAssertEqual(captured, [.init(keyCode: 40, modifiers: CGEventFlags.maskCommand.rawValue, label: "⌘K")])
    }

    func testOrdinaryFnSpaceCanStillBeRecorded() throws {
        let session = ShortcutRecordingSession()
        var captured: RecordedShortcut?
        session.onCapture = { captured = $0 }
        session.start()
        try send(session, .flagsChanged, flags: .maskSecondaryFn)
        try send(session, .keyDown, code: 49, flags: .maskSecondaryFn)
        try send(session, .flagsChanged)
        XCTAssertNil(captured)
        try send(session, .keyUp, code: 49)
        XCTAssertEqual(captured, .init(keyCode: 49, modifiers: CGEventFlags.maskSecondaryFn.rawValue, label: "Fn + Space"))
    }

    func testKeyboardSelectionBuildsLockShortcutAndKeepsKeypadCodesDistinct() throws {
        let shortcut = try XCTUnwrap(StandardShortcutKeyboard.shortcut(
            keyCode: UInt16(kVK_ANSI_Q), flags: [.maskControl, .maskCommand]))
        XCTAssertEqual(shortcut.label, "⌃⌘Q")
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        sender.send(ButtonMapping(action: .recordedShortcut, shortcut: shortcut), pressed: true)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       [Int64(kVK_ANSI_Q), Int64(kVK_ANSI_Q)])
        XCTAssertEqual(events.first?.flags, [.maskControl, .maskCommand])

        let main = try XCTUnwrap(StandardShortcutKeyboard.shortcut(keyCode: UInt16(kVK_ANSI_1), flags: []))
        let keypad = try XCTUnwrap(StandardShortcutKeyboard.shortcut(keyCode: UInt16(kVK_ANSI_Keypad1), flags: []))
        XCTAssertEqual(main.label, "1")
        XCTAssertEqual(keypad.label, "数字键盘 1")
        XCTAssertNotEqual(main.keyCode, keypad.keyCode)
        events.removeAll()
        sender.send(ButtonMapping(action: .recordedShortcut, shortcut: keypad), pressed: true)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(events.map(\.flags), [.maskNumericPad, .maskNumericPad])
        XCTAssertEqual(ShortcutRecordingSession.singleModifierShortcut(keyCode: VirtualKey.function), .voiceHoldDefault)
    }

    func testRecordingAndKeyboardSelectionUseSameMacLabels() throws {
        let cases: [(Int, CGEventFlags)] = [
            (kVK_ANSI_3, [.maskShift, .maskCommand]),
            (kVK_Tab, .maskCommand),
            (kVK_Escape, .maskAlternate),
            (kVK_F1, .maskSecondaryFn),
            (kVK_UpArrow, [.maskControl, .maskSecondaryFn, .maskNumericPad]),
            (kVK_ANSI_Keypad1, .maskNumericPad)
        ]
        for (code, flags) in cases {
            let session = ShortcutRecordingSession()
            var captured: RecordedShortcut?
            session.onCapture = { captured = $0 }
            session.start()
            try send(session, .keyDown, code: UInt16(code), flags: flags)
            try send(session, .keyUp, code: UInt16(code))
            let expected = StandardShortcutKeyboard.shortcut(keyCode: UInt16(code),
                flags: flags.intersection(ShortcutRecordingSession.modifiers).subtracting(.maskSecondaryFn))
            XCTAssertEqual(captured, expected)
        }
    }

    func testRecorderRejectsTwoOverlappingMainKeysAndCanRetry() throws {
        let session = ShortcutRecordingSession()
        var captured: RecordedShortcut?
        session.onCapture = { captured = $0 }
        session.start()
        try send(session, .keyDown, code: UInt16(kVK_ANSI_A))
        try send(session, .keyDown, code: UInt16(kVK_ANSI_B))
        try send(session, .keyUp, code: UInt16(kVK_ANSI_A))
        try send(session, .keyUp, code: UInt16(kVK_ANSI_B))
        XCTAssertNil(captured)
        XCTAssertTrue(session.isRecording)
        try send(session, .keyDown, code: UInt16(kVK_ANSI_A))
        try send(session, .keyUp, code: UInt16(kVK_ANSI_A))
        XCTAssertEqual(captured?.label, "A")
    }

    func testSingleSelectedModifierEmitsTheMacSideFlag() throws {
        for (code, sideFlag): (Int, UInt64) in [(kVK_RightCommand, 0x10), (kVK_RightShift, 0x04)] {
            let shortcut = try XCTUnwrap(ShortcutRecordingSession.singleModifierShortcut(keyCode: UInt16(code)))
            var events: [CGEvent] = []
            let sender = SystemEventSender(postEvent: { events.append($0) })
            sender.send(ButtonMapping(action: .recordedShortcut, shortcut: shortcut), pressed: true)
            XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged])
            XCTAssertEqual(events.first?.flags.rawValue, shortcut.modifiers | sideFlag)
            XCTAssertEqual(events.last?.flags, [])
        }
    }

    func testTwoSidesOfSameModifierDoNotCaptureAnAccidentalSingle() throws {
        for codes in [(55, 54), (58, 61), (59, 62)] {
            let left = VoiceShortcutKey.allCases.first { $0.keyCode == codes.0 }!
            let right = VoiceShortcutKey.allCases.first { $0.keyCode == codes.1 }!
            let session = ShortcutRecordingSession()
            var captured: [RecordedShortcut] = []
            session.onCapture = { captured.append($0) }
            session.start()
            try send(session, .flagsChanged, code: left.keyCode, flags: left.flags)
            try send(session, .flagsChanged, code: right.keyCode, flags: left.flags.union(right.flags))
            try send(session, .flagsChanged, code: left.keyCode, flags: right.flags)
            try send(session, .flagsChanged, code: right.keyCode)
            XCTAssertTrue(captured.isEmpty)
            try send(session, .flagsChanged, code: UInt16(kVK_Shift), flags: .maskShift)
            try send(session, .flagsChanged, code: UInt16(kVK_RightShift), flags: .maskShift)
            try send(session, .flagsChanged, code: UInt16(kVK_Shift), flags: .maskShift)
            try send(session, .flagsChanged, code: UInt16(kVK_RightShift))
            XCTAssertTrue(captured.isEmpty)
            try send(session, .flagsChanged, code: UInt16(kVK_Option), flags: .maskAlternate)
            try send(session, .flagsChanged, code: UInt16(kVK_Option))
            XCTAssertEqual(captured.map(\.keyCode), [UInt16(kVK_Option)])
        }
    }

    func testRestartDiscardsMissingReleaseAndKeepsProgressInSync() throws {
        let session = ShortcutRecordingSession()
        var progress: [ShortcutRecordingSession.Progress] = []
        var captured: RecordedShortcut?
        session.onProgress = { progress.append($0) }
        session.onCapture = { captured = $0 }
        session.start()
        try send(session, .keyDown, code: UInt16(kVK_ANSI_K), flags: .maskCommand)
        try send(session, .flagsChanged, code: UInt16(kVK_Command))
        XCTAssertEqual(progress.last, .waitingForRelease("⌘K"))
        XCTAssertNil(captured)
        session.start()
        XCTAssertEqual(progress.last, .waiting)
        try send(session, .keyDown, code: UInt16(kVK_ANSI_J))
        try send(session, .keyUp, code: UInt16(kVK_ANSI_J))
        XCTAssertEqual(captured?.keyCode, UInt16(kVK_ANSI_J))
    }

    func testPhysicalCapsLockRecordingCapturesTheMainKey() throws {
        let session = ShortcutRecordingSession()
        var captured: RecordedShortcut?
        session.onCapture = { captured = $0 }
        session.start()
        try send(session, .flagsChanged, code: UInt16(kVK_Command), flags: .maskCommand)
        try send(session, .flagsChanged, code: UInt16(kVK_CapsLock), flags: [.maskCommand, .maskAlphaShift])
        try send(session, .flagsChanged, code: UInt16(kVK_CapsLock), flags: [.maskCommand, .maskAlphaShift])
        try send(session, .flagsChanged, code: UInt16(kVK_Command), flags: .maskAlphaShift)
        XCTAssertEqual(captured?.label, "⌘Caps Lock")
        XCTAssertEqual(captured?.keyCode, UInt16(kVK_CapsLock))
    }

    func testRecordingIgnoresAnAlreadyHeldKeysRepeatsAndItsOwnSyntheticOutput() throws {
        let session = ShortcutRecordingSession()
        var captured: RecordedShortcut?
        session.onCapture = { captured = $0 }
        session.start()
        let sender = SystemEventSender(postEvent: {
            let event = NSEvent(cgEvent: $0)?.cgEvent ?? $0
            session.handle(event.type, event: event)
        })
        sender.send(ButtonMapping(action: .enter), pressed: true)
        sender.send(ButtonMapping(action: .enter), pressed: false)
        XCTAssertNil(captured)
        try send(session, .keyDown, code: UInt16(kVK_ANSI_A), repeatKey: true)
        try send(session, .keyDown, code: UInt16(kVK_ANSI_B))
        try send(session, .keyUp, code: UInt16(kVK_ANSI_B))
        XCTAssertEqual(captured?.keyCode, UInt16(kVK_ANSI_B))
    }

    func testHeldLegacyModifierKeepsItsPhysicalSideAcrossOtherEvents() throws {
        let rightShift = try XCTUnwrap(ShortcutRecordingSession.singleModifierShortcut(keyCode: UInt16(kVK_RightShift)))
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        sender.sendShortcut(rightShift, pressed: true)
        sender.send(ButtonMapping(action: .enter), pressed: true)
        sender.send(ButtonMapping(action: .enter), pressed: false)
        sender.sendShortcut(rightShift, pressed: false)
        let rightShiftFlags = CGEventFlags.maskShift.union(CGEventFlags(rawValue: 0x04))
        XCTAssertEqual(events.map(\.flags), [rightShiftFlags, rightShiftFlags, rightShiftFlags, []])
    }

    func testRecordingDoesNotMistakeASecondShiftForAStandaloneModifier() throws {
        let session = ShortcutRecordingSession()
        var captured: RecordedShortcut?
        session.onCapture = { captured = $0 }
        session.start()
        // Left Shift was already down when recording started.
        try send(session, .flagsChanged, code: UInt16(kVK_RightShift), flags: [.maskShift, .init(rawValue: 0x06)])
        try send(session, .flagsChanged, code: UInt16(kVK_Shift), flags: [.maskShift, .init(rawValue: 0x04)])
        try send(session, .flagsChanged, code: UInt16(kVK_RightShift))
        XCTAssertNil(captured)
        try send(session, .flagsChanged, code: UInt16(kVK_RightOption), flags: [.maskAlternate, .init(rawValue: 0x40)])
        try send(session, .flagsChanged, code: UInt16(kVK_RightOption))
        XCTAssertEqual(captured?.keyCode, UInt16(kVK_RightOption))
    }

    func testDvorakCommandKeycapsFollowTheSystemLayout() throws {
        let query = [kTISPropertyInputSourceID as String: "com.apple.keylayout.DVORAK-QWERTYCMD"] as CFDictionary
        let sources = TISCreateInputSourceList(query, true)?.takeRetainedValue() as? [TISInputSource]
        let source = try XCTUnwrap(sources?.first)
        let base = StandardShortcutKeyboard.keyLabels(for: source, command: false)
        let command = StandardShortcutKeyboard.keyLabels(for: source, command: true)
        let code = UInt16(kVK_ANSI_C)
        var selection = ShortcutKeyboardSelection(shortcut: nil, keyLabels: base, commandKeyLabels: command)
        selection.select(code)
        XCTAssertEqual(selection.shortcut?.label, "J")
        selection.toggle(.maskCommand)
        XCTAssertEqual(selection.keyLabels[code], "C")
        XCTAssertEqual(selection.shortcut?.label, "⌘C")

        let legacy = RecordedShortcut(keyCode: code, modifiers: CGEventFlags.maskCommand.rawValue | 0x10, label: "右侧 ⌘C")
        var reopened = ShortcutKeyboardSelection(shortcut: legacy, keyLabels: base, commandKeyLabels: command)
        reopened.select(code)
        XCTAssertEqual(reopened.shortcut, legacy)
    }

    func testScreenKeyboardKeepsOldChordsAndUsesLocalizedNamesForNewSelections() {
        let original = VoiceShortcutChoice.pairs[0].shortcut
        var selection = ShortcutKeyboardSelection(shortcut: original, keyLabels: [UInt16(kVK_ANSI_Y): "Z"])
        XCTAssertEqual(selection.shortcut, original)
        XCTAssertNil(selection.keyCode)
        selection.toggle(.maskCommand)
        selection.select(UInt16(kVK_ANSI_Y))
        XCTAssertEqual(selection.shortcut, RecordedShortcut(keyCode: UInt16(kVK_ANSI_Y),
                       modifiers: CGEventFlags.maskCommand.rawValue, label: "⌘Z"))
        XCTAssertEqual(ShortcutKeyboardPicker.height(visibleHeight: 510), 470)
    }

    func testFnNavigationSendsTheKeyCodeMacReceivesFromPhysicalKeyboard() throws {
        for (from, to) in [(kVK_Delete, kVK_ForwardDelete), (kVK_LeftArrow, kVK_Home),
                           (kVK_RightArrow, kVK_End), (kVK_UpArrow, kVK_PageUp), (kVK_DownArrow, kVK_PageDown)] {
            let shortcut = try XCTUnwrap(StandardShortcutKeyboard.shortcut(keyCode: UInt16(from), flags: [.maskSecondaryFn, .maskShift]))
            var events: [CGEvent] = []
            let sender = SystemEventSender(postEvent: { events.append($0) })
            sender.send(ButtonMapping(action: .recordedShortcut, shortcut: shortcut), pressed: true)
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
            XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [Int64(to), Int64(to)])
            XCTAssertTrue(events.first?.flags.contains(.maskShift) == true)
        }
    }

    func testFunctionFlagOnNavigationAndFunctionKeysDoesNotWaitForUnpressedFn() throws {
        for code: UInt16 in [123, 122] {
            let session = ShortcutRecordingSession()
            var captured: [RecordedShortcut] = []
            session.onCapture = { captured.append($0) }
            session.start()
            try send(session, .keyDown, code: code, flags: .maskSecondaryFn)
            try send(session, .keyUp, code: code, flags: .maskSecondaryFn)
            XCTAssertEqual(captured.count, 1)
            XCTAssertFalse(session.isRecording)
        }
    }

    func testCancelAndRestartDiscardPartialShortcut() throws {
        let session = ShortcutRecordingSession()
        var captured: [RecordedShortcut] = []
        session.onCapture = { captured.append($0) }
        session.start()
        try send(session, .flagsChanged, flags: .maskSecondaryFn)
        session.stop()
        XCTAssertFalse(try send(session, .flagsChanged))
        session.start()
        try send(session, .flagsChanged, code: 60, flags: .maskShift)
        try send(session, .flagsChanged, code: 60)
        XCTAssertEqual(captured.first?.keyCode, 60)
        XCTAssertEqual(captured.count, 1)
    }

    func testFieldFocusLossRemovalAndDismantlingStopLocalRecording() throws {
        let session = ShortcutRecordingSession()
        let field = ShortcutCapture.CaptureField(session: session)
        var cancellations = 0
        field.onCancel = { cancellations += 1 }
        session.onCapture = { _ in XCTFail("Focus loss must discard a partial recording") }
        session.start()
        try send(session, .flagsChanged, flags: .maskSecondaryFn)
        XCTAssertTrue(field.resignFirstResponder())
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(session.isRecording)
        session.start()
        ShortcutCapture.dismantleNSView(field, coordinator: ())
        XCTAssertFalse(session.isRecording)
        session.start()
        field.viewDidMoveToWindow()
        XCTAssertFalse(session.isRecording)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        XCTAssertFalse(field.performKeyEquivalent(with: event))
    }
}
