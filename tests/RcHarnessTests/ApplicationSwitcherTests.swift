import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class ApplicationSwitcherTests: XCTestCase {
    @MainActor
    private final class Harness {
        let clock = TestClock()
        let gestures: RemoteGestureController
        var mapping = RemoteMapping.defaults
        var events: [CGEvent] = []
        var ordinaryActions: [RemoteAction] = []
        lazy var sender = SystemEventSender(postEvent: { [weak self] in self?.events.append($0) })
        lazy var switcher = ApplicationSwitcherController(schedule: clock.schedule) { [weak self] mapping, pressed in
            self?.sender.send(mapping, pressed: pressed)
        }

        init(input: ControllerInput = .home, trigger: ButtonTrigger = .single) {
            gestures = RemoteGestureController(schedule: clock.schedule)
            mapping[input] = ButtonMapping(action: .disabled)
            mapping[input, trigger] = ButtonMapping(action: .switchApplications)
            gestures.onOutput = { [weak self] mapping, pressed, input in
                guard let self else { return }
                if mapping.action == .switchApplications {
                    if pressed {
                        self.gestures.cancel()
                        self.switcher.present(input: input)
                    }
                } else {
                    if pressed { self.ordinaryActions.append(mapping.action) }
                    self.sender.send(mapping, pressed: pressed)
                }
            }
        }

        func route(_ input: ControllerInput, _ pressed: Bool) {
            if !switcher.handle(input, pressed: pressed) {
                gestures.handle(input, pressed: pressed, mapping: mapping)
            }
        }

        func tap(_ input: ControllerInput) {
            route(input, true)
            route(input, false)
        }

        var tabDowns: [CGEvent] {
            events.filter { $0.type == .keyDown && $0.getIntegerValueField(.keyboardEventKeycode) == 0x30 }
        }
    }

    func testFirstPressOpensNativeSwitcherAndConfirmsOnlyAfterIdle() {
        let h = Harness()
        h.route(.home, true)
        XCTAssertTrue(h.switcher.isPresented)
        XCTAssertEqual(h.events.map(\.type), [.flagsChanged, .keyDown, .keyUp])
        XCTAssertEqual(h.events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [0x37, 0x30, 0x30])
        XCTAssertTrue(h.events.allSatisfy { $0.flags.contains(.maskCommand) })
        h.route(.home, false)
        h.clock.advance(1.99)
        XCTAssertTrue(h.switcher.isPresented)
        XCTAssertEqual(h.events.count, 3)
        h.clock.advance(0.01)
        XCTAssertFalse(h.switcher.isPresented)
        XCTAssertEqual(h.events.last?.type, .flagsChanged)
        XCTAssertEqual(h.events.last?.getIntegerValueField(.keyboardEventKeycode), 0x37)
        XCTAssertEqual(h.events.last?.flags, [])
    }

    func testSubsequentPressesBypassDoubleAndLongGesturesAndExtendIdleDeadline() {
        let h = Harness(input: .power)
        h.mapping[.power, .double] = ButtonMapping(action: .copy)
        h.mapping[.power, .long] = ButtonMapping(action: .paste)
        h.tap(.power)
        h.clock.advance(0.3)
        XCTAssertTrue(h.switcher.isPresented)
        h.clock.advance(1)
        h.tap(.power)
        h.tap(.power)
        XCTAssertEqual(h.tabDowns.count, 3)
        XCTAssertTrue(h.ordinaryActions.isEmpty)
        h.clock.advance(1.99)
        XCTAssertTrue(h.switcher.isPresented)
        h.clock.advance(0.01)
        XCTAssertFalse(h.switcher.isPresented)
        XCTAssertEqual(h.events.last?.flags, [])
    }

    func testLongPressBindingRepeatsWhileHeldAndStopsRepeatingOnRelease() {
        let h = Harness(trigger: .long)
        h.route(.home, true)
        h.clock.advance(0.55)
        XCTAssertEqual(h.tabDowns.count, 1)
        h.clock.advance(0.35)
        XCTAssertEqual(h.tabDowns.count, 2)
        h.clock.advance(0.24)
        XCTAssertEqual(h.tabDowns.count, 4)
        h.route(.home, false)
        h.clock.advance(1.99)
        XCTAssertEqual(h.tabDowns.count, 4)
        XCTAssertTrue(h.switcher.isPresented)
        h.clock.advance(0.01)
        XCTAssertFalse(h.switcher.isPresented)
        XCTAssertEqual(h.events.last?.flags, [])
    }

    func testDoubleClickOpeningRemembersItsInputAndIgnoresDuplicateDowns() {
        let h = Harness(input: .buttonA, trigger: .double)
        h.tap(.buttonA)
        h.tap(.buttonA)
        XCTAssertTrue(h.switcher.isPresented)
        XCTAssertEqual(h.tabDowns.count, 1)
        h.route(.buttonA, true)
        h.route(.buttonA, true)
        XCTAssertEqual(h.tabDowns.count, 2)
        h.route(.buttonA, false)
        h.clock.advance(2)
        XCTAssertFalse(h.switcher.isPresented)
        XCTAssertTrue(h.ordinaryActions.isEmpty)
    }

    func testReturnCancelsBeforeReleasingCommandAndConsumesItsRelease() {
        let h = Harness()
        h.tap(.home)
        h.route(.buttonB, true)
        XCTAssertFalse(h.switcher.isPresented)
        XCTAssertEqual(h.events.suffix(3).map { $0.getIntegerValueField(.keyboardEventKeycode) }, [0x35, 0x35, 0x37])
        XCTAssertTrue(h.events.dropLast().allSatisfy { $0.flags.contains(.maskCommand) })
        XCTAssertEqual(h.events.last?.flags, [])
        let count = h.events.count
        h.route(.buttonB, false)
        h.clock.advance(5)
        XCTAssertEqual(h.events.count, count)
        XCTAssertTrue(h.ordinaryActions.isEmpty)
        h.tap(.buttonA)
        XCTAssertEqual(h.ordinaryActions, [.enter])
        XCTAssertTrue(h.events.suffix(2).allSatisfy { $0.flags.isEmpty })
    }

    func testConfirmWhileTriggerHeldConsumesBothReleasesAndCancelsRepeat() {
        let h = Harness()
        h.route(.home, true)
        h.route(.buttonA, true)
        XCTAssertFalse(h.switcher.isPresented)
        let count = h.events.count
        h.route(.buttonA, false)
        h.route(.home, false)
        h.clock.advance(5)
        XCTAssertEqual(h.events.count, count)
        XCTAssertTrue(h.ordinaryActions.isEmpty)
        XCTAssertEqual(h.events.last?.flags, [])
    }

    func testNavigationAndResetDoNotLeaveCommandHeldOrOldTimersRunning() {
        let h = Harness()
        h.tap(.home)
        h.tap(.dpadLeft)
        XCTAssertTrue(h.tabDowns.last?.flags.contains([.maskCommand, .maskShift]) == true)
        h.tap(.dpadRight)
        XCTAssertFalse(h.tabDowns.last!.flags.contains(.maskShift))
        h.switcher.reset()
        let count = h.events.count
        h.switcher.reset()
        h.clock.advance(5)
        XCTAssertEqual(h.events.count, count)
        XCTAssertEqual(h.events.last?.flags, [])
        h.tap(.home)
        h.clock.advance(2)
        XCTAssertFalse(h.switcher.isPresented)
        XCTAssertEqual(h.events.last?.flags, [])
    }

    func testLostTriggerCancelsSessionAndReleasesCommand() {
        let h = Harness()
        h.route(.home, true)
        h.switcher.cancel(.home)
        XCTAssertFalse(h.switcher.isPresented)
        let count = h.events.count
        h.clock.advance(5)
        XCTAssertEqual(h.events.count, count)
        XCTAssertEqual(h.events.last?.flags, [])
    }

    func testDelayedOpeningKeepsItsOriginalInputAndReleasesPreviouslyHeldMappings() {
        let h = Harness()
        h.mapping[.home, .double] = ButtonMapping(action: .copy)
        h.tap(.home)
        h.route(.dpadDown, true)
        h.clock.advance(0.3)
        XCTAssertTrue(h.switcher.isPresented)
        XCTAssertEqual(h.events.prefix(2).map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(h.events.prefix(2).map { $0.getIntegerValueField(.keyboardEventKeycode) }, [0x7D, 0x7D])
        h.tap(.home)
        XCTAssertEqual(h.tabDowns.count, 2)
        let count = h.events.count
        h.route(.dpadDown, false)
        XCTAssertEqual(h.events.count, count)
        XCTAssertEqual(h.ordinaryActions, [.arrowDown])
        h.clock.advance(2)
        XCTAssertFalse(h.switcher.isPresented)
    }

    func testConfirmationReleasesOnlyTheSwitchersOwnershipOfCommand() {
        let h = Harness()
        let command = ButtonMapping(action: .leftCommand)
        h.sender.send(command, pressed: true)
        h.tap(.home)
        h.clock.advance(2)
        XCTAssertFalse(h.switcher.isPresented)
        XCTAssertTrue(h.events.last!.flags.contains(.maskCommand))
        h.sender.send(command, pressed: false)
        XCTAssertEqual(h.events.last?.type, .flagsChanged)
        XCTAssertEqual(h.events.last?.flags, [])
    }

    func testActionSurvivesBackupAndCannotStartAnInteractiveSessionFromAMacro() throws {
        var mapping = RemoteMapping.defaults
        mapping[.home, .double] = ButtonMapping(action: .switchApplications)
        let backup = SettingsBackup(mapping: mapping, profiles: [], macros: [], phrases: [])
        let restored = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(backup))
        XCTAssertEqual(restored.mapping[.home, .double].action, .switchApplications)
        let macro = SavedMacro(name: "切换应用", steps: [MacroStep(mapping: ButtonMapping(action: .switchApplications))])
        XCTAssertThrowsError(try MacroExecutionPlan(macro, macros: [macro])) {
            XCTAssertEqual($0 as? MacroExecutionError, .unsupportedAction)
        }
    }
}
