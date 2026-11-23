import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

@MainActor
struct PermissionsPanel: View {
    @ObservedObject var model: RemoteDashboardModel

    var body: some View {
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
            permissionRow("麦克风", detail: model.useRemoteMicrophone ? "将遥控器语音写入回环设备" : "当前使用目标工具选择的麦克风",
                          symbol: "mic", granted: !model.useRemoteMicrophone || model.microphoneGranted) {
                guard model.useRemoteMicrophone else { return }
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { model.refreshPermissions() } }
                } else { openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
            }
        }
    }

    private func permissionRow(_ title: String, detail: String, symbol: String, granted: Bool, action: @escaping () -> Void) -> some View {
        SettingsPreference(symbol: symbol, title: title, detail: detail) {
            HStack(spacing: SettingsStyle.Spacing.controls) {
                SettingsStatus(title: granted ? "已授权" : "待授权", color: granted ? .green : .orange)
                Button(granted ? "系统设置" : "前往授权", action: action).frame(width: 84)
            }
        }
    }
}
