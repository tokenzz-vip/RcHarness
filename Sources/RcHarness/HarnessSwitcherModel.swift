import Combine
import Foundation

/// A snapshot of a running process, independent of AppKit for input and catalog tests.
struct HarnessRunningApplication: Equatable {
    let processID: Int32
    var bundleIdentifier: String?
    var applicationPath: String?
    var isRegular = true
}

struct HarnessSwitcherItem: Identifiable, Equatable {
    let harnessID: String
    let name: String
    let application: HarnessRunningApplication
    var id: Int32 { application.processID }

    static func running(harnesses: [HarnessConfiguration], applications: [HarnessRunningApplication]) -> [Self] {
        var included = Set<Int32>()
        return harnesses.filter(\.isEnabled).flatMap { harness in
            applications.compactMap { application in
                guard application.isRegular,
                      harness.matches(applicationPath: application.applicationPath, bundleIdentifier: application.bundleIdentifier),
                      included.insert(application.processID).inserted else { return nil }
                return Self(harnessID: harness.id, name: harness.name, application: application)
            }
        }
    }
}

/// Owns modal input until every consumed press has received its release.
@MainActor
final class HarnessSwitcherModel: ObservableObject {
    static let confirmationDelay: TimeInterval = ApplicationSwitcherController.confirmationDelay
    static let repeatDelay: TimeInterval = ApplicationSwitcherController.repeatDelay
    static let repeatInterval: TimeInterval = ApplicationSwitcherController.repeatInterval

    private let schedule: RemoteVoiceSessionController.Scheduler
    @Published private(set) var items: [HarnessSwitcherItem] = []
    @Published private(set) var selectedID: Int32?
    @Published private(set) var isPresented = false
    private var heldInputs: Set<ControllerInput> = []
    private var consumedInputs: Set<ControllerInput> = []
    private var triggerInput: ControllerInput?
    private var confirmationWork: DispatchWorkItem?
    private var repeatWork: DispatchWorkItem?
    private var generation = 0
    var onConfirm: ((HarnessSwitcherItem) -> Void)?
    var onDismiss: (() -> Void)?

    init(schedule: @escaping RemoteVoiceSessionController.Scheduler = RemoteVoiceSessionController.mainQueue) {
        self.schedule = schedule
    }

    func present(items: [HarnessSwitcherItem], frontmostProcessID: Int32?, triggerInput: ControllerInput? = nil) {
        confirmationWork?.cancel()
        repeatWork?.cancel()
        generation += 1
        self.items = items
        selectedID = items.first(where: { $0.id == frontmostProcessID })?.id ?? items.first?.id
        self.triggerInput = triggerInput
        consumedInputs.formUnion(heldInputs)
        isPresented = true
        if let triggerInput, heldInputs.contains(triggerInput) {
            scheduleRepeat(after: Self.repeatDelay)
        } else if triggerInput != nil {
            scheduleConfirmation()
        }
        Log.switcher.notice("Presented items=\(items.count) held_inputs=\(self.heldInputs.count)")
    }

    func refresh(items: [HarnessSwitcherItem]) {
        guard isPresented else { return }
        let oldIndex = self.items.firstIndex(where: { $0.id == selectedID }) ?? 0
        self.items = items
        if !items.contains(where: { $0.id == selectedID }) {
            selectedID = items.isEmpty ? nil : items[min(oldIndex, items.count - 1)].id
        }
    }

    func move(_ offset: Int) {
        guard isPresented, !items.isEmpty else { return }
        let index = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        selectedID = items[((index + offset) % items.count + items.count) % items.count].id
    }

    func confirm(_ id: Int32? = nil) {
        guard isPresented, let item = items.first(where: { $0.id == (id ?? selectedID) }) else { return }
        dismiss(reason: "confirmed")
        onConfirm?(item)
    }

    func dismiss(reason: String = "requested") {
        guard isPresented else { return }
        confirmationWork?.cancel()
        repeatWork?.cancel()
        confirmationWork = nil
        repeatWork = nil
        generation += 1
        triggerInput = nil
        Log.switcher.notice("Dismissed reason=\(reason, privacy: .public)")
        isPresented = false
        onDismiss?()
    }

    func reset(reason: String = "reset") {
        dismiss(reason: reason)
        heldInputs.removeAll()
        consumedInputs.removeAll()
    }

    /// Call before the gesture/voice handlers, including while the switcher is hidden.
    @discardableResult
    func handle(_ input: ControllerInput, pressed: Bool) -> Bool {
        let wasHeld = heldInputs.contains(input)
        if pressed { heldInputs.insert(input) } else { heldInputs.remove(input) }
        if consumedInputs.contains(input) {
            if !pressed {
                consumedInputs.remove(input)
                if input == triggerInput { repeatWork?.cancel(); scheduleConfirmation() }
                else if isPresented { scheduleConfirmation() }
            }
            return true
        }
        guard isPresented else { return false }
        guard pressed else { return true }
        consumedInputs.insert(input)
        guard !wasHeld else { return true }
        if input == triggerInput {
            move(1)
            scheduleRepeat(after: Self.repeatDelay)
        } else {
            switch input {
            case .dpadLeft: move(-1)
            case .dpadRight: move(1)
            case .buttonA: confirm()
            case .buttonB, .home, .menu: dismiss(reason: "remote-\(input.rawValue)")
            default: break
            }
        }
        return true
    }

    private func scheduleConfirmation() {
        confirmationWork?.cancel()
        guard isPresented, triggerInput != nil else { return }
        let generation = generation
        confirmationWork = schedule(Self.confirmationDelay) { [weak self] in
            guard let self, self.isPresented, self.generation == generation else { return }
            self.confirm()
        }
    }

    private func scheduleRepeat(after delay: TimeInterval) {
        repeatWork?.cancel()
        guard isPresented, let triggerInput, heldInputs.contains(triggerInput) else { return }
        let generation = generation
        repeatWork = schedule(delay) { [weak self] in
            guard let self, self.isPresented, self.generation == generation,
                  let triggerInput = self.triggerInput, self.heldInputs.contains(triggerInput) else { return }
            self.move(1)
            self.scheduleRepeat(after: Self.repeatInterval)
        }
    }
}
