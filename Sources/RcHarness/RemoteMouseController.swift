import CoreGraphics
import Foundation

@MainActor
final class RemoteMouseController {
    private let sender: SystemEventSender
    private let speed: () -> Int
    private let schedule: RemoteVoiceSessionController.Scheduler
    private var directions: Set<ControllerInput> = []
    private var clicks: [ControllerInput: RemoteAction] = [:]
    private var movement: DispatchWorkItem?
    init(sender: SystemEventSender, speed: @escaping () -> Int,
         schedule: @escaping RemoteVoiceSessionController.Scheduler = RemoteVoiceSessionController.mainQueue) {
        self.sender = sender
        self.speed = speed
        self.schedule = schedule
    }

    /// A release belongs to the action captured on press, even if the binding has since changed.
    func release(_ input: ControllerInput) -> Bool {
        if let click = clicks.removeValue(forKey: input) {
            sender.send(ButtonMapping(action: click), pressed: false)
            return true
        }
        guard directions.remove(input) != nil else { return false }
        if directions.isEmpty {
            movement?.cancel()
            movement = nil
        }
        return true
    }

    func press(_ input: ControllerInput, settings: RemoteMouseSettings, mapping: RemoteMapping) -> Bool {
        // Keep the entire gesture available when the key also controls the pointer.
        guard !ButtonTrigger.allCases.contains(where: { mapping[input, $0].action == .toggleMouseMode }) else {
            return false
        }
        if RemoteMouseSettings.directions[input] != nil {
            if directions.insert(input).inserted, movement == nil { move() }
            return true
        }
        let click: RemoteAction
        if input == settings.leftClick { click = .mouseLeft }
        else if input == settings.rightClick { click = .mouseRight }
        else { return false }
        if clicks[input] == nil {
            clicks[input] = click
            sender.send(ButtonMapping(action: click), pressed: true)
        }
        return true
    }

    func reset() {
        movement?.cancel()
        movement = nil
        directions.removeAll()
        let heldClicks = Array(clicks.values)
        clicks.removeAll()
        for click in heldClicks { sender.send(ButtonMapping(action: click), pressed: false) }
    }

    private func move() {
        guard !directions.isEmpty else { return }
        let vector = directions.compactMap { RemoteMouseSettings.directions[$0] }.reduce((x: 0, y: 0)) {
            (x: $0.x + $1.x, y: $0.y + $1.y)
        }
        let length = hypot(CGFloat(vector.x), CGFloat(vector.y))
        if length > 0 {
            let step = CGFloat(speed()) / (2 * length)
            sender.moveCursor(dx: CGFloat(vector.x) * step, dy: CGFloat(vector.y) * step)
        }
        movement = schedule(0.02) { [weak self] in self?.move() }
    }
}
