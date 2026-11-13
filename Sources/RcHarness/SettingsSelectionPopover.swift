import AppKit
import SwiftUI

/// Shared anchored dropdown for single and multiple selection lists.
@MainActor
struct SettingsSelectionPopover<Label: View, Content: View>: View {
    let title: String
    let accessibilityLabel: String
    let identifier: String
    var accessibilityValue: String? = nil
    var accessibilityHelp = "打开选择列表"
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: (CGFloat, @escaping () -> Void) -> Content
    @State private var isPresented = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: SettingsStyle.Spacing.inline) {
            label()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .font(SettingsStyle.Typography.body)
        .padding(.horizontal, SettingsStyle.Spacing.inline)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(isPresented || hovering ? 0.22 : 0.12))
        }
        .onHover { hovering = $0 }
        .accessibilityHidden(true)
        .overlay {
            SettingsSelectionPopoverAnchor(isPresented: $isPresented,
                    accessibilityLabel: accessibilityLabel, accessibilityValue: accessibilityValue ?? title,
                    accessibilityHelp: accessibilityHelp, identifier: identifier, content: content)
        }
    }
}

extension SettingsSelectionPopover where Label == Text {
    init(title: String, accessibilityLabel: String, identifier: String,
         accessibilityValue: String? = nil, accessibilityHelp: String = "打开选择列表",
         @ViewBuilder content: @escaping (CGFloat, @escaping () -> Void) -> Content) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.identifier = identifier
        self.accessibilityValue = accessibilityValue
        self.accessibilityHelp = accessibilityHelp
        self.label = { Text(title) }
        self.content = content
    }
}

@MainActor
private struct SettingsSelectionPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let accessibilityLabel: String
    let accessibilityValue: String
    let accessibilityHelp: String
    let identifier: String
    let content: (CGFloat, @escaping () -> Void) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(configuration: self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.isBordered = false
        button.isTransparent = true
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityRole(.popUpButton)
        button.setAccessibilityHelp(accessibilityHelp)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.configuration = self
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(accessibilityValue)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 28)
    }

    static func dismantleNSView(_ view: NSButton, coordinator: Coordinator) {
        coordinator.popover.delegate = nil
        coordinator.popover.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var configuration: SettingsSelectionPopoverAnchor<Content>
        let popover = NSPopover()
        private weak var anchor: NSButton?

        init(configuration: SettingsSelectionPopoverAnchor<Content>) {
            self.configuration = configuration
            super.init()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
        }

        @objc func toggle(_ sender: NSButton) {
            if popover.isShown { popover.performClose(nil); return }
            anchor = sender
            guard let window = sender.window, let screen = window.screen else { return }
            let anchorRect = window.convertToScreen(sender.convert(sender.bounds, to: nil))
            let availableHeight = max(28, min(320, anchorRect.minY - screen.visibleFrame.minY - 40))
            let content = configuration.content(availableHeight, { [weak self] in self?.popover.performClose(nil) })
                .frame(width: sender.bounds.width)
                .background(Color(nsColor: .windowBackgroundColor))
            let controller = NSHostingController(rootView: content)
            controller.view.appearance = sender.effectiveAppearance
            popover.contentViewController = controller
            popover.contentSize = NSSize(width: sender.bounds.width, height: controller.view.fittingSize.height)
            configuration.isPresented = true
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: sender.isFlipped ? .maxY : .minY)
        }

        func popoverDidClose(_ notification: Notification) {
            configuration.isPresented = false
            if let anchor, anchor.window?.isKeyWindow == true {
                anchor.window?.makeFirstResponder(anchor)
            }
        }
    }
}

@MainActor
struct SettingsSelectionRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 14)
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, SettingsStyle.Spacing.inline)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsSelectionRowStyle())
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "已选" : "未选")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }
}

private struct SettingsSelectionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(!isEnabled ? Color.secondary : hovering || configuration.isPressed ? Color.white : Color.primary)
                .background(isEnabled && (hovering || configuration.isPressed) ? Color.accentColor : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .onHover { hovering = $0 }
        }
    }
}
