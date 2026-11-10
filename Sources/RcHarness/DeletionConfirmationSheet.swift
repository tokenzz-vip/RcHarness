import SwiftUI

@MainActor
struct DeletionConfirmationSheet: View {
    @ObservedObject var model: RemoteDashboardModel
    let pending: PendingDeletion

    private var current: PendingDeletion { model.pendingDeletion ?? pending }

    var body: some View {
        let deletion = current
        let impact = deletion.impact
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.sections) {
            Text("删除「\(deletion.name)」？")
                .font(SettingsStyle.Typography.dialogTitle).lineLimit(2)
            Text("该项目正在被使用，删除将影响以下配置。")
                .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsStyle.Spacing.groups) {
                    if !impact.mappings.isEmpty {
                        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
                            Text("\(impact.remoteCount) 个型号 · \(impact.directMappings + impact.indirectMappings) 处按键映射")
                                .font(.system(size: 13, weight: .semibold))
                            ForEach(impact.mappings) { usage in
                                HStack(alignment: .top, spacing: SettingsStyle.Spacing.controls) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(remoteName(usage.remoteID)).foregroundStyle(.secondary)
                                        Text(usage.name)
                                    }
                                    Spacer(minLength: 8)
                                    Text("\(usage.count) 处" + (usage.indirect > 0 ? "（含间接 \(usage.indirect)）" : ""))
                                        .monospacedDigit().foregroundStyle(.secondary)
                                }.font(SettingsStyle.Typography.body)
                            }
                        }
                    }
                    if !impact.macros.isEmpty {
                        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
                            Text("\(impact.macros.count) 个组合动作受影响")
                                .font(.system(size: 13, weight: .semibold))
                            ForEach(impact.macros) { usage in
                                HStack(alignment: .top) {
                                    Text(usage.name)
                                    Spacer(minLength: 8)
                                    Text(usage.directSteps > 0 ? "直接引用 \(usage.directSteps) 步" : "嵌套依赖")
                                        .foregroundStyle(.secondary)
                                }.font(SettingsStyle.Typography.body)
                            }
                        }
                    }
                    if !impact.assignments.isEmpty {
                        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
                            Text("\(impact.assignments.count) 个五向分配将解除")
                                .font(.system(size: 13, weight: .semibold))
                            Text(impact.assignments.map(\.label).joined(separator: "、"))
                                .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(SettingsStyle.panelPadding)
            }
            .frame(maxHeight: 300)
            .background(SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: SettingsStyle.panelRadius))
            Text("已有按键和组合动作引用将保留并显示失效；相关操作将无法完成。删除后可在窗口底部撤销，恢复原内容、顺序及五向分配。")
                .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = model.actionNotices.first(where: { $0.source == .configurationDeletion }) {
                Text(notice.message).font(SettingsStyle.Typography.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { model.cancelDeletion() }.keyboardShortcut(.cancelAction)
                Button("仍然删除", role: .destructive) { model.confirmDeletion(deletion.id) }
            }
        }
        .padding(SettingsStyle.pagePadding).frame(width: 528)
    }

    private func remoteName(_ id: String) -> String {
        model.availableRemoteProfiles.first { $0.id == id }?.shortName ?? id
    }
}

@MainActor
struct DeletionUndoBar: View {
    @ObservedObject var model: RemoteDashboardModel
    let deleted: DeletedConfigurationObject

    var body: some View {
        HStack(spacing: SettingsStyle.Spacing.controls) {
            Text("已删除「\(deleted.name)」")
                .font(SettingsStyle.Typography.body).lineLimit(1).truncationMode(.middle)
                .help(deleted.name)
            Spacer(minLength: 12)
            Button("撤销删除") { model.undoDeletion() }
                .controlSize(.small)
                .help("恢复最近删除的项目、顺序及分配；本次运行内可连续撤销")
            Button { model.dismissDeletionUndo() } label: {
                Image(systemName: "xmark").font(SettingsStyle.Typography.caption)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("关闭删除撤销提示").accessibilityLabel("关闭删除撤销提示")
        }
        .padding(.horizontal, SettingsStyle.pagePadding).padding(.vertical, 12)
        .background(SettingsStyle.subtle)
        .overlay(alignment: .top) { Divider() }
    }
}
