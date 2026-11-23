import AppKit
import XCTest
@testable import RcHarness

@MainActor
final class RemoteMouseTests: XCTestCase {
    func testMouseSettingsFollowTheModelThroughReloadAndBackup() throws {
        let suite = "RcHarness.MouseTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let xiaomi = RemoteMouseSettings(leftClick: nil, rightClick: .rightShoulder, speed: 12)
        model.setMouseSettings(xiaomi)

        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertEqual(model.mouseSettings, RemoteMouseSettings())
        model.setMouseSettings(RemoteMouseSettings(leftClick: .youtube, rightClick: .mute, speed: 35))
        model.setGlobalInput(.youtube, at: 0)
        let google = RemoteMouseSettings(leftClick: nil, rightClick: .mute, speed: 35)
        XCTAssertEqual(model.mouseSettings, google)

        let reloaded = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(reloaded.mouseSettings, google)
        reloaded.selectRemoteProfile(RemoteProfiles.xiaomiRC003.id)
        XCTAssertEqual(reloaded.mouseSettings, xiaomi)
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(reloaded.configurationBackup()))
        reloaded.setMouseSettings(RemoteMouseSettings())
        try reloaded.applyConfiguration(backup)
        XCTAssertEqual(reloaded.mouseSettings, xiaomi)
        reloaded.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertEqual(reloaded.mouseSettings, google)
    }

    func testPointerRepeatsAtCurrentSpeedAndResetReleasesDrag() {
        let clock = TestClock()
        var events: [(CGEventType, CGPoint)] = []
        var cursor = CGPoint(x: 100, y: 100)
        let sender = SystemEventSender(cursorLocation: { cursor }, postEvent: { event in
            events.append((event.type, event.location))
            cursor = event.location
        })
        var speed = 20
        let mouse = RemoteMouseController(sender: sender, speed: { speed }, schedule: clock.schedule)
        let settings = RemoteMouseSettings()

        XCTAssertTrue(mouse.press(.buttonA, settings: settings, mapping: .defaults))
        XCTAssertTrue(mouse.press(.dpadRight, settings: settings, mapping: .defaults))
        speed = 10
        clock.advance(0.02)
        mouse.reset()
        clock.advance(1)
        XCTAssertFalse(mouse.release(.buttonA))
        XCTAssertEqual(events.map(\.0), [.leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseUp])
        XCTAssertEqual(events.map(\.1), [CGPoint(x: 100, y: 100), CGPoint(x: 110, y: 100),
                                         CGPoint(x: 115, y: 100), CGPoint(x: 115, y: 100)])

        XCTAssertTrue(mouse.press(.dpadUp, settings: settings, mapping: .defaults))
        XCTAssertTrue(mouse.release(.dpadUp))
        clock.advance(1)
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events.last?.0, .mouseMoved)
        XCTAssertEqual(events.last?.1, CGPoint(x: 115, y: 95))
    }

    func testChangingClickBindingsWhileHeldReleasesTheOriginalButton() {
        var events: [CGEventType] = []
        let sender = SystemEventSender(cursorLocation: { .zero }, postEvent: { events.append($0.type) })
        let mouse = RemoteMouseController(sender: sender, speed: { 21 })
        var settings = RemoteMouseSettings()

        XCTAssertTrue(mouse.press(.buttonB, settings: settings, mapping: .defaults))
        settings.rightClick = .menu
        XCTAssertTrue(mouse.release(.buttonB))
        XCTAssertFalse(mouse.press(.buttonB, settings: settings, mapping: .defaults))
        XCTAssertEqual(events, [.rightMouseDown, .rightMouseUp])
    }

    func testConfirmEmitsOneCompleteMouseClick() throws {
        var clicks: [CGEvent] = []
        let sender = SystemEventSender(cursorLocation: { .zero }, postEvent: { clicks.append($0) })
        let mouse = RemoteMouseController(sender: sender, speed: { 21 })

        XCTAssertTrue(mouse.press(.buttonA, settings: RemoteMouseSettings(), mapping: .defaults))
        XCTAssertTrue(mouse.release(.buttonA))

        XCTAssertEqual(clicks.map(\.type), [.leftMouseDown, .leftMouseUp])
        XCTAssertEqual(clicks.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1])
    }

    func testHIDSourceCanDeliverMouseReleaseDuringAppKitTracking() throws {
        _ = NSApplication.shared
        let runLoop = CFRunLoopGetMain()
        let trackingMode = CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString)
        var deliveredRelease = false
        try withUnsafeMutablePointer(to: &deliveredRelease) { delivered in
            var context = CFRunLoopSourceContext()
            context.info = UnsafeMutableRawPointer(delivered)
            context.perform = { info in info?.assumingMemoryBound(to: Bool.self).pointee = true }
            let source = try XCTUnwrap(CFRunLoopSourceCreate(nil, 0, &context))
            let inputMode = XiaomiRemoteHIDManager.inputRunLoopMode
            CFRunLoopAddSource(runLoop, source, inputMode)
            defer { CFRunLoopRemoveSource(runLoop, source, inputMode) }

            CFRunLoopSourceSignal(source)
            CFRunLoopRunInMode(trackingMode, 0, false)
        }
        XCTAssertTrue(deliveredRelease, "AppKit's mouse tracking must be able to receive the HID release")
    }

    func testLongPressCanToggleBothWaysOnAKeyNormallyUsedForMouseClicks() {
        let clock = TestClock()
        let sender = SystemEventSender(cursorLocation: { .zero }, postEvent: { _ in XCTFail("Unexpected mouse event") })
        let mouse = RemoteMouseController(sender: sender, speed: { 21 }, schedule: clock.schedule)
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var mapping = RemoteMapping.defaults
        mapping[.buttonA, .long] = ButtonMapping(action: .toggleMouseMode)
        var enabled = false
        gestures.onOutput = { action, pressed, _ in
            guard action.action == .toggleMouseMode, pressed else { return }
            enabled.toggle()
            mouse.reset()
            gestures.cancel()
        }

        for expected in [true, false] {
            if enabled {
                XCTAssertFalse(mouse.press(.buttonA, settings: RemoteMouseSettings(), mapping: mapping))
            }
            gestures.handle(.buttonA, pressed: true, mapping: mapping)
            clock.advance(RemoteGestureController.longPressDelay)
            gestures.handle(.buttonA, pressed: false, mapping: mapping)
            XCTAssertEqual(enabled, expected)
        }
        gestures.onOutput = nil
    }
}
