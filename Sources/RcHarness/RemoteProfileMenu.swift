import AppKit
import SwiftUI

/// Uses native menu items so colored trailing indicators retain their color
/// even for the disabled, checked current model.
@MainActor
struct RemoteProfileMenu<Label: View>: View {
    @ObservedObject var model: RemoteDashboardModel
    @ViewBuilder var label: Label

    var body: some View {
        label
            .accessibilityHidden(true)
            .overlay { RemoteProfileMenuAnchor(model: model) }
    }
}

@MainActor
enum RemoteProfileMenuContent {
    static func make(model: RemoteDashboardModel, target: AnyObject?, action: Selector?) -> NSMenu {
        let menu = NSMenu(title: "更换遥控器")
        menu.autoenablesItems = false
        let font = NSFont.menuFont(ofSize: 0)
        let titleWidth = model.availableRemoteProfiles.map {
            ($0.selectionName as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: ceil(titleWidth) + 26)]
        for profile in model.availableRemoteProfiles {
            let connected = model.isRemoteConnected(profile)
            let item = NSMenuItem(title: profile.selectionName, action: action, keyEquivalent: "")
            let title = NSMutableAttributedString(string: profile.selectionName + "\t●",
                                                 attributes: [.font: font, .paragraphStyle: paragraph])
            title.addAttributes([.foregroundColor: connected ? NSColor.systemGreen : NSColor.systemGray,
                                 .font: NSFont.systemFont(ofSize: 9), .baselineOffset: 1],
                                range: NSRange(location: title.length - 1, length: 1))
            item.attributedTitle = title
            item.state = profile.id == model.remoteProfile.id ? .on : .off
            item.isEnabled = profile.id != model.remoteProfile.id
            item.target = target
            item.representedObject = profile.id
            item.toolTip = connected ? "已连接" : "未连接"
            item.setAccessibilityLabel(profile.selectionName + "，" + (connected ? "已连接" : "未连接"))
            menu.addItem(item)
        }
        if model.availableRemoteProfiles.count == 1 {
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "当前仅支持此型号", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        return menu
    }
}

@MainActor
private struct RemoteProfileMenuAnchor: NSViewRepresentable {
    @ObservedObject var model: RemoteDashboardModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.openMenu(_:)))
        button.isBordered = false
        button.isTransparent = true
        button.setAccessibilityRole(.popUpButton)
        button.setAccessibilityHelp("选择要使用的遥控器型号")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.model = model
        button.setAccessibilityLabel("更换遥控器，当前：\(model.remoteProfile.shortName)")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    @MainActor
    final class Coordinator: NSObject {
        var model: RemoteDashboardModel

        init(model: RemoteDashboardModel) { self.model = model }

        @objc func openMenu(_ sender: NSButton) {
            let menu = RemoteProfileMenuContent.make(model: model, target: self, action: #selector(selectRemote(_:)))
            // NSButton uses flipped coordinates: its bottom edge is maxY.
            let bottom = sender.isFlipped ? sender.bounds.maxY + 5 : sender.bounds.minY - 5
            menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: bottom), in: sender)
        }

        @objc private func selectRemote(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            model.selectRemoteProfile(id)
        }
    }
}
