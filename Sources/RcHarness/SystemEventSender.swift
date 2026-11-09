import AppKit
import CoreGraphics
import Foundation

/// macOS virtual key codes (HIToolbox kVK_*) used by the built-in actions.
enum VirtualKey {
    static let returnKey: CGKeyCode = 0x24
    static let delete: CGKeyCode = 0x33
    static let escape: CGKeyCode = 0x35
    static let upArrow: CGKeyCode = 0x7E
    static let downArrow: CGKeyCode = 0x7D
    static let leftArrow: CGKeyCode = 0x7B
    static let rightArrow: CGKeyCode = 0x7C
    static let rightCommand: CGKeyCode = 0x36
    static let command: CGKeyCode = 0x37
    static let function: CGKeyCode = 0x3F
    static let option: CGKeyCode = 0x3A
    static let rightOption: CGKeyCode = 0x3D
    static let c: CGKeyCode = 0x08
    static let v: CGKeyCode = 0x09
    static let four: CGKeyCode = 0x15
    static let leftBracket: CGKeyCode = 0x21
    static let rightBracket: CGKeyCode = 0x1E
}

/// NX_KEYTYPE_* codes for system-defined media key events.
private enum MediaKey {
    static let soundUp = 0
    static let soundDown = 1
    static let mute = 7
    static let play = 16
}

/// Device-dependent flags from IOLLEvent.h. Shortcut listeners may use these
/// bits to distinguish both the side and the down/up edge of a modifier.
private enum ModifierDeviceFlag {
    static let leftCommand = CGEventFlags(rawValue: 0x08) // NX_DEVICELCMDKEYMASK
    static let rightCommand = CGEventFlags(rawValue: 0x10) // NX_DEVICERCMDKEYMASK
    static let leftOption = CGEventFlags(rawValue: 0x20) // NX_DEVICELALTKEYMASK
    static let rightOption = CGEventFlags(rawValue: 0x40) // NX_DEVICERALTKEYMASK
}

/// Every synthesized event goes through `postEvent`, so tests can observe all
/// output without posting into the real session.
final class SystemEventSender {
    private static let modifierKeyCodes: Set<CGKeyCode> = [
        0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
    ]
    private struct HeldKey: Hashable {
        let keyCode: CGKeyCode
        let flags: UInt64
        let usesFunctionSource: Bool
    }

    // Posting at cghidEventTap does not change a nil source's state table.
    // Keep Fn in the HID table, as on the physical Fn/Globe keyboard path.
    private let functionKeySource = CGEventSource(stateID: .hidSystemState)
    private let cursorLocation: () -> CGPoint
    private let postEvent: (CGEvent) -> Void
    private let movePointer: (CGPoint) -> Void
    private let openApplication: (URL) -> Void
    private var heldKeys: [HeldKey: Int] = [:]
    private var keyUsesFunctionSource: [CGKeyCode: Bool] = [:]
    private var heldMouseButtons: [UInt32: Int] = [:]
    private var heldMediaKeys: [Int: Int] = [:]

    private var heldModifiers: CGEventFlags {
        heldKeys.keys.reduce(CGEventFlags()) { $0.union(CGEventFlags(rawValue: $1.flags)) }
    }

    init(
        cursorLocation: @escaping () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero },
        postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        movePointer: @escaping (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) },
        openApplication: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.cursorLocation = cursorLocation
        self.postEvent = postEvent
        self.movePointer = movePointer
        self.openApplication = openApplication
    }

    func send(_ mapping: ButtonMapping, pressed: Bool) {
        switch mapping.action {
        case .enter: heldKey(VirtualKey.returnKey, flags: [], pressed: pressed)
        case .backspace: heldKey(VirtualKey.delete, flags: [], pressed: pressed)
        case .escape: heldKey(VirtualKey.escape, flags: [], pressed: pressed)
        case .arrowUp: heldKey(VirtualKey.upArrow, flags: [], pressed: pressed)
        case .arrowDown: heldKey(VirtualKey.downArrow, flags: [], pressed: pressed)
        case .arrowLeft: heldKey(VirtualKey.leftArrow, flags: [], pressed: pressed)
        case .arrowRight: heldKey(VirtualKey.rightArrow, flags: [], pressed: pressed)
        case .rightCommand: heldKey(VirtualKey.rightCommand, flags: [.maskCommand, ModifierDeviceFlag.rightCommand], pressed: pressed)
        case .leftCommand: heldKey(VirtualKey.command, flags: [.maskCommand, ModifierDeviceFlag.leftCommand], pressed: pressed)
        case .fn:
            guard let functionKeySource else {
                Log.hid.error("Cannot create HID event source for Fn")
                return
            }
            heldKey(VirtualKey.function, flags: .maskSecondaryFn, pressed: pressed, source: functionKeySource)
        case .leftOption: heldKey(VirtualKey.option, flags: [.maskAlternate, ModifierDeviceFlag.leftOption], pressed: pressed)
        case .rightOption: heldKey(VirtualKey.rightOption, flags: [.maskAlternate, ModifierDeviceFlag.rightOption], pressed: pressed)
        case .copy: heldKey(VirtualKey.c, flags: .maskCommand, pressed: pressed)
        case .paste: heldKey(VirtualKey.v, flags: .maskCommand, pressed: pressed)
        case .browserBack: heldKey(VirtualKey.leftBracket, flags: .maskCommand, pressed: pressed)
        case .browserForward: heldKey(VirtualKey.rightBracket, flags: .maskCommand, pressed: pressed)
        case .screenshot:
            guard pressed else { return }
            shortcutEvent(RecordedShortcut(keyCode: VirtualKey.four,
                modifiers: CGEventFlags.maskCommand.union(.maskShift).rawValue, label: "⌘⇧4"))
        case .mouseLeft: mouse(.left, pressed: pressed)
        case .mouseRight: mouse(.right, pressed: pressed)
        case .pointerUp: move(0, -12, pressed: pressed)
        case .pointerDown: move(0, 12, pressed: pressed)
        case .pointerLeft: move(-12, 0, pressed: pressed)
        case .pointerRight: move(12, 0, pressed: pressed)
        case .scrollUp: scroll(4, pressed: pressed)
        case .scrollDown: scroll(-4, pressed: pressed)
        case .recordedShortcut:
            if pressed, let shortcut = mapping.shortcut { shortcutEvent(shortcut) }
        case .openApplication:
            if pressed, let path = mapping.applicationPath { openApplication(URL(fileURLWithPath: path)) }
        case .volumeUp: mediaKey(MediaKey.soundUp, pressed: pressed)
        case .volumeDown: mediaKey(MediaKey.soundDown, pressed: pressed)
        case .mute: mediaKey(MediaKey.mute, pressed: pressed)
        case .playPause: mediaKey(MediaKey.play, pressed: pressed)
        case .phrase, .macro, .switchToNativeMode, .openHarnessSwitcher, .disabled: break
        }
    }

    func typeText(_ text: String) {
        var chunks: [[UInt16]] = [[]]
        // Never split a UTF-16 surrogate pair across two Unicode events.
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunks[chunks.count - 1].count + units.count > 20 { chunks.append([]) }
            chunks[chunks.count - 1].append(contentsOf: units)
        }
        for chunk in chunks where !chunk.isEmpty {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                postEvent(event)
            }
        }
    }

    private func mediaKey(_ code: Int, pressed: Bool) {
        let count = heldMediaKeys[code, default: 0]
        if pressed {
            heldMediaKeys[code] = count + 1
            guard count == 0 else { return }
        } else {
            guard count > 0 else { return }
            if count == 1 { heldMediaKeys.removeValue(forKey: code) }
            else { heldMediaKeys[code] = count - 1; return }
        }
        let flags = pressed ? 0xA00 : 0xB00
        let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                                       timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | flags, data2: -1)
        if let event = event?.cgEvent { postEvent(event) }
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags = [], pressed: Bool, source: CGEventSource? = nil) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: pressed)
        event?.flags = flags.union(heldModifiers)
        if let event { postEvent(event) }
    }

    private func mouse(_ button: CGMouseButton, pressed: Bool) {
        let count = heldMouseButtons[button.rawValue, default: 0]
        if pressed {
            heldMouseButtons[button.rawValue] = count + 1
            guard count == 0 else { return }
        } else {
            guard count > 0 else { return }
            if count == 1 { heldMouseButtons.removeValue(forKey: button.rawValue) }
            else { heldMouseButtons[button.rawValue] = count - 1; return }
        }
        let type: CGEventType
        switch (button, pressed) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        default: return
        }
        if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursorLocation(), mouseButton: button) {
            event.flags = heldModifiers
            postEvent(event)
        }
    }

    private func move(_ x: CGFloat, _ y: CGFloat, pressed: Bool) {
        guard pressed else { return }
        let current = cursorLocation()
        movePointer(CGPoint(x: current.x + x, y: current.y + y))
    }

    private func scroll(_ value: Int32, pressed: Bool) {
        guard pressed, let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: value, wheel2: 0, wheel3: 0) else { return }
        postEvent(event)
    }

    private func shortcutEvent(_ shortcut: RecordedShortcut) {
        if let usesFunctionSource = keyUsesFunctionSource[shortcut.keyCode],
           !Self.modifierKeyCodes.contains(shortcut.keyCode) {
            // A one-shot action still needs a down when its key is already
            // held. Do not send an up or acquire persistent modifiers: the
            // existing owners retain the key and its original event source.
            key(shortcut.keyCode, flags: CGEventFlags(rawValue: shortcut.modifiers), pressed: true,
                source: usesFunctionSource ? functionKeySource : nil)
            return
        }
        sendShortcut(shortcut, pressed: true)
        sendShortcut(shortcut, pressed: false)
    }

    /// Voice holds need independent key edges; ordinary recorded macros still
    /// tap by calling both edges together above.
    func sendShortcut(_ shortcut: RecordedShortcut, pressed: Bool) {
        let isFunction = shortcut.keyCode == VirtualKey.function
        let usesFunction = isFunction || CGEventFlags(rawValue: shortcut.modifiers).contains(.maskSecondaryFn)
        if usesFunction {
            guard let functionKeySource else { return }
            let downFlags = isFunction ? CGEventFlags(rawValue: shortcut.modifiers).union(.maskSecondaryFn) : CGEventFlags(rawValue: shortcut.modifiers)
            heldKey(shortcut.keyCode, flags: downFlags, pressed: pressed, source: functionKeySource)
        } else {
            heldKey(shortcut.keyCode, flags: CGEventFlags(rawValue: shortcut.modifiers), pressed: pressed)
        }
    }

    private func heldKey(_ code: CGKeyCode, flags: CGEventFlags, pressed: Bool, source: CGEventSource? = nil) {
        let identity = HeldKey(keyCode: code, flags: flags.rawValue, usesFunctionSource: source != nil)
        if pressed {
            let count = heldKeys[identity, default: 0]
            let wasHeld = heldKeys.keys.contains { $0.keyCode == code }
            heldKeys[identity] = count + 1
            if wasHeld {
                // Sharing a modifier or the exact same held mapping must not
                // retrigger it. A different nonmodifier chord has its own down,
                // while all owners still share the final up.
                if count == 0, !Self.modifierKeyCodes.contains(code) {
                    key(code, flags: flags, pressed: true,
                        source: keyUsesFunctionSource[code] == true ? functionKeySource : nil)
                }
                return
            }
            keyUsesFunctionSource[code] = source != nil
            key(code, flags: flags, pressed: true, source: source)
        } else {
            guard let count = heldKeys[identity], count > 0 else { return }
            if count == 1 { heldKeys.removeValue(forKey: identity) }
            else { heldKeys[identity] = count - 1; return }
            guard !heldKeys.keys.contains(where: { $0.keyCode == code }) else { return }
            let usesFunctionSource = keyUsesFunctionSource.removeValue(forKey: code) ?? false
            key(code, flags: [], pressed: false, source: usesFunctionSource ? functionKeySource : nil)
        }
    }
}
