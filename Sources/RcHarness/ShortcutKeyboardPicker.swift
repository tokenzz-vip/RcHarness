import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

/// Physical Mac ANSI positions. Printable keycaps follow the current keyboard layout.
enum StandardShortcutKeyboard {
    struct Key: Identifiable {
        let id: UInt16
        let title: String
        let width: CGFloat
        let name: String

        init(_ code: Int, _ title: String, width: CGFloat = 32, name: String? = nil) {
            id = UInt16(code)
            self.title = title
            self.width = width
            self.name = name ?? title
        }
    }

    static let main: [[Key]] = [
        [.init(kVK_Escape, "Esc", width: 44, name: "Escape"),
         .init(kVK_F1, "F1"), .init(kVK_F2, "F2"), .init(kVK_F3, "F3"), .init(kVK_F4, "F4"),
         .init(kVK_F5, "F5"), .init(kVK_F6, "F6"), .init(kVK_F7, "F7"), .init(kVK_F8, "F8"),
         .init(kVK_F9, "F9"), .init(kVK_F10, "F10"), .init(kVK_F11, "F11"), .init(kVK_F12, "F12")],
        [.init(kVK_ANSI_Grave, "`"), .init(kVK_ANSI_1, "1"), .init(kVK_ANSI_2, "2"),
         .init(kVK_ANSI_3, "3"), .init(kVK_ANSI_4, "4"), .init(kVK_ANSI_5, "5"), .init(kVK_ANSI_6, "6"),
         .init(kVK_ANSI_7, "7"), .init(kVK_ANSI_8, "8"), .init(kVK_ANSI_9, "9"), .init(kVK_ANSI_0, "0"),
         .init(kVK_ANSI_Minus, "-"), .init(kVK_ANSI_Equal, "="),
         .init(kVK_Delete, "⌫", width: 54, name: "Delete")],
        [.init(kVK_Tab, "Tab", width: 53), .init(kVK_ANSI_Q, "Q"), .init(kVK_ANSI_W, "W"),
         .init(kVK_ANSI_E, "E"), .init(kVK_ANSI_R, "R"), .init(kVK_ANSI_T, "T"), .init(kVK_ANSI_Y, "Y"),
         .init(kVK_ANSI_U, "U"), .init(kVK_ANSI_I, "I"), .init(kVK_ANSI_O, "O"), .init(kVK_ANSI_P, "P"),
         .init(kVK_ANSI_LeftBracket, "["), .init(kVK_ANSI_RightBracket, "]"), .init(kVK_ANSI_Backslash, "\\")],
        [.init(kVK_CapsLock, "Caps Lock", width: 60), .init(kVK_ANSI_A, "A"), .init(kVK_ANSI_S, "S"),
         .init(kVK_ANSI_D, "D"), .init(kVK_ANSI_F, "F"), .init(kVK_ANSI_G, "G"), .init(kVK_ANSI_H, "H"),
         .init(kVK_ANSI_J, "J"), .init(kVK_ANSI_K, "K"), .init(kVK_ANSI_L, "L"), .init(kVK_ANSI_Semicolon, ";"),
         .init(kVK_ANSI_Quote, "'"), .init(kVK_Return, "Return", width: 62)],
        [.init(kVK_ANSI_Z, "Z"), .init(kVK_ANSI_X, "X"), .init(kVK_ANSI_C, "C"),
         .init(kVK_ANSI_V, "V"), .init(kVK_ANSI_B, "B"), .init(kVK_ANSI_N, "N"), .init(kVK_ANSI_M, "M"),
         .init(kVK_ANSI_Comma, ","), .init(kVK_ANSI_Period, "."), .init(kVK_ANSI_Slash, "/"),
         .init(kVK_Space, "Space", width: 162)]
    ]

    static let navigation: [[Key]] = [
        [.init(kVK_Help, "Help", width: 42), .init(kVK_Home, "Home", width: 46),
         .init(kVK_PageUp, "Page Up", width: 53), .init(kVK_ForwardDelete, "⌦", name: "Forward Delete"),
         .init(kVK_End, "End", width: 36), .init(kVK_PageDown, "Page Down", width: 65)],
        [.init(kVK_LeftArrow, "←", name: "左方向键"), .init(kVK_UpArrow, "↑", name: "上方向键"),
         .init(kVK_DownArrow, "↓", name: "下方向键"), .init(kVK_RightArrow, "→", name: "右方向键")]
    ]

    static let extended: [[Key]] = [
        [.init(kVK_F13, "F13"), .init(kVK_F14, "F14"), .init(kVK_F15, "F15"), .init(kVK_F16, "F16"),
         .init(kVK_F17, "F17"), .init(kVK_F18, "F18"), .init(kVK_F19, "F19"), .init(kVK_F20, "F20")]
    ]

    static let keypad: [[Key]] = [
        [.init(kVK_ANSI_KeypadClear, "Clear"), .init(kVK_ANSI_KeypadEquals, "="),
         .init(kVK_ANSI_KeypadDivide, "/"), .init(kVK_ANSI_KeypadMultiply, "×")],
        [.init(kVK_ANSI_Keypad7, "7"), .init(kVK_ANSI_Keypad8, "8"),
         .init(kVK_ANSI_Keypad9, "9"), .init(kVK_ANSI_KeypadMinus, "-")],
        [.init(kVK_ANSI_Keypad4, "4"), .init(kVK_ANSI_Keypad5, "5"),
         .init(kVK_ANSI_Keypad6, "6"), .init(kVK_ANSI_KeypadPlus, "+")],
        [.init(kVK_ANSI_Keypad1, "1"), .init(kVK_ANSI_Keypad2, "2"),
         .init(kVK_ANSI_Keypad3, "3"), .init(kVK_ANSI_KeypadEnter, "Enter")],
        [.init(kVK_ANSI_Keypad0, "0", width: 68), .init(kVK_ANSI_KeypadDecimal, ".")]
    ]

    static let modifiers: [(title: String, name: String, flags: CGEventFlags)] = [
        ("⌃ Control", "Control", .maskControl),
        ("⌥ Option", "Option", .maskAlternate),
        ("⇧ Shift", "Shift", .maskShift),
        ("⌘ Command", "Command", .maskCommand),
        ("Fn", "Fn / 地球键", .maskSecondaryFn)
    ]

    static func shortcut(keyCode: UInt16, flags: CGEventFlags, keyLabels: [UInt16: String] = [:]) -> RecordedShortcut? {
        if let key = (main + navigation + extended).lazy.flatMap({ $0 }).first(where: { $0.id == keyCode }) {
            return RecordedShortcut(keyCode: keyCode, flags: flags, keyLabel: keyLabels[keyCode] ?? key.title)
        }
        if let key = keypad.lazy.flatMap({ $0 }).first(where: { $0.id == keyCode }) {
            return RecordedShortcut(keyCode: keyCode, flags: flags, keyLabel: "数字键盘 " + key.title)
        }
        return nil
    }

    static func keyLabels(for source: TISInputSource, command: Bool) -> [UInt16: String] {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let bytes = CFDataGetBytePtr(Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()) else { return [:] }
        let modifiers = command ? UInt32(cmdKey >> 8) : 0
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var labels: [UInt16: String] = [:]
            for key in main.joined() where key.title.count == 1 && key.title.utf8.count == 1 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, key.id, UInt16(kUCKeyActionDisplay), modifiers, UInt32(LMGetKbdType()),
                                            UInt32(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                            characters.count, &length, &characters)
                if status == noErr, length > 0 {
                    labels[key.id] = String(decoding: characters.prefix(length), as: UTF16.self).uppercased()
                }
            }
            return labels
        }
    }
}

@MainActor
struct ShortcutKeyboardSelection {
    private var original: RecordedShortcut?
    private let baseKeyLabels: [UInt16: String]
    private let commandKeyLabels: [UInt16: String]
    private(set) var keyCode: UInt16?
    private(set) var flags: CGEventFlags
    var keyLabels: [UInt16: String] {
        flags.contains(.maskCommand) && !commandKeyLabels.isEmpty ? commandKeyLabels : baseKeyLabels
    }
    var singleModifier: RecordedShortcut? {
        ShortcutRecordingSession.singleModifierShortcut(keyCode: keyCode)
    }
    var shortcut: RecordedShortcut? {
        if let original { return original }
        guard let keyCode else { return nil }
        return singleModifier ?? StandardShortcutKeyboard.shortcut(keyCode: keyCode, flags: flags, keyLabels: keyLabels)
    }

    init(shortcut: RecordedShortcut?, keyLabels: [UInt16: String] = [:], commandKeyLabels: [UInt16: String] = [:]) {
        original = shortcut
        baseKeyLabels = keyLabels
        self.commandKeyLabels = commandKeyLabels
        keyCode = shortcut?.modifierKeyCodes == nil ? shortcut?.keyCode : nil
        let isSingleModifier = ShortcutRecordingSession.singleModifierShortcut(keyCode: keyCode) != nil
        flags = isSingleModifier || keyCode == nil ? [] : CGEventFlags(rawValue: shortcut?.modifiers ?? 0)
            .intersection(ShortcutRecordingSession.modifiers)
    }

    mutating func select(_ code: UInt16) {
        guard keyCode != code else { return }
        if ShortcutRecordingSession.singleModifierShortcut(keyCode: code) != nil { flags = [] }
        original = nil
        keyCode = code
    }

    mutating func toggle(_ modifier: CGEventFlags) {
        if singleModifier != nil { keyCode = nil }
        original = nil
        flags.formSymmetricDifference(modifier)
    }
}

@MainActor
struct ShortcutKeyboardOverlay: ViewModifier {
    @Binding var shortcut: Binding<RecordedShortcut?>?

    func body(content: Content) -> some View {
        content
            .disabled(shortcut != nil)
            .accessibilityHidden(shortcut != nil)
            .overlay {
                if let binding = shortcut {
                    GeometryReader { geometry in
                        ZStack {
                            Color.black.opacity(0.24)
                                .accessibilityHidden(true)
                            ShortcutKeyboardPicker(shortcut: binding.wrappedValue,
                                width: min(ShortcutKeyboardPicker.preferredWidth, max(1, geometry.size.width - 40)),
                                height: ShortcutKeyboardPicker.height(visibleHeight: geometry.size.height),
                                onCancel: { shortcut = nil }) { selection in
                                    binding.wrappedValue = selection
                                    shortcut = nil
                                }
                                .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.panelRadius))
                                .overlay {
                                    RoundedRectangle(cornerRadius: SettingsStyle.panelRadius)
                                        .strokeBorder(Color.primary.opacity(0.14))
                                        .allowsHitTesting(false)
                                }
                                .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
                                .onExitCommand { shortcut = nil }
                        }
                    }
                    .clipped()
                }
            }
    }
}

@MainActor
struct ShortcutKeyboardPicker: View {
    nonisolated static let preferredWidth: CGFloat = 560
    nonisolated static let preferredHeight: CGFloat = 560
    static func height(visibleHeight: CGFloat?) -> CGFloat {
        guard let visibleHeight else { return preferredHeight }
        return min(preferredHeight, max(1, visibleHeight - 40))
    }

    let width: CGFloat
    let height: CGFloat
    let onCancel: () -> Void
    let onConfirm: (RecordedShortcut) -> Void
    @State private var selection: ShortcutKeyboardSelection
    private let keyGap: CGFloat = 4
    private let sectionGap: CGFloat = 10
    private let panelInset: CGFloat = 18

    init(shortcut: RecordedShortcut?, width: CGFloat = Self.preferredWidth, height: CGFloat = Self.preferredHeight,
         onCancel: @escaping () -> Void,
         onConfirm: @escaping (RecordedShortcut) -> Void) {
        self.onCancel = onCancel
        self.width = width
        self.height = height
        self.onConfirm = onConfirm
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let baseLabels = source.map { StandardShortcutKeyboard.keyLabels(for: $0, command: false) } ?? [:]
        let commandLabels = source.map { StandardShortcutKeyboard.keyLabels(for: $0, command: true) } ?? [:]
        _selection = State(initialValue: ShortcutKeyboardSelection(shortcut: shortcut,
            keyLabels: baseLabels, commandKeyLabels: commandLabels))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("键盘选键").font(SettingsStyle.Typography.dialogTitle)
                Text("点选一个主键或单独修饰键。键帽随当前键盘布局显示。").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, panelInset)
            .padding(.vertical, sectionGap)

            Divider()
            ViewThatFits(in: [.horizontal, .vertical]) {
                keyboard
                    .frame(minWidth: Self.preferredWidth)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView(width < Self.preferredWidth ? [.vertical, .horizontal] : .vertical) {
                    keyboard.frame(minWidth: Self.preferredWidth)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .font(SettingsStyle.Typography.body)
        .frame(width: width, height: height)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: sectionGap) {
            VStack(alignment: .leading, spacing: keyGap) {
                sectionTitle("修饰键")
                HStack(spacing: keyGap) {
                    ForEach(StandardShortcutKeyboard.modifiers, id: \.name) { modifier in
                        keyButton(modifier.title, name: modifier.name, width: 88,
                                  selected: selection.singleModifier == nil && selection.flags.contains(modifier.flags)) {
                            selection.toggle(modifier.flags)
                        }
                    }
                }
            }
            keyboardSection("主键区", StandardShortcutKeyboard.main)
            HStack(alignment: .top, spacing: SettingsStyle.Spacing.groups) {
                VStack(alignment: .leading, spacing: sectionGap) {
                    keyboardSection("方向与导航键", StandardShortcutKeyboard.navigation)
                    keyboardSection("扩展功能键", StandardShortcutKeyboard.extended)
                }
                Spacer(minLength: 0)
                keyboardSection("数字键盘", StandardShortcutKeyboard.keypad, numberPad: true)
            }

            VStack(alignment: .leading, spacing: keyGap) {
                sectionTitle("单独修饰键（单独使用）")
                HStack(spacing: keyGap) {
                    ForEach(ShortcutRecordingSession.modifierKeys, id: \.code) { key in
                        let title = key.label.replacingOccurrences(of: "侧 ", with: " ")
                            .replacingOccurrences(of: "Command", with: "⌘")
                            .replacingOccurrences(of: "Option", with: "⌥")
                            .replacingOccurrences(of: "Shift", with: "⇧")
                            .replacingOccurrences(of: "Control", with: "⌃")
                        keyButton(key.code == VirtualKey.function ? "Fn" : title,
                                  name: key.label, width: 54, selected: selection.keyCode == key.code) {
                            selection.select(key.code)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, panelInset)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: SettingsStyle.Spacing.inline) {
            if let shortcut = selection.shortcut {
                Text(shortcut.label)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("当前选择")
                    .accessibilityValue(shortcut.label)
                    .help(shortcut.label)
            } else {
                Text("尚未选择快捷键").foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
            Button("使用快捷键") { if let shortcut = selection.shortcut { onConfirm(shortcut) } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selection.shortcut == nil)
        }
        .padding(.horizontal, panelInset)
        .padding(.vertical, 9)
    }

    private func keyboardSection(_ title: String, _ rows: [[StandardShortcutKeyboard.Key]],
                                 numberPad: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: keyGap) {
            sectionTitle(title)
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: keyGap) {
                    ForEach(rows[index]) { key in
                        let title = selection.keyLabels[key.id] ?? key.title
                        let name = selection.keyLabels[key.id] ?? key.name
                        keyButton(title, name: numberPad ? "数字键盘 " + name : name,
                                  width: key.width, selected: selection.keyCode == key.id) {
                            selection.select(key.id)
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func keyButton(_ title: String, name: String, width: CGFloat,
                           selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(selected ? .semibold : .regular)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 3)
                .frame(width: width, height: 25)
                .background(selected ? Color.accentColor.opacity(0.19) : Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.10))
                }
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(name)
    }
}
