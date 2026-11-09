import Foundation

extension RemoteMapping {
    static func codexDefaults(macros: [SavedMacro]) -> Self {
        var mapping = Self.defaults
        mapping[.menu] = ButtonMapping(action: .copy)
        mapping[.buttonY] = ButtonMapping(action: .paste)
        let doubleActions: [(ControllerInput, String)] = [
            (.buttonA, "Codex-新建会话"),
            (.dpadUp, "Codex-转到最近聊天1"),
            (.dpadRight, "Codex-转到最近聊天2"),
            (.dpadDown, "Codex-转到最近聊天3"),
            (.dpadLeft, "Codex-转到最近聊天4"),
            (.rightShoulder, "Codex-转到最近聊天5"),
            (.leftShoulder, "Codex-转到最近聊天6"),
        ]
        for (input, name) in doubleActions {
            let preset = DefaultMacros.codex.first { $0.name == name }
            // Prefer the stable ID (including renamed presets), then a user's
            // same-name action. Never recreate an intentionally deleted macro.
            let macro = macros.first { $0.id == preset?.id }
                ?? macros.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }
            mapping[input, .double] = macro.map { ButtonMapping(action: .macro, referenceID: $0.id.uuidString) }
                ?? ButtonMapping(action: .disabled)
        }
        return mapping
    }
}
