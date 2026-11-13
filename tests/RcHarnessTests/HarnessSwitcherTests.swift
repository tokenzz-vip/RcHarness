import AppKit
import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class HarnessSwitcherTests: XCTestCase {
    func testControllerRepeatedlyPresentsAVisiblePanelFromTheBackground() throws {
        try checkControllerPresentation()
    }

    func testControllerPresentationSkipsWhenDisplaysAreAsleep() {
        // Exercise the same integration-test entry point without putting the
        // user's physical displays to sleep or changing their desktop session.
        XCTAssertThrowsError(try checkControllerPresentation(isDisplayAsleep: { _ in true })) {
            XCTAssertTrue($0 is XCTSkip, "A sleeping display is an unavailable test environment")
        }
    }

    private func checkControllerPresentation(
        isDisplayAsleep: (CGDirectDisplayID) -> Bool = { CGDisplayIsAsleep($0) != 0 }
    ) throws {
        let app = NSApplication.shared
        let displays = NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        // WindowServer can show the panel while refusing key focus when every
        // display is asleep. Keep the focus assertions for an awake desktop.
        try XCTSkipIf(displays.isEmpty || displays.allSatisfy(isDisplayAsleep),
                      "Keyboard focus requires an awake display; rerun this integration test with the screen on.")
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let controller = HarnessSwitcherController(harnesses: { [] }, onSelection: { _ in }, onError: { _ in })
        defer { controller.model.dismiss() }

        for testPolicy in [NSApplication.ActivationPolicy.regular, .accessory] {
            app.setActivationPolicy(testPolicy)
            for _ in 0..<10 {
                controller.show()
                XCTAssertTrue(controller.model.isPresented)
                XCTAssertTrue(controller.renderView?.window?.isVisible == true)
                XCTAssertTrue(controller.renderView?.window?.isOnActiveSpace == true)
                XCTAssertTrue(controller.renderView?.window?.isKeyWindow == true)
                controller.model.dismiss()
                XCTAssertFalse(controller.renderView?.window?.isVisible == true)
            }
        }
    }

    func testPowerSingleClickShowsPanelWithDoubleAndLongMappingsConfigured() {
        _ = NSApplication.shared
        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        let controller = HarnessSwitcherController(harnesses: { [] }, onSelection: { _ in }, onError: { _ in })
        let mapping = GlobalButtonSettings(single: ButtonMapping(action: .openHarnessSwitcher),
                                           double: ButtonMapping(action: .volumeDown),
                                           long: ButtonMapping(action: .macro)).applying(to: .defaults)
        let parser = XiaomiRemoteHIDParser()
        var actions: [RemoteAction] = []
        gestures.onOutput = { value, pressed, _ in
            guard pressed else { return }
            actions.append(value.action)
            if value.action == .openHarnessSwitcher {
                controller.show()
                gestures.cancel()
            }
        }
        defer {
            gestures.onOutput = nil
            gestures.cancel()
            controller.model.dismiss()
        }
        func route(_ input: ControllerInput, _ pressed: Bool) {
            if !controller.model.handle(input, pressed: pressed) {
                gestures.handle(input, pressed: pressed, mapping: mapping)
            }
        }
        // Exercise all supported power usages through parsing, gesture timing,
        // modal routing and a real AppKit panel without posting system events.
        for (page, usage): (UInt32, UInt32) in [(0x01, 0x81), (0x0C, 0x30), (0x07, 0x66)] {
            for value in [1, 0] {
                for event in parser.parse(usagePage: page, usage: usage, value: value) {
                    route(event.input, event.isPressed)
                }
            }
            XCTAssertFalse(controller.model.isPresented)
            clock.advance(RemoteGestureController.doubleTapWindow + 0.01)
            XCTAssertEqual(actions.last, .openHarnessSwitcher)
            XCTAssertTrue(controller.model.isPresented)
            XCTAssertTrue(controller.renderView?.window?.isVisible == true)
            clock.advance(1)
            XCTAssertTrue(controller.model.isPresented)
            route(.menu, true)
            route(.menu, false)
            XCTAssertFalse(controller.renderView?.window?.isVisible == true)
        }
        XCTAssertEqual(actions, Array(repeating: .openHarnessSwitcher, count: 3))

        actions.removeAll()
        route(.power, true)
        route(.power, false)
        clock.advance(0.1)
        route(.power, true)
        route(.power, false)
        clock.advance(1)
        XCTAssertEqual(actions, [.volumeDown])
        XCTAssertFalse(controller.model.isPresented)

        route(.power, true)
        clock.advance(RemoteGestureController.longPressDelay + 0.01)
        route(.power, false)
        clock.advance(1)
        XCTAssertEqual(actions, [.volumeDown, .macro])
        XCTAssertFalse(controller.model.isPresented)
    }


    private func application(_ pid: Int32, bundle: String? = nil, path: String? = nil,
                             regular: Bool = true) -> HarnessRunningApplication {
        HarnessRunningApplication(processID: pid, bundleIdentifier: bundle, applicationPath: path, isRegular: regular)
    }

    private var items: [HarnessSwitcherItem] {
        HarnessSwitcherItem.running(harnesses: HarnessConfiguration.defaults, applications: [
            application(10, bundle: "com.openai.codex"), application(20, bundle: "com.deepseek.dsh")
        ])
    }

    func testCatalogIncludesOnlyRunningEnabledHarnessesAndSupportsCustomAppsWithoutBindings() {
        var harnesses = HarnessConfiguration.defaults
        harnesses[1].isEnabled = false
        harnesses.append(HarnessConfiguration(id: "local", name: "本机 Harness", applicationPath: "/Applications/Local.app"))
        harnesses.append(harnesses[0])
        let apps = [application(10, bundle: "com.openai.codex"), application(11, bundle: "com.openai.codex", regular: false),
                    application(20, bundle: "com.anthropic.claudefordesktop"), application(30, bundle: "com.deepseek.dsh"),
                    application(40, path: "/Applications/Local.app"), application(50, bundle: "other.app"),
                    application(60, bundle: "com.tencent.workbuddy.mac")]
        let items = HarnessSwitcherItem.running(harnesses: harnesses, applications: apps)
        XCTAssertEqual(items.map(\.id), [10, 30, 60, 40])
        XCTAssertEqual(items.map(\.harnessID), ["codex", "deepseek", "workbuddy", "local"])
        XCTAssertTrue(harnesses.allSatisfy { $0.profileID == nil })
    }

    func testNavigationWrapsAndIgnoresDuplicateEdgesUntilRelease() {
        let model = HarnessSwitcherModel()
        model.present(items: items, frontmostProcessID: 20)
        XCTAssertEqual(model.selectedID, 20)
        XCTAssertTrue(model.handle(.dpadRight, pressed: true))
        XCTAssertEqual(model.selectedID, 10)
        XCTAssertTrue(model.handle(.dpadRight, pressed: true))
        XCTAssertEqual(model.selectedID, 10)
        XCTAssertTrue(model.handle(.dpadRight, pressed: false))
        model.handle(.dpadLeft, pressed: true)
        XCTAssertEqual(model.selectedID, 20)
        model.handle(.dpadLeft, pressed: false)
        model.move(-1)
        XCTAssertEqual(model.selectedID, 10)
    }

    func testOpeningWithConfirmDoesNotConfirmUntilANewPressAndItsReleaseCannotLeak() {
        let model = HarnessSwitcherModel()
        var activated: [Int32] = []
        model.onConfirm = { activated.append($0.id) }
        XCTAssertFalse(model.handle(.buttonA, pressed: true))
        model.present(items: items, frontmostProcessID: nil)
        XCTAssertTrue(model.handle(.buttonA, pressed: true))
        XCTAssertTrue(model.handle(.buttonA, pressed: false))
        XCTAssertTrue(model.isPresented)
        XCTAssertTrue(activated.isEmpty)
        model.handle(.dpadRight, pressed: true)
        model.handle(.dpadRight, pressed: false)
        model.handle(.buttonA, pressed: true)
        XCTAssertFalse(model.isPresented)
        XCTAssertEqual(activated, [20])
        XCTAssertTrue(model.handle(.buttonA, pressed: false))
        XCTAssertFalse(model.handle(.buttonA, pressed: true))
        XCTAssertFalse(model.handle(.buttonA, pressed: false))
        XCTAssertEqual(activated, [20])
    }

    func testTriggerKeyRepeatsSelectionAndAutoConfirmsAfterTwoSecondsOfIdle() {
        let clock = TestClock()
        let model = HarnessSwitcherModel(schedule: clock.schedule)
        var activated: [Int32] = []
        model.onConfirm = { activated.append($0.id) }
        model.handle(.home, pressed: true)
        model.present(items: items, frontmostProcessID: 20, triggerInput: .home)
        XCTAssertEqual(model.selectedID, 20)
        model.handle(.home, pressed: false)
        clock.advance(1.99)
        XCTAssertTrue(model.isPresented)
        model.handle(.home, pressed: true)
        XCTAssertEqual(model.selectedID, 10)
        model.handle(.home, pressed: false)
        clock.advance(1.99)
        XCTAssertTrue(model.isPresented)
        clock.advance(0.01)
        XCTAssertFalse(model.isPresented)
        XCTAssertEqual(activated, [10])
    }

    func testTriggerKeyHeldRepeatsAndStopsOnReleaseWithoutLeakingToNormalRouting() {
        let clock = TestClock()
        let model = HarnessSwitcherModel(schedule: clock.schedule)
        model.handle(.home, pressed: true)
        model.present(items: items, frontmostProcessID: 20, triggerInput: .home)
        clock.advance(HarnessSwitcherModel.repeatDelay)
        XCTAssertEqual(model.selectedID, 10)
        clock.advance(HarnessSwitcherModel.repeatInterval + 0.01)
        XCTAssertEqual(model.selectedID, 20)
        model.handle(.home, pressed: false)
        let selected = model.selectedID
        clock.advance(HarnessSwitcherModel.repeatInterval * 5)
        XCTAssertEqual(model.selectedID, selected)
        model.handle(.home, pressed: false)
        clock.advance(HarnessSwitcherModel.confirmationDelay)
        XCTAssertFalse(model.isPresented)
    }

    func testDismissConsumesAllHeldReleasesAndResetRestoresNormalRouting() {
        for cancel in [ControllerInput.buttonB, .home, .menu] {
            let model = HarnessSwitcherModel()
            var activations = 0
            model.onConfirm = { _ in activations += 1 }
            model.present(items: items, frontmostProcessID: nil)
            model.handle(.options, pressed: true)
            model.handle(.dpadLeft, pressed: true)
            model.handle(cancel, pressed: true)
            XCTAssertFalse(model.isPresented)
            for key in [ControllerInput.options, .dpadLeft, cancel] {
                XCTAssertTrue(model.handle(key, pressed: false))
            }
            XCTAssertEqual(activations, 0)
            model.present(items: items, frontmostProcessID: nil)
            model.handle(.buttonA, pressed: true)
            model.reset()
            XCTAssertFalse(model.handle(.buttonA, pressed: true))
        }
    }

    func testRefreshPreservesSelectionAndCannotActivateAProcessThatExited() {
        let model = HarnessSwitcherModel()
        var activated: [Int32] = []
        model.onConfirm = { activated.append($0.id) }
        model.present(items: items, frontmostProcessID: 20)
        model.refresh(items: items.reversed())
        XCTAssertEqual(model.selectedID, 20)
        model.refresh(items: [items[0]])
        XCTAssertEqual(model.selectedID, 10)
        model.confirm(20)
        XCTAssertTrue(activated.isEmpty)
        model.refresh(items: [])
        model.handle(.buttonA, pressed: true)
        model.handle(.buttonA, pressed: false)
        model.move(1)
        XCTAssertNil(model.selectedID)
        XCTAssertTrue(model.isPresented)
        XCTAssertTrue(activated.isEmpty)
        model.refresh(items: [items[1]])
        model.move(-1)
        XCTAssertEqual(model.selectedID, 20)
        model.confirm()
        XCTAssertEqual(activated, [20])
    }

    func testModalNavigationOverridesCustomGesturesAndBalancesPreviouslyHeldMouseButton() {
        let clock = TestClock()
        let model = HarnessSwitcherModel()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var events: [CGEventType] = []
        let sender = SystemEventSender(postEvent: { events.append($0.type) })
        var mapping = RemoteMapping.defaults
        mapping[.home] = ButtonMapping(action: .openHarnessSwitcher)
        mapping[.buttonA] = ButtonMapping(action: .mouseLeft)
        mapping[.dpadRight] = ButtonMapping(action: .paste)
        mapping[.dpadRight, .double] = ButtonMapping(action: .copy)
        mapping[.dpadRight, .long] = ButtonMapping(action: .screenshot)
        gestures.onOutput = { value, pressed, _ in
            if value.action == .openHarnessSwitcher {
                if pressed {
                    model.present(items: self.items, frontmostProcessID: nil)
                    gestures.cancel()
                }
            } else { sender.send(value, pressed: pressed) }
        }
        func route(_ input: ControllerInput, _ pressed: Bool) {
            if !model.handle(input, pressed: pressed) { gestures.handle(input, pressed: pressed, mapping: mapping) }
        }
        route(.buttonA, true)
        route(.home, true)
        XCTAssertEqual(events, [.leftMouseDown, .leftMouseUp])
        route(.home, false)
        route(.buttonA, false)
        route(.dpadRight, true)
        clock.advance(1)
        route(.dpadRight, false)
        XCTAssertEqual(model.selectedID, 20)
        route(.buttonA, true)
        route(.buttonA, false)
        clock.advance(1)
        XCTAssertFalse(model.isPresented)
        XCTAssertEqual(events, [.leftMouseDown, .leftMouseUp])
        route(.buttonA, true)
        route(.buttonA, false)
        XCTAssertEqual(events, [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        gestures.onOutput = nil
    }

    func testOpeningCancelsPendingDoubleClickInsteadOfFiringItBehindTheOverlay() {
        let clock = TestClock()
        let gestures = RemoteGestureController(schedule: clock.schedule)
        var mapping = RemoteMapping.defaults
        mapping[.dpadRight, .double] = ButtonMapping(action: .copy)
        var output: [RemoteAction] = []
        gestures.onOutput = { value, pressed, _ in if pressed { output.append(value.action) } }
        gestures.handle(.dpadRight, pressed: true, mapping: mapping)
        gestures.handle(.dpadRight, pressed: false, mapping: mapping)
        gestures.cancel()
        clock.advance(1)
        XCTAssertTrue(output.isEmpty)
    }

    func testActionRoundTripsInConfigurationAndIsRejectedInMacros() throws {
        var mapping = RemoteMapping.defaults
        mapping[.home, .long] = ButtonMapping(action: .openHarnessSwitcher)
        let backup = SettingsBackup(mapping: mapping, profiles: [], macros: [], phrases: [])
        let restored = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(backup))
        XCTAssertEqual(restored.mapping[.home, .long].action, .openHarnessSwitcher)
        let macro = SavedMacro(name: "打开列表", steps: [MacroStep(mapping: ButtonMapping(action: .openHarnessSwitcher))])
        XCTAssertThrowsError(try MacroExecutionPlan(macro, macros: [macro])) { error in
            XCTAssertEqual(error as? MacroExecutionError, .unsupportedAction)
        }
    }
}
