import AppKit
import SwiftUI

@MainActor
final class ShortcutOverviewController {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }
    var renderView: NSView? { panel?.contentView }

    func toggle(model: RemoteDashboardModel, narrow: Bool = false) {
        if isVisible {
            dismiss()
            return
        }

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1120, height: 768)
        let size = NSSize(width: min(narrow ? 760 : 1100, available.width - 32),
                          height: min(model.remoteProfile.adapter == .chromecast ? 710 : 630, available.height - 32))
        let frame = NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                           width: size.width, height: size.height)

        let panel = self.panel ?? makePanel(model: model, frame: frame)
        self.panel = panel
        panel.setFrame(frame, display: true)
        // Leave the foreground app and its keyboard focus in place.
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func makePanel(model: RemoteDashboardModel, frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.title = RemoteAction.showShortcuts.label
        panel.contentView = NSHostingView(rootView: ShortcutOverview(model: model) { [weak self] in self?.dismiss() })
        return panel
    }
}

@MainActor
private struct ShortcutOverview: View {
    @ObservedObject var model: RemoteDashboardModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RemoteAction.showShortcuts.label)
                        .font(SettingsStyle.Typography.dialogTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(model.activeMappingName) · \(model.remoteProfile.shortName)")
                        .font(SettingsStyle.Typography.body)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("关闭", action: onClose)
                    .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            GeometryReader { proxy in
                ScrollView {
                    MappingCanvas(model: model, live: model.live, readOnly: true)
                        .frame(height: max(model.remoteProfile.adapter == .chromecast ? 600 : 510, proxy.size.height - 32))
                        .padding(16)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(.rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12)).allowsHitTesting(false) }
    }
}
