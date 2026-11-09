import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

/// "设置" page: about card, permissions, general preferences and diagnostics.
struct AboutPage: View {
    @ObservedObject var model: RemoteDashboardModel

    var body: some View {
        VStack(spacing: 18) {
            SettingsPanel {
                HStack(alignment: .top, spacing: 24) {
                    HStack(alignment: .top, spacing: 16) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                            .padding(.top, 2)
                            .accessibilityLabel("RcHarness 应用图标")
                        VStack(alignment: .leading, spacing: 8) {
                            Text("RcHarness").font(.system(size: 20, weight: .semibold))
                            Text("用遥控器操作 Codex、Claude、Cursor 等 AI 对话与编程应用。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 14) {
                                Button("项目主页") { NSWorkspace.shared.open(AppInfo.repository) }
                                Button("项目官网") { NSWorkspace.shared.open(AppInfo.website) }
                            }.buttonStyle(.link).font(.system(size: 11)).padding(.top, 2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("当前版本").foregroundStyle(.secondary)
                            Text(AppInfo.version)
                                .font(.system(size: 14, weight: .semibold))
                                .monospacedDigit().help("构建 \(AppInfo.build)")
                        }.font(.system(size: 12))
                        Text("Apple Silicon · macOS 14 及以上").font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("检查更新…") {}.disabled(true).help("此本地构建尚未配置更新源")
                            Button("版本历史") { NSWorkspace.shared.open(AppInfo.history) }
                        }.controlSize(.small)
                    }.frame(width: 236, alignment: .leading)
                }.fixedSize(horizontal: false, vertical: true)
            }
            GlobalButtonsPanel(model: model)
            permissionsPanel
            SettingsPanel("通用", symbol: "gearshape") {
                SettingsPreference(symbol: "arrow.up.arrow.down", title: "配置导入与导出", detail: "备份各遥控器独立的全局按键、键位方案、组合动作和常用语。") {
                    HStack {
                        Button("导出配置") { if let url = FilePanels.chooseConfigurationDestination() { model.exportConfiguration(to: url) } }
                        Button("导入配置") { if let url = FilePanels.chooseConfigurationSource() { model.importConfiguration(from: url) } }
                    }
                }
                Divider()
                SettingsPreference(symbol: "power", title: "启动行为", detail: "选择登录和打开应用时的行为。") {
                    HStack(spacing: 16) {
                        Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLoginEnabled)).toggleStyle(.switch).controlSize(.small)
                        Toggle("启动时打开主面板", isOn: $model.openAtLaunch).toggleStyle(.switch).controlSize(.small)
                    }.font(.system(size: 11))
                }
                Divider()
                SettingsPreference(symbol: "dock.rectangle", title: "在 Dock 中显示应用图标", detail: "隐藏后仍可从菜单栏打开设置。") {
                    Toggle("显示 Dock 图标", isOn: $model.showDockIcon).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                SettingsPreference(symbol: "textformat.abc", title: "显示键位方案前缀", detail: "显示方案所属遥控器的固定前缀；隐藏不影响已保存的方案。") {
                    Toggle("显示键位方案前缀", isOn: $model.showKeyProfilePrefix).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                SettingsPreference(symbol: "globe", title: "应用语言", detail: "当前界面使用简体中文。") {
                    Text("简体中文").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Divider()
                SettingsPreference(symbol: "arrow.counterclockwise.circle", title: "首次使用", detail: "查看设备连接、权限和麦克风设置。") {
                    Button("查看设置指引") { model.page = .connection }
                }
            }
            SettingsPanel("诊断与支持", symbol: "stethoscope") {
                HStack {
                    Text("复制权限和连接状态，帮助排查问题。").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制诊断信息") { model.copyDiagnostics() }
                    Button("刷新状态") { model.refreshPermissions() }
                }
            }
        }
    }

    private var permissionsPanel: some View {
        SettingsPanel("权限", symbol: "shield.lefthalf.filled") {
            permissionRow("蓝牙", detail: "连接遥控器及其语音服务", symbol: "antenna.radiowaves.left.and.right", granted: model.bluetoothGranted) {
                openSystemSettings("x-apple.systempreferences:com.apple.BluetoothSettings")
            }
            Divider()
            permissionRow("输入监控", detail: "接收遥控器的普通按键", symbol: "keyboard", granted: model.inputGranted) {
                if !CGRequestListenEventAccess() { openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") }
            }
            Divider()
            permissionRow("辅助功能", detail: "向当前 App 发送键盘与鼠标操作", symbol: "hand.raised", granted: model.accessibilityGranted) {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
            Divider()
            permissionRow("麦克风", detail: "将遥控器语音写入回环设备", symbol: "mic", granted: model.microphoneGranted) {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { model.refreshPermissions() } }
                } else { openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
            }
        }
    }

    private func permissionRow(_ title: String, detail: String, symbol: String, granted: Bool, action: @escaping () -> Void) -> some View {
        SettingsPreference(symbol: symbol, title: title, detail: detail) {
            HStack(spacing: 12) {
                SettingsStatus(title: granted ? "已授权" : "待授权", color: granted ? .green : .orange)
                Button(granted ? "系统设置" : "前往授权", action: action).frame(width: 84)
            }
        }
    }
}
