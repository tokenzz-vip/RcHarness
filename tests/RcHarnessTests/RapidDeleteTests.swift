import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class RapidDeleteTests: XCTestCase {
    @MainActor
    private final class Harness {
        let clock = TestClock()
        let engine: RemoteGestureController
        var mapping = RemoteMapping.defaults
        var events: [CGEvent] = []
        var actions: [RemoteAction] = []
        lazy var sender = SystemEventSender(postEvent: { [weak self] in self?.events.append($0) })

        init() {
            engine = RemoteGestureController(schedule: clock.schedule)
            mapping[.buttonB] = ButtonMapping(action: .rapidDelete)
            engine.onOutput = { [weak self] mapping, pressed, _ in
                guard let self else { return }
                if pressed { self.actions.append(mapping.action) }
                self.sender.send(mapping, pressed: pressed)
            }
        }

        func press() { engine.handle(.buttonB, pressed: true, mapping: mapping) }
        func release() { engine.handle(.buttonB, pressed: false, mapping: mapping) }
    }

    func testHoldEmitsCompleteBackspaceTapsAndReleaseStopsImmediately() {
        let h = Harness()
        h.press()
        XCTAssertEqual(h.events.map(\.type), [.keyDown, .keyUp])
        h.clock.advance(0.34)
        XCTAssertEqual(h.events.count, 2)
        h.clock.advance(0.14)
        XCTAssertEqual(h.events.count, 8)
        XCTAssertTrue(h.events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(VirtualKey.delete) })
        XCTAssertTrue(h.events.allSatisfy { !$0.flags.contains(.maskCommand) && !$0.flags.contains(.maskAlternate) })
        XCTAssertEqual(h.events.map(\.type), Array(repeating: [CGEventType.keyDown, .keyUp], count: 4).flatMap { $0 })
        h.release()
        h.clock.advance(2)
        XCTAssertEqual(h.events.count, 8)
    }

    func testShortPressDeletesOnceAndNextPressGetsItsOwnDelay() {
        let h = Harness()
        h.press()
        h.clock.advance(0.1)
        h.release()
        h.press()
        h.clock.advance(0.3)
        XCTAssertEqual(h.events.count, 4)
        h.clock.advance(0.06)
        XCTAssertEqual(h.events.count, 6)
        h.release()
        h.clock.advance(1)
        XCTAssertEqual(h.events.count, 6)
    }

    func testLongBindingRepeatsWhileHeldWithoutFiringSingleOnRelease() {
        let h = Harness()
        h.mapping[.buttonB] = ButtonMapping(action: .backspace)
        h.mapping[.buttonB, .long] = ButtonMapping(action: .rapidDelete)
        h.press()
        h.clock.advance(0.54)
        XCTAssertTrue(h.events.isEmpty)
        h.clock.advance(0.14)
        XCTAssertEqual(h.actions, [.rapidDelete, .rapidDelete, .rapidDelete])
        h.release()
        h.clock.advance(1)
        XCTAssertEqual(h.events.count, 6)

        h.press()
        h.release()
        XCTAssertEqual(h.actions.last, .backspace)
        XCTAssertEqual(h.events.count, 8)
    }

    func testCancellationAndModeChangeStopBothImmediateAndLongRepeats() {
        for longBinding in [false, true] {
            for stop in 0..<3 {
                let h = Harness()
                if longBinding {
                    h.mapping[.buttonB] = ButtonMapping(action: .backspace)
                    h.mapping[.buttonB, .long] = ButtonMapping(action: .rapidDelete)
                }
                h.press()
                h.clock.advance(0.8)
                let count = h.events.count
                XCTAssertGreaterThan(count, 2)
                switch stop {
                case 0: h.engine.cancel()
                case 1: h.engine.cancel(.buttonB)
                default: h.engine.setOperationMode(.native)
                }
                h.clock.advance(2)
                h.release()
                XCTAssertEqual(h.events.count, count)
                XCTAssertEqual(h.events.last?.type, .keyUp)
            }
        }
    }

    func testCancellationBeforeRepeatDelayDoesNotDeleteLater() {
        let h = Harness()
        h.press()
        h.engine.cancel()
        h.clock.advance(2)
        XCTAssertEqual(h.events.count, 2)
    }

    func testCancellingOneInputLeavesAnotherInputsRepeatRunning() {
        let h = Harness()
        h.mapping[.buttonA] = ButtonMapping(action: .rapidDelete)
        h.press()
        h.engine.handle(.buttonA, pressed: true, mapping: h.mapping)
        XCTAssertEqual(h.events.count, 4)
        h.clock.advance(0.34)
        h.engine.cancel(.buttonB)
        h.clock.advance(0.14)
        XCTAssertEqual(h.events.count, 10, "Only the other input emits three repeat taps")
        h.engine.handle(.buttonA, pressed: false, mapping: h.mapping)
        h.release()
        h.clock.advance(1)
        XCTAssertEqual(h.events.count, 10)
        XCTAssertEqual(h.events.last?.type, .keyUp)
    }

    func testCancelledRepeatAndLongPressCallbacksCannotAffectANewGesture() {
        for longBinding in [false, true] {
            var callbacks: [() -> Void] = []
            let engine = RemoteGestureController(schedule: { _, callback in
                callbacks.append(callback)
                return DispatchWorkItem(block: callback)
            })
            var mapping = RemoteMapping.defaults
            mapping[.buttonB] = ButtonMapping(action: longBinding ? .backspace : .rapidDelete)
            if longBinding { mapping[.buttonB, .long] = ButtonMapping(action: .rapidDelete) }
            var edges: [(RemoteAction, Bool)] = []
            engine.onOutput = { value, pressed, _ in edges.append((value.action, pressed)) }
            engine.handle(.buttonB, pressed: true, mapping: mapping)
            let obsolete = callbacks
            XCTAssertFalse(obsolete.isEmpty)
            engine.cancel(.buttonB)
            mapping[.buttonB] = ButtonMapping(action: .enter)
            mapping[.buttonB, .long] = ButtonMapping(action: .disabled)
            engine.handle(.buttonB, pressed: true, mapping: mapping)
            let count = edges.count
            obsolete.forEach { $0() } // Deliberately invoke even cancelled work.
            XCTAssertEqual(edges.count, count)
            engine.handle(.buttonB, pressed: false, mapping: mapping)
            XCTAssertEqual(edges.suffix(2).map { $0.0 }, [.enter, .enter])
            XCTAssertEqual(edges.suffix(2).map { $0.1 }, [true, false])
        }
    }

    func testEditingMappingAndRepeatedHIDDownDoNotChangeActiveRepeat() {
        let h = Harness()
        h.press()
        h.mapping[.buttonB] = ButtonMapping(action: .enter)
        h.press()
        h.clock.advance(0.48)
        h.release()
        h.clock.advance(1)
        XCTAssertEqual(h.actions, Array(repeating: .rapidDelete, count: 4))
        h.press()
        h.release()
        XCTAssertEqual(h.actions.last, .enter)
    }

    func testSingleRapidDeleteCanRepeatAlongsideConfiguredDoubleClick() {
        let h = Harness()
        h.mapping[.buttonB, .double] = ButtonMapping(action: .copy)
        h.press()
        h.clock.advance(0.68)
        XCTAssertEqual(h.actions, [.rapidDelete, .rapidDelete, .rapidDelete])
        h.release()
        h.clock.advance(1)
        XCTAssertEqual(h.actions.count, 3)
        h.press()
        h.release()
        h.press()
        h.release()
        h.clock.advance(1)
        XCTAssertEqual(h.actions.last, .copy)
        XCTAssertEqual(h.actions.count, 4)
    }

    func testExplicitLongActionOverridesSingleRapidDelete() {
        let h = Harness()
        h.mapping[.buttonB, .long] = ButtonMapping(action: .copy)
        h.press()
        h.clock.advance(2)
        h.release()
        XCTAssertEqual(h.actions, [.copy])
    }

    func testDoubleRapidDeleteOnlyDeletesOnce() {
        let h = Harness()
        h.mapping[.buttonB] = ButtonMapping(action: .enter)
        h.mapping[.buttonB, .double] = ButtonMapping(action: .rapidDelete)
        h.press()
        h.release()
        h.press()
        h.release()
        h.clock.advance(2)
        XCTAssertEqual(h.actions, [.rapidDelete])
        XCTAssertEqual(h.events.map(\.type), [.keyDown, .keyUp])
    }

    func testOrdinaryBackspaceKeepsOriginalHeldKeyBehavior() {
        let h = Harness()
        h.mapping[.buttonB] = ButtonMapping(action: .backspace)
        h.press()
        h.clock.advance(2)
        XCTAssertEqual(h.events.map(\.type), [.keyDown])
        h.release()
        XCTAssertEqual(h.events.map(\.type), [.keyDown, .keyUp])
    }

    func testBackupPreservesRapidDeleteMappingAndMacroStep() throws {
        let h = Harness()
        let macro = SavedMacro(name: "删除", steps: [MacroStep(mapping: ButtonMapping(action: .rapidDelete), delay: 0)])
        let backup = SettingsBackup(mapping: h.mapping, profiles: [], macros: [macro], phrases: [])
        let decoded = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(backup))
        XCTAssertEqual(decoded.mapping[.buttonB].action, .rapidDelete)
        let plan = try MacroExecutionPlan(XCTUnwrap(decoded.macros.first), macros: decoded.macros)
        XCTAssertEqual(plan.events.map(\.mapping.action), [.rapidDelete])
    }
}
