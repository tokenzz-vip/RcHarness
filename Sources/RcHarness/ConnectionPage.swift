import SwiftUI

struct ConnectionPage: View {
    static let audioSectionID = "connection-audio"
    @ObservedObject var model: RemoteDashboardModel
    @State private var uninstallMicrophoneVisible = false
    @State private var remoteMenuHovered = false

    var body: some View {
        Grid(horizontalSpacing: SettingsStyle.Spacing.groups, verticalSpacing: 0) {
            GridRow {
                remotePanel
                    .frame(width: 224)
                    .gridCellUnsizedAxes(.vertical)
                VStack(spacing: SettingsStyle.Spacing.groups) {
                    connectionInfoPanel
                    audioPanel
                        .id(Self.audioSectionID)
                    microphonePanel
                }
            }
        }
    }

    private var remotePanel: some View {
        SettingsPanel {
            VStack(spacing: SettingsStyle.Spacing.groups) {
                VStack(spacing: 6) {
                    Text(model.remoteProfile.shortName)
                        .font(.system(size: 14, weight: .semibold))
                        .multilineTextAlignment(.center)
                    Text(model.remoteProfile.model)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if model.remoteProfile.validation != .voiceVerified {
                        Text(model.remoteProfile.validation.rawValue)
                            .font(SettingsStyle.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                LiveRemoteArtwork(live: model.live, profile: model.remoteProfile)
                    .frame(width: 80, height: 316)
                Spacer(minLength: 12)
                RemoteProfileMenu(model: model) {
                    HStack(spacing: SettingsStyle.Spacing.inline) {
                        Text(model.remoteProfile.shortName)
                            .font(SettingsStyle.Typography.body.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: SettingsStyle.controlRadius)
                            .fill(Color.primary.opacity(remoteMenuHovered ? 0.04 : 0))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: SettingsStyle.controlRadius)
                            .strokeBorder(Color.primary.opacity(remoteMenuHovered ? 0.18 : 0.10))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
                }
                .onHover { remoteMenuHovered = $0 }
                .help("更换遥控器")
                .accessibilityLabel("更换遥控器，当前：\(model.remoteProfile.shortName)")
                .accessibilityHint("选择要使用的遥控器型号")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var connectionInfoPanel: some View {
        SettingsPanel {
            HStack(spacing: SettingsStyle.Spacing.controls) {
                Label("连接信息", systemImage: "antenna.radiowaves.left.and.right")
                    .font(SettingsStyle.Typography.panelTitle)
                    .labelStyle(ConnectionPanelLabelStyle())
                Spacer(minLength: 8)
                Button("立即重新连接") { model.rescan() }
                    .buttonStyle(.bordered)
                Button("打开蓝牙设置") {
                    openSystemSettings("x-apple.systempreferences:com.apple.BluetoothSettings")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
            if !model.inputGranted || !model.accessibilityGranted {
                HStack {
                    Text("语音按键需要输入监控和辅助功能权限。")
                        .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("打开设置 → 权限") { model.openPermissions() }
                        .controlSize(.small)
                }
            }
            HStack(alignment: .top, spacing: SettingsStyle.Spacing.groups) {
                ConnectionInfoItem(
                    title: "按键连接",
                    value: model.isConnected ? "已连接" : "等待连接",
                    color: model.isConnected ? .green : .secondary
                )
                ConnectionInfoItem(
                    title: "语音连接",
                    value: model.voiceReady ? "已连接" : "等待连接",
                    color: model.voiceReady ? .green : .secondary
                )
                .help(model.voiceStatus)
                VStack(alignment: .leading, spacing: 4) {
                    Text("电量").font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                    Label(model.batteryLevel.map { "\(Int($0 * 100))%" } ?? "未知",
                          systemImage: batterySymbol(for: model.batteryLevel ?? 0))
                        .font(SettingsStyle.Typography.body.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 62, alignment: .leading)
            }
        }
    }

    private var microphonePanel: some View {
        SettingsPanel("虚拟麦克风组件", symbol: "mic") {
            HStack {
                Text("组件状态").font(SettingsStyle.Typography.body)
                Spacer()
                SettingsStatus(title: microphoneStatusTitle, color: model.microphoneInstalled && !model.microphoneUpdateAvailable ? .green : .orange)
            }
            Text(VoiceSetupGuidance.systemDefault)
                .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
            HStack {
                Button(microphoneInstallTitle) { model.installMicrophone() }
                    .disabled(model.microphoneOperationInProgress)
                if model.microphoneComponentPresent {
                    Button("卸载…") { uninstallMicrophoneVisible = true }
                        .disabled(model.microphoneOperationInProgress)
                }
                Button("系统默认输入…") { openSystemSettings("x-apple.systempreferences:com.apple.Sound-Settings.extension?input") }
            }.controlSize(.small)
            .confirmationDialog("卸载 RcHarness 麦克风组件？", isPresented: $uninstallMicrophoneVisible, titleVisibility: .visible) {
                Button("卸载", role: .destructive) { model.uninstallMicrophone() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("需要管理员授权，并会短暂重启系统音频服务。")
            }
        }
    }

    private var microphoneStatusTitle: String {
        if model.microphoneOperationInProgress { return "正在处理…" }
        if model.microphoneUpdateAvailable { return "需要更新" }
        return model.microphoneInstalled ? "已安装" : "未安装"
    }

    private var microphoneInstallTitle: String {
        if model.microphoneUpdateAvailable { return "更新麦克风组件…" }
        return model.microphoneComponentPresent ? "重新安装麦克风组件…" : "安装麦克风组件…"
    }

    private var audioPanel: some View {
        SettingsPanel("遥控器语音", symbol: "waveform") {
            Text("遥控器麦克风 → 接收设备 → 目标语音应用")
                .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
            Picker("接收设备", selection: $model.outputUID) {
                if !model.outputDevices.contains(where: { $0.id == model.outputUID }) {
                    Text("所选设备不可用").tag(model.outputUID)
                }
                ForEach(model.outputDevices) { device in Text(device.name).tag(device.id) }
            }.font(SettingsStyle.Typography.body)
            Text(VoiceSetupGuidance.selectReceiver)
                .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SettingsStyle.Spacing.controls) {
                Text("增益").font(SettingsStyle.Typography.body)
                Slider(value: $model.gain, in: 0...24, step: 1).accessibilityLabel("语音增益")
                Text("\(Int(model.gain)) dB").font(.system(size: 12, design: .monospaced)).frame(width: 48, alignment: .trailing)
            }
            Text("0 dB 不额外放大；音频仍会轻度降噪与限幅。增益会放大环境噪声，可从 6–12 dB 开始。")
                .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
            if case .failed(let message) = model.audioOutputState {
                Text(message).font(SettingsStyle.Typography.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("刷新音频设备") { model.refreshDevices(forceReload: true) }
                Button("发送 1 秒测试音") { model.playTestTone() }
                    .disabled(model.audioBusy || !model.outputDevices.contains(where: { $0.id == model.outputUID }))
                Spacer(minLength: 8)
                SettingsStatus(title: model.audioOutputDescription, color: audioStatusColor)
                    .accessibilityLabel("音频状态：" + model.audioOutputDescription)
                    .help("收音：\(model.voiceStatus)\n输出：\(model.audioOutputDescription)")
            }.controlSize(.small)
            Text(VoiceSetupGuidance.checkInputLevel)
                .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var audioStatusColor: Color {
        switch model.audioOutputState {
        case .streaming: .green
        case .preparing, .draining: .orange
        case .failed: .red
        case .idle: .secondary
        }
    }
}

private struct ConnectionInfoItem: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(value).font(SettingsStyle.Typography.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConnectionPanelLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SettingsStyle.Spacing.inline) {
            configuration.icon.foregroundStyle(.secondary)
            configuration.title
        }
    }
}
