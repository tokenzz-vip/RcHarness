import AppKit
import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class ShortcutRecordingTests: XCTestCase {
    @MainActor
    private final class Interceptor: ShortcutEventIntercepting {
        var canStart = true
        var failureMessage: String?
        var handler: ((CGEventType, CGEvent) -> Bool)?
        var downstreamEvents = 0
        var stops = 0
        func start(handler: @escaping (CGEventType, CGEvent) -> Bool) -> Bool {
            guard canStart else { return false }
            self.handler = handler
            return true
        }
        func stop() { handler = nil; stops += 1 }
        func send(_ type: CGEventType, code: UInt16 = 63, flags: CGEventFlags = [], repeatKey: Bool = false) throws {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type != .keyUp))
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
            // Models the next shortcut listener. No events reach the real session.
            if handler?(type, event) != true { downstreamEvents += 1 }
        }
    }

    func testFnIsCapturedAndBothEdgesAreHiddenFromOtherShortcutListeners() throws {
        let tap = Interceptor()
        let recorder = ShortcutRecordingSession(interceptor: tap)
        var captured: [RecordedShortcut] = []
        recorder.onCapture = { captured.append($0) }
        recorder.start()
        try tap.send(.flagsChanged, flags: .maskSecondaryFn)
        XCTAssertTrue(captured.isEmpty)
        try tap.send(.flagsChanged)
        XCTAssertEqual(captured, [.voiceHoldDefault])
        XCTAssertEqual(tap.downstreamEvents, 0)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(tap.handler)
        try tap.send(.keyDown, code: 49)
        XCTAssertEqual(tap.downstreamEvents, 1, "Normal keyboard delivery resumes immediately after recording")
    }

    func testFnSpaceWaitsForKeyAndModifierReleasesInEitherOrder() throws {
        for releaseModifierFirst in [false, true] {
            let tap = Interceptor()
            let recorder = ShortcutRecordingSession(interceptor: tap)
            var captured: [RecordedShortcut] = []
            recorder.onCapture = { captured.append($0) }
            recorder.start()
            try tap.send(.flagsChanged, flags: .maskSecondaryFn)
            try tap.send(.keyDown, code: 49, flags: .maskSecondaryFn)
            try tap.send(.keyDown, code: 49, flags: .maskSecondaryFn, repeatKey: true)
            XCTAssertTrue(captured.isEmpty)
            if releaseModifierFirst {
                try tap.send(.flagsChanged)
                XCTAssertTrue(captured.isEmpty)
                try tap.send(.keyUp, code: 49)
            } else {
                try tap.send(.keyUp, code: 49, flags: .maskSecondaryFn)
                XCTAssertTrue(captured.isEmpty)
                try tap.send(.flagsChanged)
            }
            XCTAssertEqual(captured, [.voiceTapDefault])
            XCTAssertEqual(tap.downstreamEvents, 0)
            XCTAssertNil(tap.handler)
        }
    }

    func testCreationFailureReportsErrorAndDoesNotRecordUnprotectedEvents() throws {
        let tap = Interceptor()
        tap.canStart = false
        let recorder = ShortcutRecordingSession(interceptor: tap)
        var failures: [String] = []
        recorder.onFailure = { failures.append($0) }
        recorder.onCapture = { _ in XCTFail("Must not fall back to unprotected recording") }
        recorder.start()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("辅助功能"))
        XCTAssertTrue(failures[0].contains("输入监控"))
        try tap.send(.flagsChanged, flags: .maskSecondaryFn)
        XCTAssertEqual(tap.downstreamEvents, 1)
    }

    func testProtectionFailureReasonIsShownWithoutSavingShortcut() {
        let tap = Interceptor()
        tap.canStart = false
        tap.failureMessage = "无法启用受保护的键盘录制"
        let recorder = ShortcutRecordingSession(interceptor: tap)
        var failure: String?
        recorder.onFailure = { failure = $0 }
        recorder.onCapture = { _ in XCTFail("Protection failure must not save a shortcut") }
        recorder.start()
        XCTAssertEqual(failure, tap.failureMessage)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(tap.handler)
    }

    func testProtectionBalancesRepeatedStartAndStopWithoutReleasingOtherOwners() {
        var claims = 1 // Another application's existing claim must survive.
        var enables = 0
        var disables = 0
        let protection = ShortcutInputProtection(enable: {
            claims += 1
            enables += 1
            return 0
        }, disable: {
            claims -= 1
            disables += 1
            return 0
        })
        XCTAssertTrue(protection.start())
        XCTAssertTrue(protection.start())
        XCTAssertTrue(protection.isActive)
        XCTAssertEqual(claims, 2)
        protection.stop()
        protection.stop()
        XCTAssertFalse(protection.isActive)
        XCTAssertEqual(enables, 1)
        XCTAssertEqual(disables, 1)
        XCTAssertEqual(claims, 1)
        XCTAssertTrue(protection.start())
        protection.stop()
        XCTAssertEqual(claims, 1)
        XCTAssertEqual(disables, 2)
    }

    func testFailedProtectionDoesNotReleaseAnUnownedClaim() {
        var disables = 0
        let protection = ShortcutInputProtection(enable: { -1 }, disable: { disables += 1; return 0 })
        XCTAssertFalse(protection.start())
        protection.stop()
        XCTAssertFalse(protection.isActive)
        XCTAssertEqual(disables, 0)
    }

    func testProtectionIsReleasedWhenItsOwnerIsDestroyed() {
        var claims = 0
        var protection: ShortcutInputProtection? = ShortcutInputProtection(enable: { claims += 1; return 0 },
                                                                         disable: { claims -= 1; return 0 })
        XCTAssertTrue(protection?.start() == true)
        XCTAssertEqual(claims, 1)
        protection = nil
        XCTAssertEqual(claims, 0)
    }

    func testDisabledTapStopsAndDiscardsPartialShortcut() throws {
        for reason in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let tap = Interceptor()
            let recorder = ShortcutRecordingSession(interceptor: tap)
            var failures: [String] = []
            recorder.onFailure = { failures.append($0) }
            recorder.onCapture = { _ in XCTFail("Partial capture must be discarded") }
            recorder.start()
            try tap.send(.flagsChanged, flags: .maskSecondaryFn)
            try tap.send(reason)
            XCTAssertFalse(recorder.isRecording)
            XCTAssertNil(tap.handler)
            XCTAssertEqual(failures.count, 1)
            try tap.send(.flagsChanged)
        }
    }

    func testCancelClearsPendingStateAndRestartCanRecordAnotherModifier() throws {
        let tap = Interceptor()
        let recorder = ShortcutRecordingSession(interceptor: tap)
        var captured: [RecordedShortcut] = []
        recorder.onCapture = { captured.append($0) }
        recorder.start()
        try tap.send(.flagsChanged, flags: .maskSecondaryFn)
        recorder.stop()
        try tap.send(.flagsChanged)
        XCTAssertTrue(captured.isEmpty)
        recorder.start()
        try tap.send(.flagsChanged, code: 54, flags: .maskCommand)
        try tap.send(.flagsChanged, code: 54)
        XCTAssertEqual(captured, [RecordedShortcut(keyCode: 54, modifiers: CGEventFlags.maskCommand.rawValue, label: "右侧 Command")])
    }

    func testOrdinaryShortcutConsumesCommandAndKeyReleases() throws {
        let tap = Interceptor()
        let recorder = ShortcutRecordingSession(interceptor: tap)
        var captured: [RecordedShortcut] = []
        recorder.onCapture = { captured.append($0) }
        recorder.start()
        try tap.send(.flagsChanged, code: 55, flags: .maskCommand)
        try tap.send(.keyDown, code: 40, flags: .maskCommand)
        try tap.send(.keyUp, code: 40, flags: .maskCommand)
        XCTAssertTrue(captured.isEmpty)
        try tap.send(.flagsChanged, code: 55)
        XCTAssertEqual(captured.first?.keyCode, 40)
        XCTAssertEqual(captured.first?.modifiers, CGEventFlags.maskCommand.rawValue)
        XCTAssertEqual(tap.downstreamEvents, 0)
    }

    func testFunctionFlagOnArrowAndFKeysDoesNotWaitForAnUnpressedFnKey() throws {
        for code: UInt16 in [123, 122] {
            let tap = Interceptor()
            let recorder = ShortcutRecordingSession(interceptor: tap)
            var captured: [RecordedShortcut] = []
            recorder.onCapture = { captured.append($0) }
            recorder.start()
            try tap.send(.keyDown, code: code, flags: .maskSecondaryFn)
            try tap.send(.keyUp, code: code, flags: .maskSecondaryFn)
            XCTAssertEqual(captured.count, 1)
            XCTAssertFalse(recorder.isRecording)
        }
    }

    func testFieldResigningFocusAndDismantlingStopInterception() throws {
        let tap = Interceptor()
        let recorder = ShortcutRecordingSession(interceptor: tap)
        let field = ShortcutCapture.CaptureField(session: recorder)
        var cancellations = 0
        field.onCancel = { cancellations += 1 }
        recorder.onCapture = { _ in XCTFail("Must discard recording on focus loss") }
        recorder.start()
        try tap.send(.flagsChanged, flags: .maskSecondaryFn)
        XCTAssertTrue(field.resignFirstResponder())
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(tap.handler)

        recorder.start()
        ShortcutCapture.dismantleNSView(field, coordinator: ())
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(tap.handler)

        recorder.start()
        field.viewDidMoveToWindow() // A field removed from the window stops, too.
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(tap.handler)
    }
}
