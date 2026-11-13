import CoreGraphics
import Foundation

/// Keeps Command down across remote presses while macOS owns the switcher UI.
@MainActor
final class ApplicationSwitcherController {
    static let confirmationDelay: TimeInterval = 2
    static let repeatDelay: TimeInterval = 0.35
    static let repeatInterval: TimeInterval = 0.12

    private let schedule: RemoteVoiceSessionController.Scheduler
    private let sendKey: (ButtonMapping, Bool) -> Void
    private var openingInput: ControllerInput?
    private var heldInputs: Set<ControllerInput> = []
    private var consumedInputs: Set<ControllerInput> = []
    private var idleWork: DispatchWorkItem?
    private var repeatWork: DispatchWorkItem?
    private var generation = 0
    private(set) var isPresented = false

    init(schedule: @escaping RemoteVoiceSessionController.Scheduler = RemoteVoiceSessionController.mainQueue,
         sendKey: @escaping (ButtonMapping, Bool) -> Void) {
        self.schedule = schedule
        self.sendKey = sendKey
    }

    func present(input: ControllerInput) {
        guard !isPresented else { return }
        generation += 1
        openingInput = input
        consumedInputs.formUnion(heldInputs)
        isPresented = true
        sendKey(ButtonMapping(action: .leftCommand), true)
        tab()
        if heldInputs.contains(input) { scheduleRepeat(after: Self.repeatDelay) }
        else { scheduleConfirmation() }
    }

    /// Observe every edge before gesture recognition, even while hidden.
    @discardableResult
    func handle(_ input: ControllerInput, pressed: Bool) -> Bool {
        let wasHeld = heldInputs.contains(input)
        if pressed { heldInputs.insert(input) } else { heldInputs.remove(input) }
        if consumedInputs.contains(input) {
            if !pressed {
                consumedInputs.remove(input)
                if input == openingInput { releasedTrigger() }
            }
            return true
        }
        guard isPresented else { return false }
        if !pressed {
            if input == openingInput { releasedTrigger() }
            return true
        }
        consumedInputs.insert(input)
        guard !wasHeld else { return true }
        if input == openingInput {
            idleWork?.cancel()
            tab()
            scheduleRepeat(after: Self.repeatDelay)
        } else {
            switch input {
            case .buttonA: confirm()
            case .buttonB, .home, .menu: cancel()
            case .dpadLeft:
                tab(backwards: true)
                scheduleConfirmation()
            case .dpadRight:
                tab()
                scheduleConfirmation()
            default: break
            }
        }
        return true
    }

    func confirm() { finish(cancelled: false) }
    func cancel() { finish(cancelled: true) }

    func reset() {
        cancel()
        heldInputs.removeAll()
        consumedInputs.removeAll()
    }

    func cancel(_ input: ControllerInput) {
        if input == openingInput { cancel() }
        heldInputs.remove(input)
        consumedInputs.remove(input)
    }

    private func tab(backwards: Bool = false) {
        let mapping = ButtonMapping(action: .recordedShortcut,
            shortcut: RecordedShortcut(keyCode: VirtualKey.tab,
                modifiers: backwards ? CGEventFlags.maskShift.rawValue : 0, label: "Tab"))
        sendKey(mapping, true)
        sendKey(mapping, false)
    }

    private func releasedTrigger() {
        repeatWork?.cancel()
        scheduleConfirmation()
    }

    private func scheduleConfirmation() {
        idleWork?.cancel()
        guard isPresented, let openingInput, !heldInputs.contains(openingInput) else { return }
        let generation = generation
        idleWork = schedule(Self.confirmationDelay) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.confirm()
        }
    }

    private func scheduleRepeat(after delay: TimeInterval) {
        repeatWork?.cancel()
        let generation = generation
        repeatWork = schedule(delay) { [weak self] in
            guard let self, self.isPresented, self.generation == generation,
                  let input = self.openingInput, self.heldInputs.contains(input) else { return }
            self.tab()
            self.scheduleRepeat(after: Self.repeatInterval)
        }
    }

    private func finish(cancelled: Bool) {
        guard isPresented else { return }
        isPresented = false
        openingInput = nil
        generation += 1
        idleWork?.cancel()
        repeatWork?.cancel()
        idleWork = nil
        repeatWork = nil
        if cancelled {
            sendKey(ButtonMapping(action: .escape), true)
            sendKey(ButtonMapping(action: .escape), false)
        }
        sendKey(ButtonMapping(action: .leftCommand), false)
    }
}
