import AppKit
import SwiftUI

/// Both routes share the main window, so closing and reopening it preserves the
/// guide's place and the settings window never sits behind a separate wizard.
@MainActor
struct HarnessRootView: View {
    @ObservedObject var model: RemoteDashboardModel
    @ObservedObject var setup: SetupFlow

    var body: some View {
        Group {
            if setup.isPresented {
                SetupView(model: model, setup: setup)
            } else {
                RemoteDashboardView(model: model)
            }
        }
    }
}

@MainActor
struct SetupView: View {
    @ObservedObject var model: RemoteDashboardModel
    @ObservedObject var setup: SetupFlow

    private var readiness: SetupReadiness { model.setupReadiness }

    var body: some View {
        VStack(spacing: 0) {
            stepHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsStyle.Spacing.sections) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(setup.step.title).font(SettingsStyle.Typography.pageTitle)
                            .accessibilityAddTraits(.isHeader)
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content
                }
                .frame(maxWidth: 840, alignment: .leading)
                .padding(.horizontal, 36).padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .id(setup.step)
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .frame(minWidth: SettingsStyle.minimumWindowSize.width, minHeight: SettingsStyle.minimumWindowSize.height)
        .tint(.blue)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .topTrailing) {
            if let notice = model.actionNotices.first {
                ActionNoticeBanner(notice: notice, count: model.actionNotices.count,
                    onDismiss: { model.dismissNotice(notice.id) }, onNext: model.showNextNotice,
                    onRecovery: { action in setup.pause(); model.performNoticeRecovery(action) },
                    onCopy: { model.copy(notice.message) })
                    .padding(.top, 120).padding(.trailing, 24)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        .onChange(of: readiness.ready) { _, ready in if !ready { setup.resetVoiceTest() } }
    }

    private var stepHeader: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(SetupStep.allCases) { step in
                stepButton(for: step)
            }
        }
        .background(alignment: .top) { stepConnections }
        .frame(maxWidth: 900)
        .padding(.horizontal, 36).padding(.top, 38).padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置向导进度")
    }

    // Keep these expressions separate so Xcode 16's SwiftUI type checker can
    // compile the progress header as well as newer toolchains do.
    private func stepButton(for step: SetupStep) -> some View {
        let current = step == setup.step
        let previous = step.index < setup.step.index
        return Button { setup.goBack(to: step) } label: {
            VStack(spacing: 10) {
                stepIndicator(for: step, current: current, previous: previous)
                Text(step.title)
                    .font(.system(size: 12, weight: current ? .semibold : .regular))
                    .foregroundStyle(current ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SetupStepButtonStyle())
        .disabled(step.index > setup.step.index)
        .accessibilityLabel("第 \(step.index + 1) 步，\(step.title)")
        .accessibilityValue(current ? "当前步骤" : previous ? "已完成，可返回" : "待完成")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func stepIndicator(for step: SetupStep, current: Bool, previous: Bool) -> some View {
        let fill: Color = current ? .accentColor : previous ? .accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor)
        let border: Color = current || previous ? .accentColor : .primary.opacity(0.18)
        let foreground: Color = current ? .white : previous ? .accentColor : .secondary
        return ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(border, lineWidth: 1)
            if previous {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
            } else {
                Text("\(step.index + 1)")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
        }
        .foregroundStyle(foreground)
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    private var stepConnections: some View {
        GeometryReader { geometry in
            let column = geometry.size.width / CGFloat(SetupStep.allCases.count)
            ForEach(0..<(SetupStep.allCases.count - 1), id: \.self) { index in
                stepConnection(at: index, columnWidth: column)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func stepConnection(at index: Int, columnWidth: CGFloat) -> some View {
        let startCenter: CGFloat = CGFloat(index) + 0.5
        let endCenter: CGFloat = CGFloat(index) + 1.5
        let startX: CGFloat = columnWidth * startCenter + 22
        let endX: CGFloat = columnWidth * endCenter - 22
        let color: Color = index < setup.step.index ? .accentColor : .primary.opacity(0.12)
        return Path { path in
            path.move(to: CGPoint(x: startX, y: 14))
            path.addLine(to: CGPoint(x: endX, y: 14))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !setup.canContinue(readiness), let blockingHint {
                Label(blockingHint, systemImage: "info.circle")
                    .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: SettingsStyle.Spacing.controls) {
                if setup.step != .welcome {
                    Button("上一步") { setup.goBack(to: SetupStep.allCases[setup.step.index - 1]) }
                }
                Text("第 \(setup.step.index + 1) 步，共 \(SetupStep.allCases.count) 步 · 设置自动保存在本机")
                    .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                Spacer()
                Button(setup.completed ? "返回设置" : "稍后设置") { setup.pause(); model.page = .about }
                Button(setup.step == .complete ? "开始使用" : setup.step == .welcome ? "开始设置" : "继续") {
                    setup.advance(readiness)
                    if !setup.isPresented { model.page = .mapping }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!setup.canContinue(readiness) || model.audioBusy)
            }.controlSize(.large)
        }
        .padding(.horizontal, 36).padding(.vertical, 20)
    }

    private var subtitle: String {
        switch setup.step {
        case .welcome: "用几步连接遥控器，配置按键和语音输入。你可以随时暂停，之后从设置中继续。"
        case .permissions: "逐项授权后返回 RcHarness，状态会自动刷新。权限由 macOS 管理。"
        case .remote: "选择手中的型号，在 macOS 蓝牙设置中完成配对，再按一下非语音键。"
        case .audio: "把遥控器音频送到接收设备，再让语音应用使用同一个麦克风。"
        case .voice: "让 RcHarness 发送的快捷键，与目标输入法或听写工具的语音快捷键保持一致。"
        case .test: "打开目标应用的文本输入框，用遥控器说一句话。结束后返回这里确认结果。"
        case .complete: "连接和语音试用已确认。接下来可以使用默认按键，或为常用应用调整方案。"
        }
    }

    @ViewBuilder private var content: some View {
        switch setup.step {
        case .welcome: welcome
        case .permissions:
            PermissionsPanel(model: model)
            Button("刷新权限状态") { model.refreshPermissions() }
            note("如果输入监控授权后仍收不到按键，请退出并重新打开 RcHarness，向导会保留进度。")
        case .remote: remote
        case .audio: audio
        case .voice: voice
        case .test: trial
        case .complete: completion
        }
    }

    private var welcome: some View {
        VStack(spacing: SettingsStyle.Spacing.groups) {
            SettingsPanel("用遥控器操作常用应用", symbol: "appletvremote.gen4") {
                Text("方向键、确认键和自定义动作，让你在 ChatGPT、Claude、Cursor 等应用中切换对话、发送常用语。")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Divider()
                Label("检查系统权限与设备连接", systemImage: "lock.shield")
                Label("准备虚拟麦克风与语音快捷键", systemImage: "mic")
                Label("实际试用，再确认完成", systemImage: "checkmark.circle")
            }
            SettingsPanel("开始前准备", symbol: "checklist") {
                Text("准备好支持的蓝牙遥控器和一个语音输入工具。安装或更新麦克风组件时，macOS 会请求管理员授权，并短暂重启音频服务。")
                    .fixedSize(horizontal: false, vertical: true)
                Text("RcHarness 负责连接遥控器和输入工具，语音识别由你选择的输入法或听写工具完成。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.system(size: 13))
    }

    private var remote: some View {
        HStack(alignment: .top, spacing: SettingsStyle.Spacing.sections) {
            LiveRemoteArtwork(live: model.live, profile: model.remoteProfile)
                .frame(width: 90, height: 356).padding(20)
                .accessibilityLabel(model.remoteProfile.shortName)
            VStack(alignment: .leading, spacing: SettingsStyle.Spacing.groups) {
                SettingsPanel("遥控器型号", symbol: "appletvremote.gen4") {
                    Picker("选择型号", selection: Binding(get: { model.remoteProfile.id }, set: model.selectRemoteProfile)) {
                        ForEach(model.availableRemoteProfiles) { Text($0.selectionName).tag($0.id) }
                    }
                    Text(model.remoteProfile.model + " · " + model.remoteProfile.validation.rawValue)
                        .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                    if !model.remoteProfile.pairingButtons.isEmpty {
                        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
                            HStack(spacing: 8) {
                                Text("蓝牙配对：同时长按")
                                ForEach(Array(model.remoteProfile.pairingButtons.enumerated()), id: \.offset) { index, input in
                                    if index > 0 { Text("+").foregroundStyle(.secondary) }
                                    Label(input.label, systemImage: input.symbol)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                            Text(model.remoteProfile.pairingHint)
                                .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.font(.system(size: 13))
                    }
                    HStack(spacing: SettingsStyle.Spacing.inline) {
                        Button("打开蓝牙设置") { openSystemSettings("x-apple.systempreferences:com.apple.BluetoothSettings") }
                        Button("重新连接") { model.rescan() }
                    }
                }
                SettingsPanel("连接与按键检查", symbol: "antenna.radiowaves.left.and.right") {
                    status("按键连接", ready: model.isConnected)
                    status("语音连接", ready: model.voiceReady)
                    Text(model.voiceStatus).font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    if setup.testedInputs.isEmpty {
                        Label {
                            Text("按一下\(Text("非语音键").foregroundColor(.red).bold())，检查按键是否能被接收。")
                        } icon: {
                            Image(systemName: "hand.tap")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.primary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("已收到：" + setup.testedInputs.sorted { $0.rawValue < $1.rawValue }.map(\.label).joined(separator: "、"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text("向导内的非语音键仅用于检测，不执行已配置的动作。")
                        .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                }.font(.system(size: 13))
            }
        }
    }

    private var audio: some View {
        VStack(spacing: SettingsStyle.Spacing.groups) {
            SettingsPanel("虚拟麦克风组件", symbol: "mic") {
                if !model.useRemoteMicrophone {
                    Text("当前未使用遥控器麦克风，无需安装 RcHarness 虚拟麦克风组件。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                status("RcHarness 麦克风", ready: !model.useRemoteMicrophone || (model.microphoneInstalled && !model.microphoneUpdateAvailable),
                       pending: !model.useRemoteMicrophone ? "未使用遥控器麦克风" : model.microphoneOperationInProgress ? "正在处理…" : model.microphoneUpdateAvailable ? "需要更新" : "未就绪")
                Text("如果还没有可用的回环设备，请安装随应用提供的麦克风组件。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Button(model.microphoneUpdateAvailable ? "更新麦克风组件…" : model.microphoneComponentPresent ? "重新安装麦克风组件…" : "安装麦克风组件…") {
                    model.installMicrophone()
                }.disabled(!model.useRemoteMicrophone || model.microphoneOperationInProgress)
                if model.microphoneOperationInProgress { ProgressView().controlSize(.small) }
            }
            SettingsPanel("选择接收设备", symbol: "waveform") {
                Picker("接收设备", selection: $model.outputUID) {
                    if !model.outputDevices.contains(where: { $0.id == model.outputUID }) {
                        Text("所选设备不可用").tag(model.outputUID)
                    }
                    ForEach(model.outputDevices) { Text($0.name).tag($0.id) }
                }
                Text(VoiceSetupGuidance.selectReceiver).fixedSize(horizontal: false, vertical: true)
                Text(VoiceSetupGuidance.systemDefault).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("刷新设备") { model.refreshDevices(forceReload: true) }
                    Button("系统声音设置") { openSystemSettings("x-apple.systempreferences:com.apple.Sound-Settings.extension?input") }
                }
            }.font(.system(size: 13))
        }
    }

    private var voice: some View {
        VStack(spacing: SettingsStyle.Spacing.groups) {
            SettingsPanel("语音触发方式", symbol: "keyboard") {
                Toggle("使用遥控器麦克风", isOn: $model.useRemoteMicrophone)
                Text(model.useRemoteMicrophone
                     ? "使用遥控器麦克风，并在语音工具中选择 RcHarness 遥控器麦克风。"
                     : "关闭后使用其他麦克风，需在语音工具内做调整。")
                    .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                if model.voiceTapAvailable {
                    Picker("触发方式", selection: Binding(get: { model.voiceMode }, set: { model.voiceMode = $0 })) {
                        Text("按住说话").tag(VoiceTriggerMode.hold)
                        Text("点按开始 / 结束").tag(VoiceTriggerMode.tap)
                    }.pickerStyle(.segmented)
                }
                VoiceShortcutPicker(mode: model.voiceMode, shortcut: Binding(
                    get: { model.voiceMode == .hold ? model.voiceHoldShortcut : model.voiceTapShortcut },
                    set: { if model.voiceMode == .hold { model.voiceHoldShortcut = $0 } else { model.voiceTapShortcut = $0 } }
                ))
                Text(model.voiceMode == .hold ? "在语音工具中，把“按住说话”快捷键设为上方按键。" : "在语音工具中，把“点按开始 / 结束”快捷键设为上方按键。")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Text(model.useRemoteMicrophone ? "点按模式会让遥控器麦克风持续收音，第二次按键结束。" : "目标工具使用其他麦克风，请在语音工具内做调整。")
                    .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsPanel("在输入工具中检查", symbol: "checklist") {
                Text("1. 打开\(Text("输入法").foregroundColor(.red).bold())或听写工具的语音设置。")
                Text(model.useRemoteMicrophone ? "2. 麦克风选择“\(receiverName)”。" : "2. 在语音工具内选择要使用的麦克风。")
                Text("3. 设置相同的快捷键和触发方式。")
                Text("使用 Fn / 地球键时，检查系统键盘设置中该按键的用途，避免同时触发系统动作。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VoiceInputToolSettingsButtons()
                Divider()
                Toggle("我已在目标工具中设置相同的麦克风和快捷键", isOn: $setup.toolConfigured)
                    .toggleStyle(.checkbox)
            }.font(.system(size: 13))
        }
    }

    private var trial: some View {
        VStack(spacing: SettingsStyle.Spacing.groups) {
            SettingsPanel("说一句话，检查整条链路", symbol: "waveform") {
                Text(model.useRemoteMicrophone
                     ? "在目标应用中点击文本输入框，按住遥控器语音键说“用遥控器开始工作”，松开结束。确认文字出现后，返回这里。"
                     : "在目标应用中点击文本输入框，按住遥控器语音键说“用遥控器开始工作”，松开结束。请在语音工具内选择要使用的麦克风。")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Divider()
                status("语音会话已开始", ready: setup.voiceStarted, pending: "等待按下语音键")
                status("收到遥控器音频", ready: !model.useRemoteMicrophone || setup.voiceSamplesReceived,
                       pending: model.useRemoteMicrophone ? "等待遥控器音频" : "由输入法选择的麦克风收音")
                status("语音会话已结束", ready: setup.voiceEnded, pending: "等待松开语音键")
                status("音频输出", ready: readiness.audio && readiness.outputHealthy, pending: model.audioOutputDescription)
                Toggle("已在目标应用中确认语音输入正常", isOn: $setup.transcriptConfirmed)
                    .toggleStyle(.checkbox).disabled(!setup.voiceTestSucceeded)
            }
            SettingsPanel("如果没有出现文字", symbol: "questionmark.circle") {
                Text("返回上一步核对快捷键。也可以发送测试音，在目标语音应用中观察麦克风输入电平。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("发送 1 秒测试音") { model.playTestTone() }
                    .disabled(model.audioBusy || !model.outputDevices.contains { $0.id == model.outputUID })
                Text(VoiceSetupGuidance.checkInputLevel).font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var completion: some View {
        VStack(spacing: SettingsStyle.Spacing.groups) {
            SettingsPanel("准备就绪", symbol: "checkmark.circle") {
                status("系统权限", ready: readiness.permissions)
                status(model.remoteProfile.shortName, ready: readiness.remote)
                status(receiverName, ready: readiness.audio)
                status("语音试用已确认", ready: setup.voiceTestSucceeded && setup.transcriptConfirmed)
            }
            SettingsPanel("接下来可以做什么", symbol: "keyboard") {
                Text("在“按键”中查看默认映射；在 Harness 中为不同应用绑定按键方案；长按确认键可以唤出常用语。")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Text("关闭窗口后，RcHarness 仍在菜单栏运行。需要再次检查时，可从“设置”重新运行向导。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var receiverName: String { model.outputDevices.first { $0.id == model.outputUID }?.name ?? "所选接收设备" }

    private var blockingHint: String? {
        if !readiness.permissions { return "请完成系统权限授权；如已授权，可返回权限步骤刷新状态。" }
        if setup.step.index >= SetupStep.remote.index, !readiness.remote { return "等待当前遥控器的按键和语音连接；可返回连接步骤重新检查。" }
        if setup.step == .remote { return nil }
        if !readiness.audio { return "请检查麦克风组件和接收设备；如有错误，可刷新设备或重新安装组件。" }
        if setup.step == .voice { return nil }
        if !readiness.outputHealthy { return "音频输出失败，请检查接收设备后发送测试音重试。" }
        return "请完成一次语音试用，并确认目标应用已正确收到文字。"
    }

    private func status(_ title: String, ready: Bool, pending: String = "待完成") -> some View {
        HStack(spacing: SettingsStyle.Spacing.controls) {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 12)
            SettingsStatus(title: ready ? "已就绪" : pending, color: ready ? .green : .orange)
        }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.system(size: 13)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

}

/// Future steps remain disabled without dimming their numbers and captions a
/// second time; their neutral colors already distinguish them from progress.
private struct SetupStepButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
    }
}
