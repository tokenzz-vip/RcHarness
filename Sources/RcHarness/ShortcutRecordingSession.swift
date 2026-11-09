import AppKit
import Carbon
import CoreGraphics

@MainActor
protocol ShortcutEventIntercepting: AnyObject {
    var failureMessage: String? { get }
    func start(handler: @escaping (CGEventType, CGEvent) -> Bool) -> Bool
    func stop()
}

extension ShortcutEventIntercepting {
    var failureMessage: String? { nil }
}

/// Owns exactly one secure-input claim, independent of claims held by other
/// applications. Only the focused recording field may hold this claim.
@MainActor
final class ShortcutInputProtection {
    private let enable: () -> OSStatus
    private let disable: () -> OSStatus
    private(set) var isActive = false

    init(enable: @escaping () -> OSStatus = { EnableSecureEventInput() },
         disable: @escaping () -> OSStatus = { DisableSecureEventInput() }) {
        self.enable = enable
        self.disable = disable
    }

    func start() -> Bool {
        if isActive { return true }
        isActive = enable() == noErr
        return isActive
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        _ = disable()
    }

    deinit { if isActive { _ = disable() } }
}

/// Installed only while the recording field owns keyboard focus. Returning true
/// consumes an event before later taps and applications can act on it.
@MainActor
final class ShortcutEventTap: ShortcutEventIntercepting {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var localMonitor: Any?
    private let protection = ShortcutInputProtection()
    private var handler: ((CGEventType, CGEvent) -> Bool)?
    private var globalEventCount = 0
    private var localEventCount = 0
    private(set) var failureMessage: String?

    func start(handler: @escaping (CGEventType, CGEvent) -> Bool) -> Bool {
        stop()
        failureMessage = nil
        self.handler = handler
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // This tap's source is installed exclusively on the main run loop.
            return MainActor.assumeIsolated {
                let owner = Unmanaged<ShortcutEventTap>.fromOpaque(context).takeUnretainedValue()
                if type == .keyDown || type == .keyUp || type == .flagsChanged { owner.globalEventCount += 1 }
                return owner.handler?(type, event) == true ? nil : Unmanaged.passUnretained(event)
            }
        }
        // Try the earliest location first; session-level interception is a
        // fallback on systems that do not allow a HID-level tap.
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            if let created = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: callback,
                                              userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                tap = created
                break
            }
        }
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            stop()
            return false
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else { stop(); return false }
        // Other tools may recreate their taps to reclaim first position. Secure
        // input protects the focused field independently of that ordering. It
        // may affect global delivery, so keep a foreground capture route as well.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let cgEvent = event.cgEvent else { return false }
                self.localEventCount += 1
                return self.handler?(cgEvent.type, cgEvent) == true
            }
            return consumed ? nil : event
        }
        guard localMonitor != nil, protection.start() else {
            stop()
            failureMessage = "无法启用受保护的键盘录制，录制已停止。请重新开始录制。"
            return false
        }
        Log.settings.notice("Shortcut recording protected input enabled secure=\(IsSecureEventInputEnabled())")
        return true
    }

    func stop() {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        source = nil
        tap = nil
        handler = nil
        if protection.isActive {
            Log.settings.notice("Shortcut recording protected input released global_events=\(self.globalEventCount) local_events=\(self.localEventCount)")
        }
        protection.stop()
        globalEventCount = 0
        localEventCount = 0
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}

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
    var onFailure: ((String) -> Void)?
    private(set) var isRecording = false
    private let interceptor: ShortcutEventIntercepting
    private var pendingModifier: RecordedShortcut?
    private var pendingShortcut: RecordedShortcut?
    private var heldKeys: Set<UInt16> = []
    private var functionHeld = false

    init(interceptor: ShortcutEventIntercepting? = nil) {
        self.interceptor = interceptor ?? ShortcutEventTap()
    }

    func start() {
        stop()
        isRecording = true
        guard interceptor.start(handler: { [weak self] type, event in self?.handle(type, event: event) ?? false }) else {
            fail(interceptor.failureMessage ?? "无法拦截键盘事件。请检查 RcHarness 的辅助功能和输入监控权限后重试。")
            return
        }
    }

    func stop() {
        isRecording = false
        interceptor.stop()
        pendingModifier = nil
        pendingShortcut = nil
        heldKeys.removeAll()
        functionHeld = false
    }

    private func fail(_ message: String) {
        stop()
        Log.settings.error("Shortcut recording stopped: \(message, privacy: .public)")
        onFailure?(message)
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        guard isRecording else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            fail("键盘拦截已被系统停用，录制已停止。请重新开始录制。")
            return false
        }
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
                if flags.contains(key.flag) {
                    pendingModifier = flags.rawValue.nonzeroBitCount == 1
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
