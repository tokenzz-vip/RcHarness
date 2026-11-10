import SwiftUI

@MainActor
struct ConfigurationImportSheet: View {
    @ObservedObject var model: RemoteDashboardModel
    let preview: ConfigurationImportPreview
    @State private var commitError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.sections) {
            VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
                Text(preview.isRecovery ? "恢复替换前配置" : "导入配置")
                    .font(SettingsStyle.Typography.dialogTitle)
                Text(preview.source).font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(preview.source)
                Text("将替换各遥控器的全局按键、键位方案及 Harness 绑定，以及共用的组合动作、常用语和五向分配。")
                    .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: SettingsStyle.Spacing.sections, verticalSpacing: 10) {
                GridRow {
                    Text("替换范围").gridColumnAlignment(.leading)
                    Text("当前").gridColumnAlignment(.trailing)
                    Text(preview.isRecovery ? "恢复后" : "导入后").gridColumnAlignment(.trailing)
                }.font(SettingsStyle.Typography.caption.weight(.medium)).foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                countRow("遥控器配置（含全局按键）", preview.current.remotes, preview.prepared.counts.remotes)
                countRow("按键方案", preview.current.profiles, preview.prepared.counts.profiles)
                countRow("Harness 应用", preview.current.harnesses, preview.prepared.counts.harnesses)
                countRow("Harness 方案绑定", preview.current.bindings, preview.prepared.counts.bindings)
                countRow("组合动作", preview.current.macros, preview.prepared.counts.macros)
                countRow("常用语", preview.current.phrases, preview.prepared.counts.phrases)
                countRow("五向分配", preview.current.assignments, preview.prepared.counts.assignments)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsStyle.panelPadding)
            .background(SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: SettingsStyle.panelRadius))
            if preview.prepared.isLegacy || !preview.prepared.notices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if preview.prepared.isLegacy {
                        Text("此备份未包含分型号配置，仅导入当前遥控器；其他型号将使用默认配置。")
                    }
                    ForEach(preview.prepared.notices, id: \.self) { Text($0) }
                }
                .font(SettingsStyle.Typography.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("替换前会自动保存当前配置，可从设置中的“恢复替换前配置”找回，重启后仍可恢复。每次替换保留最近一份备份。")
                .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let commitError {
                Text(commitError).font(SettingsStyle.Typography.body).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("取消") { model.cancelConfigurationImport() }
                    .keyboardShortcut(.cancelAction)
                Button(preview.isRecovery ? "恢复配置" : "替换配置") {
                    do {
                        try model.confirmConfigurationImport(preview.id)
                    } catch {
                        commitError = (error as? SettingsBackupError)?.localizedDescription
                            ?? "无法保存配置及恢复备份，当前配置未更改。请重试。\n" + error.localizedDescription
                        model.postNotice(commitError ?? error.localizedDescription, level: .error,
                            recoveryAction: .configuration,
                            source: preview.isRecovery ? .configurationRecovery : .configurationImport)
                        Log.settings.error("Configuration replacement failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(SettingsStyle.pagePadding)
        .frame(width: 528)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func countRow(_ title: String, _ current: Int, _ incoming: Int) -> some View {
        GridRow {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(current)").foregroundStyle(.secondary)
            Text("\(incoming)").fontWeight(.medium)
        }
        .font(SettingsStyle.Typography.body).monospacedDigit()
    }
}
