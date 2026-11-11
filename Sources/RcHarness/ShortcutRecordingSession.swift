import AppKit
import CoreGraphics

@MainActor
final class ShortcutRecordingSession {
    private static let modifierKeys: [(code: UInt16, flag: CGEventFlags, label: String)] = [
        (VirtualKey.function, .maskSecondaryFn, "Fn / 地球键"),
        (54, .maskCommand, "右侧 Command"), (55, .maskCommand, "左侧 Command"),
        (58, .maskAlternate, "左侧 Option"), (61, .maskAlternate, "右侧 Option"),
        (56, .maskShift, "左侧 Shift"), (60, .maskShift, "右侧 Shift"),
        (59, .maskControl, "左侧 Control"), (62, .maskControl, "右侧 Control")
    ]
    private static let modifiers: CGEventFlags = [.maskSecondaryFn, .maskControl, .maskAlternate, .maskShift, .maskCommand]

    var onCapture: ((RecordedShortcut) -> Void)?
    private(set) var isRecording = false
    private var pendingModifier: RecordedShortcut?
    private var pendingShortcut: RecordedShortcut?
    private var heldKeys: Set<UInt16> = []
    private var heldModifiers: Set<UInt16> = []
    private var functionHeld = false

    func start() {
        stop()
        isRecording = true
    }

    func stop() {
        isRecording = false
        pendingModifier = nil
        pendingShortcut = nil
        heldKeys.removeAll()
        heldModifiers.removeAll()
        functionHeld = false
    }

    /// Receives only events delivered to the focused AppKit recording field.
    @discardableResult
    func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        guard isRecording else { return false }
        guard type == .flagsChanged || type == .keyDown || type == .keyUp else { return false }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        var flags = event.flags.intersection(Self.modifiers)
        if type == .flagsChanged, code == VirtualKey.function {
            functionHeld = flags.contains(.maskSecondaryFn)
        }
        // AppKit also marks F/navigation keys as "function" keys. That flag
        // alone does not imply a physical Fn press requiring a later release.
        if type != .flagsChanged, !functionHeld,
           let character = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.unicodeScalars.first,
           (0xF700...0xF8FF).contains(character.value) {
            flags.remove(.maskSecondaryFn)
        }
        switch type {
        case .flagsChanged:
            if pendingShortcut == nil, let key = Self.modifierKeys.first(where: { $0.code == code }) {
                let sideKeys = VoiceShortcutKey.allCases.filter { $0.flags.contains(key.flag) }
                let sideMask = sideKeys.reduce(CGEventFlags()) { $0.union($1.flags.subtracting(Self.modifiers)) }
                let side = sideKeys.first { $0.keyCode == code }?.flags.subtracting(Self.modifiers) ?? []
                let pressed = side.isEmpty || event.flags.intersection(sideMask).isEmpty
                    ? flags.contains(key.flag) : !event.flags.intersection(side).isEmpty
                if pressed { heldModifiers.insert(code) } else { heldModifiers.remove(code) }
                if pressed {
                    pendingModifier = heldModifiers.count == 1 && flags.rawValue.nonzeroBitCount == 1
                        ? RecordedShortcut(keyCode: code, modifiers: key.flag.rawValue, label: key.label) : nil
                } else if flags.isEmpty, pendingModifier?.keyCode == code {
                    pendingShortcut = pendingModifier
                    pendingModifier = nil
                }
            }
        case .keyDown:
            heldKeys.insert(code)
            pendingModifier = nil
            if pendingShortcut == nil, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                let key = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.uppercased()
                var label = ""
                if flags.contains(.maskControl) { label += "⌃" }
                if flags.contains(.maskAlternate) { label += "⌥" }
                if flags.contains(.maskShift) { label += "⇧" }
                if flags.contains(.maskCommand) { label += "⌘" }
                if flags.contains(.maskSecondaryFn) { label += "Fn + " }
                label += code == 0x31 ? "Space" : key ?? "Key \(code)"
                pendingShortcut = RecordedShortcut(keyCode: code, modifiers: flags.rawValue, label: label)
            }
        case .keyUp:
            heldKeys.remove(code)
        default: break
        }
        // Consume both edges, including releases of modifiers in a combination.
        if let shortcut = pendingShortcut, heldKeys.isEmpty, flags.isEmpty {
            stop()
            onCapture?(shortcut)
        }
        return true
    }
}
