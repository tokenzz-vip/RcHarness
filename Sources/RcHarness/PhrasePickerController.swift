import AppKit
import SwiftUI

@MainActor
final class PhrasePickerController {
    let model = PhrasePickerModel()
    private var panel: PhrasePickerPanel?

    init(onOutput: @escaping (String) -> Void) {
        model.onOutput = onOutput
        model.onDismiss = { [weak self] in self?.panel?.orderOut(nil) }
    }

    func show(phrases: [SavedPhrase], assignments: PhraseAssignments) {
        model.present(phrases: phrases, assignments: assignments)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let size = PhrasePickerView.panelSize
        if panel == nil {
            let panel = PhrasePickerPanel(contentRect: NSRect(origin: .zero, size: size),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.onCancel = { [weak self] in self?.model.dismiss() }
            panel.contentView = NSHostingView(rootView: PhrasePickerView(model: model))
            self.panel = panel
        }
        panel?.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        // Keep the current application active; ordering out restores its text focus before output.
        panel?.makeKeyAndOrderFront(nil)
    }

    var renderView: NSView? { panel?.contentView }
}

@MainActor
struct PhrasePickerView: View {
    static let panelSize = NSSize(width: 296, height: 340)
    @ObservedObject var model: PhrasePickerModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("常用语").font(.system(size: 14, weight: .medium))
                Spacer()
                Button { model.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("关闭常用语（返回 / 主页 / 菜单 / Esc）")
                .accessibilityLabel("关闭常用语")
            }
            .frame(height: 24)
            PhrasePadView(title: { model.phrases[$0]?.displayTitle ?? "未分配" },
                          isAssigned: { model.phrases[$0] != nil }, showsAssignmentMarks: false,
                          diameter: 244) { input in
                _ = model.handle(input, pressed: true)
                _ = model.handle(input, pressed: false)
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 2) {
                Text(model.phrases.isEmpty ? "先在按键页分配常用语" : model.message)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("返回 / 主页 /")
                    Text("esc")
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 4).frame(height: 16)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                    Text("关闭")
                }
                .foregroundStyle(.secondary)
            }
            .font(.system(size: 11)).lineLimit(1)
            .frame(height: 32)
        }
        .padding(12)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)) }
    }
}

@MainActor
private final class PhrasePickerPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == VirtualKey.escape { onCancel?() }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func resignKey() {
        super.resignKey()
        onCancel?()
    }
}
