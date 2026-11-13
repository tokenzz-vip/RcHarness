import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class HarnessSwitcherController {
    let model = HarnessSwitcherModel()
    private let harnesses: () -> [HarnessConfiguration]
    private let onSelection: (HarnessSwitcherItem) -> Void
    private let onError: (String) -> Void
    private var panel: HarnessSwitcherPanel?
    private var observers: [NSObjectProtocol] = []

    init(harnesses: @escaping () -> [HarnessConfiguration],
         onSelection: @escaping (HarnessSwitcherItem) -> Void,
         onError: @escaping (String) -> Void) {
        self.harnesses = harnesses
        self.onSelection = onSelection
        self.onError = onError
        model.onDismiss = { [weak self] in self?.panel?.orderOut(nil) }
        model.onConfirm = { [weak self] item in self?.activate(item) }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func show(input: ControllerInput? = nil) {
        model.present(items: runningItems(), frontmostProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                      triggerInput: input)
        showPanel()
    }

    func refresh() {
        guard model.isPresented else { return }
        model.refresh(items: runningItems())
    }

    private func runningItems() -> [HarnessSwitcherItem] {
        let applications = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map {
            HarnessRunningApplication(processID: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                                      applicationPath: $0.bundleURL?.path, isRegular: $0.activationPolicy == .regular)
        }
        return HarnessSwitcherItem.running(harnesses: harnesses(), applications: applications)
    }

    private func activate(_ item: HarnessSwitcherItem) {
        let result = HarnessApplicationActivation.perform(processID: item.id, isAvailable: {
            // A listed app may have quit, been replaced, or been disabled.
            runningItems().contains(item)
        })
        switch result {
        case .activated:
            onSelection(item)
        case .unavailable:
            onError("该 Harness 已退出或停用，请重新打开运行列表。")
        case .failed:
            Log.app.error("Harness activation failed pid=\(item.id) accessibility_granted=\(AXIsProcessTrusted())")
            onError(AXIsProcessTrusted() ? "无法切换到「\(item.name)」，请重试。" : "无法切换到「\(item.name)」，请在系统设置中开启 RcHarness 的辅助功能权限后重试。")
        }
    }

    private func showPanel(narrow: Bool = false) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let idealWidth = CGFloat(max(1, model.items.count)) * 132 + 48
        let width = min(max(360, idealWidth), narrow ? 420 : 920, frame.width - 48)
        let size = NSSize(width: width, height: 256)
        if panel == nil {
            let panel = HarnessSwitcherPanel(contentRect: NSRect(origin: .zero, size: size),
                                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.onCancel = { [weak self] reason in self?.model.dismiss(reason: reason) }
            panel.onKey = { [weak self] key in
                switch key {
                case VirtualKey.leftArrow: self?.model.move(-1)
                case VirtualKey.rightArrow: self?.model.move(1)
                case VirtualKey.returnKey: self?.model.confirm()
                case VirtualKey.escape: self?.model.dismiss(reason: "keyboard-escape")
                default: break
                }
            }
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            let cornerRadius: CGFloat = 26
            // Mask the material itself as well as its hosted content. A layer
            // corner radius alone does not define the behind-window effect or
            // the native window shadow's shape.
            let maskSize = NSSize(width: cornerRadius * 2 + 1, height: cornerRadius * 2 + 1)
            let mask = NSImage(size: maskSize, flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                         bottom: cornerRadius, right: cornerRadius)
            mask.resizingMode = .stretch
            effect.maskImage = mask
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            let content = NSHostingView(rootView: HarnessSwitcherView(model: model))
            content.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                content.topAnchor.constraint(equalTo: effect.topAnchor),
                content.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            panel.contentView = effect
            self.panel = panel
        }
        panel?.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel?.invalidateShadow()
        // A nonactivating panel accepts navigation without replacing the foreground app.
        panel?.makeKeyAndOrderFront(nil)
        Log.switcher.notice("Panel ordered presented=\(self.model.isPresented) visible=\(self.panel?.isVisible == true) key=\(self.panel?.isKeyWindow == true) active_space=\(self.panel?.isOnActiveSpace == true)")
    }

    /// Uses sample processes only in --render-settings; never launches the preview apps.
    func showPreview(narrow: Bool) {
        let items = HarnessConfiguration.defaults.enumerated().map { index, harness in
            HarnessSwitcherItem(harnessID: harness.id, name: harness.name,
                                application: HarnessRunningApplication(processID: Int32(index + 1),
                                                                       bundleIdentifier: harness.bundleIdentifier,
                                                                       applicationPath: harness.installedApplicationURL?.path))
        }
        model.onConfirm = nil
        model.present(items: items, frontmostProcessID: items.first?.id)
        showPanel(narrow: narrow)
    }

    var renderView: NSView? { panel?.contentView }
}

@MainActor
private final class HarnessSwitcherPanel: NSPanel {
    var onKey: ((UInt16) -> Void)?
    var onCancel: ((String) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) { onKey?(event.keyCode) }
    override func cancelOperation(_ sender: Any?) { onCancel?("cancel-operation") }
    override func resignKey() {
        super.resignKey()
        onCancel?("panel-resigned-key")
    }
}
