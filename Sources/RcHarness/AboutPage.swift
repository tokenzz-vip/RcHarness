import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

/// "设置" page: about card, permissions, general preferences and diagnostics.
struct AboutPage: View {
    static let permissionsSectionID = "settings-permissions"
    static let configurationSectionID = "settings-configuration"
    @ObservedObject var model: RemoteDashboardModel
    @State private var feedbackVisible = false

    var body: some View {
        VStack(spacing: SettingsStyle.Spacing.groups) {
            SettingsPanel {
                HStack(alignment: .top, spacing: SettingsStyle.Spacing.sections) {
                    HStack(alignment: .top, spacing: SettingsStyle.Spacing.groups) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                            .padding(.top, 2)
                            .accessibilityLabel("RcHarness 应用图标")
                        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
                            Text("RcHarness").font(.system(size: 20, weight: .semibold))
                            Text("用遥控器操作 ChatGPT、Claude、Cursor 等 AI 对话与编程应用。")
                                .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: SettingsStyle.Spacing.controls) {
                                Button("项目主页") { NSWorkspace.shared.open(AppInfo.repository) }
                                Button("项目官网") { NSWorkspace.shared.open(AppInfo.website) }
                            }.buttonStyle(.link).font(SettingsStyle.Typography.caption).padding(.top, 2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
                        HStack(alignment: .firstTextBaseline, spacing: SettingsStyle.Spacing.inline) {
                            Text("当前版本").foregroundStyle(.secondary)
                            Text(AppInfo.version)
                                .font(.system(size: 14, weight: .semibold))
                                .monospacedDigit().help("构建 \(AppInfo.build)")
                        }.font(SettingsStyle.Typography.body)
                        Text("macOS 14 及以上").font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                        AppUpdateSettingsView(model: model.updates)
                    }.frame(width: 340, alignment: .leading)
                }.fixedSize(horizontal: false, vertical: true)
            }
            GlobalButtonsPanel(model: model)
            MouseModePanel(model: model)
            PermissionsPanel(model: model)
                .id(Self.permissionsSectionID)
            SettingsPanel("通用", symbol: "gearshape") {
                SettingsPreference(symbol: "arrow.up.arrow.down", title: "配置导入与导出", detail: "备份各遥控器的全局按键、鼠标设置和键位方案，以及组合动作和常用语。") {
                    HStack {
                        Button("导出配置") { if let url = FilePanels.chooseConfigurationDestination() { model.exportConfiguration(to: url) } }
                        Button("导入配置") { if let url = FilePanels.chooseConfigurationSource() { model.importConfiguration(from: url) } }
                        Button("恢复替换前配置") { model.previewConfigurationRecovery() }
                            .disabled(model.configurationRecoveryDate == nil)
                            .help(model.configurationRecoveryDate.map {
                                "恢复 \($0.formatted(date: .abbreviated, time: .shortened)) 保存的配置"
                            } ?? "首次替换配置后可恢复，重启应用后仍保留")
                    }
                }
                .id(Self.configurationSectionID)
                Divider()
                SettingsPreference(symbol: "power", title: "启动行为", detail: "选择登录和打开应用时的行为。") {
                    HStack(spacing: SettingsStyle.Spacing.groups) {
                        Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLoginEnabled)).toggleStyle(SettingsSwitchStyle()).controlSize(.small)
                        Toggle("启动时打开主面板", isOn: $model.openAtLaunch).toggleStyle(SettingsSwitchStyle()).controlSize(.small)
                    }.font(SettingsStyle.Typography.caption)
                }
                Divider()
                SettingsPreference(symbol: "dock.rectangle", title: "在 Dock 中显示应用图标", detail: "隐藏后仍可从菜单栏打开设置。") {
                    Toggle("显示 Dock 图标", isOn: $model.showDockIcon).labelsHidden().toggleStyle(SettingsSwitchStyle())
                }
                Divider()
                SettingsPreference(symbol: "textformat.abc", title: "显示键位方案前缀", detail: "显示方案所属遥控器的固定前缀；隐藏不影响已保存的方案。") {
                    Toggle("显示键位方案前缀", isOn: $model.showKeyProfilePrefix).labelsHidden().toggleStyle(SettingsSwitchStyle())
                }
                Divider()
                SettingsPreference(symbol: "globe", title: "应用语言", detail: "当前界面使用简体中文。") {
                    Text("简体中文").font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
                }
                Divider()
                SettingsPreference(symbol: "circle.lefthalf.filled", title: "主题模式", detail: "选择应用外观，切换后立即生效。") {
                    Picker("主题模式", selection: $model.themeMode) {
                        ForEach(AppThemeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                }
                Divider()
                SettingsPreference(symbol: "arrow.counterclockwise.circle", title: "首次使用", detail: "逐步检查权限、遥控器连接和语音输入，可随时继续未完成的设置。") {
                    Button(model.setup.completed ? "重新运行设置向导" : "继续设置向导") { model.setup.present() }
                }
            }
            SettingsPanel("诊断与支持", symbol: "stethoscope") {
                HStack {
                    Text("复制权限和连接状态，帮助排查问题。").font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制诊断信息") { model.copyDiagnostics() }
                    Button("刷新状态") { model.refreshPermissions() }
                    Button("提交反馈") { feedbackVisible = true }
                }
            }
        }
        .sheet(isPresented: $feedbackVisible) { FeedbackSheet(model: model) }
    }

}

private struct AppUpdateSettingsView: View {
    @ObservedObject var model: AppUpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
            HStack(spacing: SettingsStyle.Spacing.inline) {
                Button("检查更新…", action: model.checkForUpdates)
                    .disabled(!model.canCheckForUpdates)
                Button("版本历史") { NSWorkspace.shared.open(AppInfo.history) }
            }.controlSize(.small)
            HStack(spacing: SettingsStyle.Spacing.inline) {
                Toggle("自动检查更新", isOn: Binding(
                    get: { model.automaticallyChecksForUpdates },
                    set: model.setAutomaticallyChecksForUpdates
                ))
                .toggleStyle(.checkbox)
                .disabled(!model.isConfigured)
                .fixedSize()
                Text(model.lastUpdateCheckDate.map {
                    "上次检查：\($0.formatted(date: .abbreviated, time: .shortened))"
                } ?? "尚未检查更新")
                .foregroundStyle(.secondary)
                .fixedSize()
            }
        }.font(SettingsStyle.Typography.caption)
    }
}
