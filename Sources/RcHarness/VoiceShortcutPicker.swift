import AppKit
import SwiftUI

/// Choose the opening direction and content size before presenting, so a
/// low anchor never opens an oversized menu and then jumps to another edge.
struct VoiceShortcutPopoverLayout {
    static let width: CGFloat = 360
    static let height: CGFloat = 344
    let preferredEdge: NSRectEdge
    let contentHeight: CGFloat

    init(anchor: CGRect, visibleFrame: CGRect) {
        let clearance: CGFloat = 20 // Arrow and space from the screen edge.
        let below = max(0, anchor.minY - visibleFrame.minY - clearance)
        let above = max(0, visibleFrame.maxY - anchor.maxY - clearance)
        let opensBelow = below >= Self.height || below >= above
        preferredEdge = opensBelow ? .minY : .maxY
        contentHeight = min(Self.height, opensBelow ? below : above)
    }
}

@MainActor
struct VoiceShortcutPicker: View {
    let mode: VoiceTriggerMode
    @Binding var shortcut: RecordedShortcut
    @State private var isPresented = false
    @State private var hovering = false

    private var choice: VoiceShortcutChoice {
        VoiceShortcutChoice.matching(shortcut, mode: mode) ?? VoiceShortcutChoice.singles[0]
    }

    var body: some View {
        HStack(spacing: SettingsStyle.Spacing.controls) {
            Text("快捷键").font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Array(choice.keys.enumerated()), id: \.element.id) { index, key in
                    if index > 0 { Text("+").foregroundStyle(.tertiary) }
                    Text(key.pickerLabel)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isPresented ? 180 : 0))
                    .animation(.easeOut(duration: 0.16), value: isPresented)
            }
            .padding(.horizontal, SettingsStyle.controlPadding)
            .frame(height: 36)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsStyle.controlRadius)
                    .strokeBorder(isPresented ? Color.accentColor : Color.primary.opacity(hovering ? 0.22 : 0.12))
            }
            .onHover { hovering = $0 }
            .overlay { VoiceShortcutPopoverAnchor(mode: mode, shortcut: $shortcut, isPresented: $isPresented) }
        }
    }
}

@MainActor
private struct VoiceShortcutPopoverAnchor: NSViewRepresentable {
    let mode: VoiceTriggerMode
    @Binding var shortcut: RecordedShortcut
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator(configuration: self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.isBordered = false
        button.isTransparent = true
        button.setAccessibilityRole(.popUpButton)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.configuration = self
        button.setAccessibilityLabel("\(mode == .hold ? "长按" : "点按")快捷键，当前：\(shortcut.label)")
        button.setAccessibilityHelp("打开按键选择面板")
    }

    static func dismantleNSView(_ view: NSButton, coordinator: Coordinator) {
        coordinator.popover.delegate = nil
        coordinator.popover.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var configuration: VoiceShortcutPopoverAnchor
        let popover = NSPopover()
        private weak var anchor: NSButton?

        init(configuration: VoiceShortcutPopoverAnchor) {
            self.configuration = configuration
            super.init()
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
        }

        @objc func toggle(_ sender: NSButton) {
            if popover.isShown { popover.performClose(nil); return }
            guard let window = sender.window, let screen = window.screen else { return }
            anchor = sender
            let rect = window.convertToScreen(sender.convert(sender.bounds, to: nil))
            let layout = VoiceShortcutPopoverLayout(anchor: rect, visibleFrame: screen.visibleFrame)
            guard layout.contentHeight > 0 else { return }
            let content = VoiceShortcutSelectionPanel(mode: configuration.mode, shortcut: configuration.shortcut,
                height: layout.contentHeight, onCancel: { [weak self] in self?.popover.performClose(nil) },
                onConfirm: { [weak self] choice in
                    guard let self else { return }
                    self.configuration.shortcut = choice.shortcut
                    self.popover.performClose(nil)
                })
            let controller = NSHostingController(rootView: content)
            controller.view.appearance = sender.effectiveAppearance
            popover.contentViewController = controller
            popover.contentSize = NSSize(width: VoiceShortcutPopoverLayout.width, height: layout.contentHeight)
            configuration.isPresented = true
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: layout.preferredEdge)
        }

        func popoverDidClose(_ notification: Notification) {
            configuration.isPresented = false
            if let anchor, anchor.window?.isKeyWindow == true { anchor.window?.makeFirstResponder(anchor) }
        }
    }
}

@MainActor
struct VoiceShortcutSelectionPanel: View {
    let mode: VoiceTriggerMode
    let height: CGFloat
    let onCancel: () -> Void
    let onConfirm: (VoiceShortcutChoice) -> Void
    @State private var selected: Set<VoiceShortcutKey>

    init(mode: VoiceTriggerMode, shortcut: RecordedShortcut, height: CGFloat = VoiceShortcutPopoverLayout.height,
         onCancel: @escaping () -> Void, onConfirm: @escaping (VoiceShortcutChoice) -> Void) {
        self.mode = mode
        self.height = height
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selected = State(initialValue: Set(VoiceShortcutChoice.matching(shortcut, mode: mode)?.keys ?? [.function]))
    }

    private var choice: VoiceShortcutChoice? {
        VoiceShortcutChoice.options(for: mode).first { Set($0.keys) == selected }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode == .hold ? "长按快捷键" : "点按快捷键")
                    .font(SettingsStyle.Typography.dialogTitle)
                Text(selectionHint)
                    .font(SettingsStyle.Typography.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            Divider()
            ScrollView {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { keyButton(.function).gridCellColumns(2) }
                    GridRow { keyButton(.leftCommand); keyButton(.rightCommand) }
                    GridRow { keyButton(.leftOption); keyButton(.rightOption) }
                    GridRow { keyButton(.leftControl); keyButton(.rightControl) }
                }
                .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: SettingsStyle.Spacing.inline) {
                Text("已选 \(selected.count) / \(mode == .hold ? 1 : 2)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("使用快捷键") { if let choice { onConfirm(choice) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(choice == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: VoiceShortcutPopoverLayout.width, height: height)
    }

    private var selectionHint: String {
        if mode == .hold { return "选择一个按键，点击其他按键即可更换" }
        return selected.count == 2 ? "已选满两个按键，先取消一个即可更换" : "选择一个或两个按键，再次点击可取消"
    }

    private func keyButton(_ key: VoiceShortcutKey) -> some View {
        VoiceShortcutKeyButton(key: key, selected: selected.contains(key)) {
            if mode == .hold { selected = [key] }
            else if selected.contains(key) { selected.remove(key) }
            else { selected.insert(key) }
        }
        .disabled(mode == .tap && selected.count == 2 && !selected.contains(key))
    }
}

@MainActor
private struct VoiceShortcutKeyButton: View {
    let key: VoiceShortcutKey
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(key.glyph)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
                Text(key == .function ? "地球键" : key.label.replacingOccurrences(of: "侧", with: ""))
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor).opacity(selected ? 1 : 0)
                    .frame(width: 12)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(selected ? Color.accentColor.opacity(0.11) : Color.primary.opacity(hovering ? 0.065 : 0.028),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(key.label)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .help(isEnabled ? key.label : "最多选择两个按键，先取消一个已选按键即可更换")
    }
}

private extension VoiceShortcutKey {
    var glyph: String {
        switch self {
        case .function: "fn"
        case .leftCommand, .rightCommand: "⌘"
        case .leftOption, .rightOption: "⌥"
        case .leftControl, .rightControl: "⌃"
        }
    }
    var pickerLabel: String {
        switch self {
        case .function: "Fn / 地球键"
        default: label.replacingOccurrences(of: "Command", with: "⌘")
            .replacingOccurrences(of: "Option", with: "⌥").replacingOccurrences(of: "Control", with: "⌃")
        }
    }
}
