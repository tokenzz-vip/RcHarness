import CoreGraphics

enum VoiceShortcutKey: String, CaseIterable, Identifiable {
    case function, leftCommand, rightCommand, leftOption, rightOption, leftControl, rightControl
    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .function: VirtualKey.function
        case .leftCommand: 55
        case .rightCommand: 54
        case .leftOption: 58
        case .rightOption: 61
        case .leftControl: 59
        case .rightControl: 62
        }
    }

    var label: String {
        switch self {
        case .function: "Fn / 地球键"
        case .leftCommand: "左侧 Command"
        case .rightCommand: "右侧 Command"
        case .leftOption: "左侧 Option"
        case .rightOption: "右侧 Option"
        case .leftControl: "左侧 Control"
        case .rightControl: "右侧 Control"
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .function: .maskSecondaryFn
        case .leftCommand: [.maskCommand, CGEventFlags(rawValue: 0x08)]
        case .rightCommand: [.maskCommand, CGEventFlags(rawValue: 0x10)]
        case .leftOption: [.maskAlternate, CGEventFlags(rawValue: 0x20)]
        case .rightOption: [.maskAlternate, CGEventFlags(rawValue: 0x40)]
        case .leftControl: [.maskControl, CGEventFlags(rawValue: 0x01)]
        case .rightControl: [.maskControl, CGEventFlags(rawValue: 0x2000)]
        }
    }
}

/// Restricts voice bindings independently of ordinary recorded shortcuts.
/// A pair stores both physical keys, including two sides of the same modifier.
struct VoiceShortcutChoice: Hashable, Identifiable {
    let keys: [VoiceShortcutKey]
    var id: String { keys.map(\.rawValue).joined(separator: "+") }
    var label: String { keys.map(\.label).joined(separator: " + ") }

    private init(keys: [VoiceShortcutKey]) { self.keys = keys }

    static let singles = VoiceShortcutKey.allCases.map { Self(keys: [$0]) }
    static let pairs = VoiceShortcutKey.allCases.indices.flatMap { index in
        VoiceShortcutKey.allCases.dropFirst(index + 1).map {
            Self(keys: [VoiceShortcutKey.allCases[index], $0])
        }
    }

    static func options(for mode: VoiceTriggerMode) -> [Self] {
        mode == .hold ? singles : singles + pairs
    }

    var shortcut: RecordedShortcut {
        let flags = keys.reduce(CGEventFlags()) { $0.union($1.flags) }
        return RecordedShortcut(keyCode: keys[keys.count - 1].keyCode, modifiers: flags.rawValue,
                                label: label, modifierKeyCodes: keys.count == 2 ? keys.map(\.keyCode) : nil)
    }

    static func matching(_ shortcut: RecordedShortcut, mode: VoiceTriggerMode) -> Self? {
        if let codes = shortcut.modifierKeyCodes {
            guard codes.count == Set(codes).count else { return nil }
            return options(for: mode).first { Set($0.keys.map(\.keyCode)) == Set(codes) }
        }
        guard let single = singles.first(where: { $0.keys[0].keyCode == shortcut.keyCode }) else { return nil }
        let flags = CGEventFlags(rawValue: shortcut.modifiers)
        // Legacy single modifiers may omit their device-dependent side bits.
        let generic: CGEventFlags = [.maskSecondaryFn, .maskCommand, .maskAlternate, .maskControl]
        guard flags.intersection(generic) == single.keys[0].flags.intersection(generic),
              flags.subtracting(single.keys[0].flags).isEmpty else { return nil }
        return single
    }

    static func normalized(_ shortcut: RecordedShortcut?, mode: VoiceTriggerMode) -> RecordedShortcut {
        shortcut.flatMap { matching($0, mode: mode) }?.shortcut ?? .voiceHoldDefault
    }
}
