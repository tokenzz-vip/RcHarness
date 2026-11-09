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
    @Published private(set) var items: [HarnessSwitcherItem] = []
    @Published private(set) var selectedID: Int32?
    @Published private(set) var isPresented = false
    private var heldInputs: Set<ControllerInput> = []
    private var consumedInputs: Set<ControllerInput> = []
    var onConfirm: ((HarnessSwitcherItem) -> Void)?
    var onDismiss: (() -> Void)?

    func present(items: [HarnessSwitcherItem], frontmostProcessID: Int32?) {
        self.items = items
        selectedID = items.first(where: { $0.id == frontmostProcessID })?.id ?? items.first?.id
        consumedInputs.formUnion(heldInputs)
        isPresented = true
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
            if !pressed { consumedInputs.remove(input) }
            return true
        }
        guard isPresented else { return false }
        guard pressed else { return true }
        consumedInputs.insert(input)
        guard !wasHeld else { return true }
        switch input {
        case .dpadLeft: move(-1)
        case .dpadRight: move(1)
        case .buttonA: confirm()
        case .buttonB, .home, .menu: dismiss(reason: "remote-\(input.rawValue)")
        default: break
        }
        return true
    }
}
