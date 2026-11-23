import Foundation

struct RemoteMouseSettings: Codable, Equatable {
    static let speedRange = 1...40
    static let directions: [ControllerInput: (x: Int, y: Int)] = [
        .dpadUp: (0, -1), .dpadDown: (0, 1), .dpadLeft: (-1, 0), .dpadRight: (1, 0)
    ]

    var leftClick: ControllerInput? = .buttonA
    var rightClick: ControllerInput? = .buttonB
    var speed = 21

    static func buttonChoices(for profile: RemoteProfile, globals: GlobalButtonSettings) -> [ControllerInput] {
        let globalInputs = Set(globals.buttons.compactMap(\.input))
        return profile.inputs.filter { $0 != .options && directions[$0] == nil && !globalInputs.contains($0) }
    }

    func normalized(for profile: RemoteProfile, globals: GlobalButtonSettings) -> Self {
        let choices = Self.buttonChoices(for: profile, globals: globals)
        var result = self
        if let leftClick, !choices.contains(leftClick) { result.leftClick = nil }
        if let rightClick, !choices.contains(rightClick) || rightClick == result.leftClick { result.rightClick = nil }
        result.speed = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        return result
    }
}
