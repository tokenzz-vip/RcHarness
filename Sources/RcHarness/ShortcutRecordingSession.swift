import AppKit
import Carbon.HIToolbox
import CoreGraphics

@MainActor
final class ShortcutRecordingSession {
    static let modifierKeys: [(code: UInt16, flag: CGEventFlags, side: CGEventFlags, label: String)] = [
        (55, .maskCommand, .init(rawValue: 0x08), "左侧 Command"),
        (54, .maskCommand, .init(rawValue: 0x10), "右侧 Command"),
        (58, .maskAlternate, .init(rawValue: 0x20), "左侧 Option"),
        (61, .maskAlternate, .init(rawValue: 0x40), "右侧 Option"),
        (56, .maskShift, .init(rawValue: 0x02), "左侧 Shift"),
        (60, .maskShift, .init(rawValue: 0x04), "右侧 Shift"),
        (59, .maskControl, .init(rawValue: 0x01), "左侧 Control"),
        (62, .maskControl, .init(rawValue: 0x2000), "右侧 Control"),
        (VirtualKey.function, .maskSecondaryFn, [], "Fn / 地球键")
    ]
    static let modifiers: CGEventFlags = [.maskSecondaryFn, .maskControl, .maskAlternate, .maskShift, .maskCommand]

    static func singleModifierShortcut(keyCode: UInt16?) -> RecordedShortcut? {
        guard let key = modifierKeys.first(where: { $0.code == keyCode }) else { return nil }
        return RecordedShortcut(keyCode: key.code, modifiers: key.flag.rawValue, label: key.label)
    }

    var onCapture: ((RecordedShortcut) -> Void)?
    var onProgress: ((Progress) -> Void)?
    private(set) var isRecording = false
    private var pendingModifier: RecordedShortcut?
    private var pendingShortcut: RecordedShortcut?
    private var heldKeys: Set<UInt16> = []
    private var heldModifiers: Set<UInt16> = []
    private var functionHeld = false

    enum Progress: Equatable {
        case waiting, waitingForRelease(String), tooManyKeys
    }

    private var progress: Progress = .waiting {
        didSet { if oldValue != progress { onProgress?(progress) } }
    }

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
        progress = .waiting
    }

    /// Receives only events delivered to the focused AppKit recording field.
    @discardableResult
    func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        guard isRecording else { return false }
        guard type == .flagsChanged || type == .keyDown || type == .keyUp else { return false }
        if event.getIntegerValueField(.eventSourceUserData) == SystemEventSender.keyboardEventMarker { return true }
        guard let code = UInt16(exactly: event.getIntegerValueField(.keyboardEventKeycode)) else { return true }
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
            if code == UInt16(kVK_CapsLock) {
                pendingModifier = nil
                if pendingShortcut?.keyCode == code || progress == .tooManyKeys { break }
                if heldKeys.isEmpty, pendingShortcut == nil {
                    pendingShortcut = StandardShortcutKeyboard.shortcut(keyCode: code, flags: flags)
                } else {
                    pendingShortcut = nil
                    progress = .tooManyKeys
                }
                break
            }
            // Clear the whole family when its shared flag goes up, even if
            // the keyboard omitted per-side bits or a release was intercepted.
            for key in Self.modifierKeys where !flags.contains(key.flag) { heldModifiers.remove(key.code) }
            if let key = Self.modifierKeys.first(where: { $0.code == code }) {
                let family = Self.modifierKeys.filter { $0.flag == key.flag }
                let sideMask = family.reduce(CGEventFlags()) { $0.union($1.side) }
                let hasSideFlags = !event.flags.intersection(sideMask).isEmpty
                let pressed = flags.contains(key.flag)
                    && (hasSideFlags ? event.flags.contains(key.side) : !heldModifiers.contains(code))
                if hasSideFlags {
                    for side in family {
                        if event.flags.contains(side.side) { heldModifiers.insert(side.code) }
                        else { heldModifiers.remove(side.code) }
                    }
                } else if pressed {
                    heldModifiers.insert(code)
                } else {
                    heldModifiers.remove(code)
                }
                if pendingShortcut == nil, heldKeys.isEmpty, progress != .tooManyKeys {
                    if pressed {
                        pendingModifier = heldModifiers.count == 1 && flags.rawValue.nonzeroBitCount == 1
                            ? Self.singleModifierShortcut(keyCode: code) : nil
                    } else if flags.isEmpty, pendingModifier?.keyCode == code {
                        pendingShortcut = pendingModifier
                        pendingModifier = nil
                    }
                }
            }
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
            heldKeys.insert(code)
            pendingModifier = nil
            if heldKeys.count > 1 || pendingShortcut.map({ $0.keyCode != code }) == true {
                self.pendingShortcut = nil
                progress = .tooManyKeys
            } else if pendingShortcut == nil, progress != .tooManyKeys {
                pendingShortcut = Self.shortcut(for: event, keyCode: code, flags: flags)
            }
        case .keyUp:
            heldKeys.remove(code)
        default: break
        }
        // Consume both edges, including releases of modifiers in a combination.
        if let shortcut = pendingShortcut, heldKeys.isEmpty, flags.isEmpty {
            stop()
            onCapture?(shortcut)
        } else if let candidate = pendingShortcut ?? pendingModifier {
            progress = .waitingForRelease(candidate.label)
        } else if heldKeys.isEmpty && (flags.isEmpty || progress != .tooManyKeys) {
            progress = .waiting
        }
        return true
    }

    private static func shortcut(for event: CGEvent, keyCode: UInt16, flags: CGEventFlags) -> RecordedShortcut {
        if !event.flags.contains(.maskNumericPad),
           let characters = NSEvent(cgEvent: event)?.characters(
               byApplyingModifiers: flags.contains(.maskCommand) ? .command : []),
           !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({
               !CharacterSet.controlCharacters.contains($0)
                   && !CharacterSet.whitespacesAndNewlines.contains($0)
                   && $0.properties.generalCategory != .privateUse
           }) {
            return RecordedShortcut(keyCode: keyCode, flags: flags, keyLabel: characters.uppercased())
        }
        return StandardShortcutKeyboard.shortcut(keyCode: keyCode, flags: flags)
            ?? RecordedShortcut(keyCode: keyCode, flags: flags, keyLabel: "Key \(keyCode)")
    }
}

extension RecordedShortcut {
    init(keyCode: UInt16, flags: CGEventFlags, keyLabel: String) {
        var label = ""
        if flags.contains(.maskControl) { label += "⌃" }
        if flags.contains(.maskAlternate) { label += "⌥" }
        if flags.contains(.maskShift) { label += "⇧" }
        if flags.contains(.maskCommand) { label += "⌘" }
        if flags.contains(.maskSecondaryFn) { label += "Fn + " }
        self.init(keyCode: keyCode, modifiers: flags.rawValue, label: label + keyLabel)
    }
}
