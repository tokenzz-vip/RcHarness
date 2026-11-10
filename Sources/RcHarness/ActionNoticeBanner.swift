import SwiftUI

@MainActor
struct ActionNoticeBanner: View {
    let notice: ActionNotice
    let count: Int
    let onDismiss: () -> Void
    let onNext: () -> Void
    let onRecovery: (ActionNotice.RecoveryAction) -> Void
    let onCopy: () -> Void
    @State private var detailsExpanded = false
    @State private var copied = false

    init(notice: ActionNotice, count: Int, onDismiss: @escaping () -> Void,
         onNext: @escaping () -> Void, onRecovery: @escaping (ActionNotice.RecoveryAction) -> Void,
         onCopy: @escaping () -> Void, initiallyExpanded: Bool = false) {
        self.notice = notice
        self.count = count
        self.onDismiss = onDismiss
        self.onNext = onNext
        self.onRecovery = onRecovery
        self.onCopy = onCopy
        _detailsExpanded = State(initialValue: initiallyExpanded)
    }

    private var color: Color {
        switch notice.level {
        case .success: .green
        case .information: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
            HStack(spacing: SettingsStyle.Spacing.inline) {
                Label(notice.level.title, systemImage: notice.level.symbol)
                    .font(SettingsStyle.Typography.body.weight(.semibold)).foregroundStyle(color)
                Spacer(minLength: 8)
                if count > 1 {
                    Button("另有 \(count - 1) 条提示", action: onNext)
                        .font(SettingsStyle.Typography.caption).buttonStyle(.link)
                        .accessibilityHint("切换提示，未关闭的失败仍会保留")
                }
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
            }
            if detailsExpanded {
                ScrollView {
                    Text(notice.message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(height: 180)
            } else {
                Text(notice.message).lineLimit(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: SettingsStyle.Spacing.controls) {
                Button(detailsExpanded ? "收起详情" : "展开详情") { detailsExpanded.toggle() }
                    .accessibilityValue(detailsExpanded ? "已展开" : "已收起")
                Button(copied ? "已复制" : "复制详情") { onCopy(); copied = true }
                Spacer(minLength: 0)
            }
            .buttonStyle(.link)
            if let action = notice.recoveryAction {
                Button(action.title) { onRecovery(action) }
                    .controlSize(.small)
            }
        }
        .font(SettingsStyle.Typography.body)
        .padding(SettingsStyle.controlPadding)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SettingsStyle.panelRadius))
        .overlay { RoundedRectangle(cornerRadius: SettingsStyle.panelRadius).strokeBorder(color.opacity(0.3)) }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
    }
}
