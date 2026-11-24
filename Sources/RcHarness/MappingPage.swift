import AppKit
import SwiftUI

enum ActionFilter: String, CaseIterable, Identifiable {
    case all = "全部", basic = "基本按键", system = "系统与媒体", custom = "自定义"
    var id: String { rawValue }
}

struct MappingLayout {
    static let xiaomiLeftInputs: [ControllerInput] = [.dpadUp, .dpadLeft, .buttonB, .home, .menu]
    static let xiaomiRightInputs: [ControllerInput] = [.buttonA, .dpadRight, .dpadDown, .rightShoulder, .leftShoulder, .buttonY]
    // Keep the binding status in a stable slot so changing the binding does not
    // move the status label or the controls that follow it.
    static let profileBindingStatusWidth: CGFloat = 245
    let size: CGSize
    let profile: RemoteProfile
    var compactText = false

    var leftInputs: [ControllerInput] {
        if profile.adapter == .chromecast {
            return [.dpadUp, .dpadLeft, .dpadDown, .buttonB, .home, .youtube, .power]
        }
        return [.power] + Self.xiaomiLeftInputs
    }
    var rightInputs: [ControllerInput] {
        if profile.adapter == .chromecast {
            return [.buttonA, .dpadRight, .rightShoulder, .leftShoulder, .options, .mute, .netflix, .inputSource]
        }
        return [.options] + Self.xiaomiRightInputs
    }
    private var rows: CGFloat { CGFloat(max(leftInputs.count, rightInputs.count)) }

    var cardSpacing: CGFloat { 6 * contentScale }
    var cardHeight: CGFloat { (size.height - cardSpacing * (rows - 1)) / rows }
    var centerColumnWidth: CGFloat { min(240, max(180, size.width * 0.18)) }
    var remoteHeight: CGFloat { min(size.height - 28, (centerColumnWidth - 44) / RemoteArtworkView.artworkAspectRatio(for: profile.artwork)) }
    var remoteWidth: CGFloat { remoteHeight * RemoteArtworkView.artworkAspectRatio(for: profile.artwork) }
    var remoteTop: CGFloat { (size.height - remoteHeight - 28) / 2 }
    // Grow the controls and text together, while keeping large windows readable.
    var contentScale: CGFloat { min(compactText ? 1 : 1.25, max(1, size.height / 468)) * (profile.adapter == .xiaomi ? 1 : 0.88) }
}

@MainActor
struct MappingPage: View {
    @ObservedObject var model: RemoteDashboardModel
    let onRenameProfile: () -> Void

    var body: some View {
        VStack(spacing: SettingsStyle.Spacing.controls) {
            SettingsPanel {
                HStack(spacing: SettingsStyle.Spacing.controls) {
                    Picker("按键方案", selection: Binding(get: { model.selectedProfileID }, set: { model.activateProfile($0) })) {
                        ForEach(model.profiles) { profile in Text(model.profileDisplayName(profile)).tag(Optional(profile.id)) }
                    }
                    .frame(maxWidth: 360)
                    .help("仅显示「\(model.remoteProfile.shortName)」的按键方案")
                    if let id = model.selectedProfileID, id != SavedKeyProfile.defaultID {
                        Button(action: onRenameProfile) { Image(systemName: "pencil") }
                            .buttonStyle(.bordered)
                            .help("重命名当前按键方案")
                    }
                    ProfileBindingStatus(harnesses: model.selectedProfileID.map { model.boundHarnesses(for: $0) } ?? [])
                    Spacer(minLength: 0)
                    Button("管理绑定") { model.page = .harness }
                }
            }
            MappingCanvas(model: model, live: model.live)
        }
    }
}

/// Share the remote diagram and mapping labels with the read-only shortcuts panel.
@MainActor
struct MappingCanvas: View {
    private struct TriggerFocus: Hashable {
        let input: ControllerInput
        let trigger: ButtonTrigger
    }

    @ObservedObject var model: RemoteDashboardModel
    @ObservedObject var live: RemoteLiveStatus
    var readOnly = false
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedTrigger: TriggerFocus?
    @FocusState private var focusedArtworkInput: ControllerInput?
    @State private var hoveredCardInput: ControllerInput?
    @State private var hoveredArtworkInput: ControllerInput?

    private var previewInput: ControllerInput? {
        if !readOnly, model.editorVisible { return model.selectedInput }
        return hoveredArtworkInput ?? hoveredCardInput ?? focusedArtworkInput ?? focusedTrigger?.input
    }

    private var emphasizedInputs: Set<ControllerInput> {
        RemoteArtworkView.highlightedInputs(
            pressed: live.pressedInputs,
            preview: previewInput
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = MappingLayout(size: proxy.size, profile: model.remoteProfile,
                                       compactText: readOnly && proxy.size.width < 820)
            let columnWidth = (proxy.size.width - layout.centerColumnWidth) / 2
            ZStack {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: layout.cardSpacing) {
                        ForEach(layout.leftInputs, id: \.self) { mappingCard($0, layout: layout) }
                    }.frame(width: columnWidth)
                    VStack(spacing: SettingsStyle.Spacing.controls) {
                        LiveRemoteArtwork(
                            live: live,
                            highlightedInput: previewInput,
                            onHoverInput: { input in
                                guard !model.editorVisible else { return }
                                hoveredArtworkInput = input
                            },
                            onSelectInput: readOnly ? nil : { input in
                                clearHover()
                                model.openButtonEditor(input)
                            },
                            focusedInput: $focusedArtworkInput,
                            profile: model.remoteProfile
                        )
                            .frame(width: layout.remoteWidth, height: layout.remoteHeight)
                            .shadow(color: .black.opacity(0.12), radius: 10, x: 3, y: 6)
                        Text(model.remoteProfile.model).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    .frame(width: layout.centerColumnWidth).padding(.top, layout.remoteTop)
                    VStack(spacing: layout.cardSpacing) {
                        ForEach(layout.rightInputs, id: \.self) { mappingCard($0, layout: layout) }
                    }.frame(width: columnWidth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                MappingConnectors(
                    layout: layout,
                    emphasizedInputs: emphasizedInputs,
                    pressedInputs: live.pressedInputs
                )
            }
        }
        .onDisappear(perform: clearHover)
        .onChange(of: focusedTrigger) { _, focus in
            if focus != nil { clearHover() }
        }
        .onChange(of: focusedArtworkInput) { _, focus in
            if focus != nil { clearHover() }
        }
        .onChange(of: model.editorVisible) { _, visible in
            if visible { clearHover() }
        }
    }

    private func clearHover() {
        hoveredCardInput = nil
        hoveredArtworkInput = nil
    }

    private func mappingCard(_ input: ControllerInput, layout: MappingLayout) -> some View {
        let pressed = live.pressedInputs.contains(input)
        let emphasized = emphasizedInputs.contains(input)
        let shape = RoundedRectangle(cornerRadius: SettingsStyle.controlRadius)
        let background = emphasized ? Color.accentColor.opacity(pressed ? 0.17 : 0.09) : SettingsStyle.subtle
        let border = emphasized ? Color.accentColor.opacity(pressed ? 0.82 : 0.5) : Color.primary.opacity(0.07)
        return Group {
            if input == .options { voiceCard(input, layout: layout) }
            else { mappingButton(input, layout: layout) }
        }
        .background(background, in: shape)
        .overlay { shape.strokeBorder(border).allowsHitTesting(false) }
        .onHover { hovering in
            guard !model.editorVisible else { return }
            if hovering { hoveredCardInput = input }
            else if hoveredCardInput == input { hoveredCardInput = nil }
        }
    }

    private var globalButtonScopeLabel: some View {
        Text("全局")
            .font(SettingsStyle.Typography.caption)
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
    }

    private func voiceCard(_ input: ControllerInput, layout: MappingLayout) -> some View {
        let shortcut = model.mappingTitle(model.effectiveMapping[.options])
        let label = VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(input.label, systemImage: "mic").font(.system(size: max(11, 12 * layout.contentScale), weight: .semibold))
                Spacer()
                globalButtonScopeLabel
            }
            Text(shortcut).font(.system(size: max(11, 11 * layout.contentScale))).foregroundStyle(.secondary)
                .lineLimit(readOnly ? 2 : 1)
        }
        .padding(8 * layout.contentScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: layout.cardHeight)
        .contentShape(Rectangle())
        return Group {
            if readOnly {
                label.accessibilityElement(children: .ignore)
            } else {
                Button { model.openButtonEditor(input) } label: { label }
                    .buttonStyle(.plain)
                    .focused($focusedTrigger, equals: TriggerFocus(input: input, trigger: .single))
            }
        }
        .help(shortcut)
        .accessibilityLabel("\(input.label) · 全局")
        .accessibilityValue(shortcut)
    }

    private func mappingButton(_ input: ControllerInput, layout: MappingLayout) -> some View {
        VStack(alignment: .leading, spacing: 2 * layout.contentScale) {
            HStack(spacing: 6) {
                Image(systemName: input.symbol)
                Text(input.label).fontWeight(.semibold)
                Spacer()
                if model.isGlobalInput(input) { globalButtonScopeLabel }
                LivePressIndicator(live: model.live, input: input)
            }
            .font(.system(size: max(11, 11 * layout.contentScale)))
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                ForEach(input.supportedTriggers) { trigger in
                    let mapping = model.effectiveMapping[input, trigger]
                    let configured = mapping.action != .disabled
                    let label = VStack(alignment: .leading, spacing: 0) {
                        Text(trigger.title)
                            .font(.system(size: max(10, 9 * layout.contentScale)))
                            .foregroundStyle(SettingsStyle.mappingTriggerLabel(in: colorScheme))
                            .lineLimit(1)
                        Text(configured ? cardTitle(mapping) : "– 未设置")
                            .font(.system(size: max(11, 11 * layout.contentScale),
                                          weight: configured ? .semibold : .regular))
                            .foregroundStyle(configured ? .primary : SettingsStyle.mappingTriggerLabel(in: colorScheme))
                            .minimumScaleFactor(0.92)
                            .lineLimit(readOnly ? 2 : 1)
                        if let detail = cardDetail(mapping.action) {
                            Text(detail)
                                .font(.system(size: max(10, 9 * layout.contentScale),
                                              design: mapping.action == .rapidDelete ? .default : .monospaced))
                                .foregroundStyle(SettingsStyle.mappingTriggerLabel(in: colorScheme))
                                .lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                    Group {
                        if readOnly {
                            label
                                .background {
                                    MappingTriggerBackground(isConfigured: configured)
                                }
                                .accessibilityElement(children: .ignore)
                        } else {
                            Button { model.openButtonEditor(input, trigger: trigger) } label: { label }
                                .buttonStyle(MappingTriggerButtonStyle(isConfigured: configured))
                                .focused($focusedTrigger, equals: TriggerFocus(input: input, trigger: trigger))
                        }
                    }
                    .overlay(alignment: .leading) {
                        if trigger != .single {
                            Rectangle()
                                .fill(Color.primary.opacity(0.12))
                                .frame(width: 1)
                                .padding(.vertical, 3)
                                .allowsHitTesting(false)
                        }
                    }
                    .help("\(input.label) · \(trigger.title)：\(model.mappingTitle(mapping))")
                    .accessibilityLabel("\(input.label)\(trigger.title)")
                    .accessibilityValue(model.mappingTitle(mapping))
                }
            }
        }
        .padding(.horizontal, 8 * layout.contentScale)
        .padding(.vertical, 3 * layout.contentScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: layout.cardHeight)
    }

    private func cardTitle(_ mapping: ButtonMapping) -> String {
        switch mapping.action {
        case .openHarnessSwitcher: "Harness 列表"
        case .showDesktop: "显示桌面"
        case .switchToNativeMode: "停止映射"
        case .toggleMouseMode: "鼠标模式"
        case .rapidDelete: "快速删除"
        case .showAllWindows: "查看所有窗口"
        case .switchApplications: "切换应用"
        case .macro:
            if let macro = model.macros.first(where: { $0.id.uuidString == mapping.referenceID }) {
                DefaultMacros.cardTitle(for: macro)
            } else {
                model.mappingTitle(mapping)
            }
        default: model.mappingTitle(mapping)
        }
    }

    private func cardDetail(_ action: RemoteAction) -> String? {
        switch action {
        case .rapidDelete: "按住连续退格"
        case .showAllWindows: "⌃ ↑"
        case .switchApplications: "⌘ Tab"
        default: nil
        }
    }
}

private struct MappingTriggerBackground: View {
    let isConfigured: Bool
    var interactionOpacity: Double = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let baseOpacity = isConfigured ? (colorScheme == .dark ? 0.10 : 0.08) : 0
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(baseOpacity + interactionOpacity))
            .padding(.horizontal, 2)
            .allowsHitTesting(false)
    }
}

private struct MappingTriggerButtonStyle: ButtonStyle {
    let isConfigured: Bool

    func makeBody(configuration: Configuration) -> some View {
        TriggerButton(configuration: configuration, isConfigured: isConfigured)
    }

    private struct TriggerButton: View {
        let configuration: ButtonStyleConfiguration
        let isConfigured: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background {
                    MappingTriggerBackground(isConfigured: isConfigured,
                        interactionOpacity: configuration.isPressed ? 0.06 : isHovered ? 0.03 : 0)
                }
                .onHover { isHovered = $0 }
        }
    }
}

private struct ProfileBindingStatus: View {
    let harnesses: [HarnessConfiguration]

    var body: some View {
        HStack(spacing: SettingsStyle.Spacing.inline) {
            if harnesses.isEmpty {
                bindingIcon(for: nil)
                Text("未绑定 Harness").foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    boundIcons.fixedSize(horizontal: true, vertical: false)
                    ScrollView(.horizontal) { boundIcons }
                        .frame(height: 26)
                }
                Text("已绑定")
                    .fontWeight(.medium)
                    .fixedSize()
            }
        }
        .font(SettingsStyle.Typography.body)
        .frame(width: MappingLayout.profileBindingStatusWidth, height: 35, alignment: .leading)
        .help(statusDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusDescription)
    }

    private var statusDescription: String {
        harnesses.isEmpty ? "未绑定 Harness" : "已绑定 \(harnesses.count) 个 Harness：\(harnesses.map(\.name).joined(separator: "、"))"
    }

    private var boundIcons: some View {
        HStack(spacing: -4) {
            ForEach(harnesses) { harness in
                bindingIcon(for: harness)
            }
        }
    }

    private func bindingIcon(for harness: HarnessConfiguration?) -> some View {
        Group {
            if let url = harness?.installedApplicationURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().scaledToFit().padding(2)
            } else {
                HarnessIcon(size: 14).foregroundStyle(harness == nil ? Color.secondary : Color.accentColor)
            }
        }
        .frame(width: 20, height: 20)
        .background(Color(nsColor: .controlBackgroundColor), in: Circle())
        .overlay { Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1) }
    }
}

struct MappingFooter: View {
    @ObservedObject var model: RemoteDashboardModel

    var body: some View {
        HStack(spacing: SettingsStyle.Spacing.groups) {
            Label(model.isConnected ? "按键功能已连接" : "等待遥控器连接", systemImage: "keyboard")
                .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
            Divider().frame(height: 30)
            Button("设置全局按键") { model.page = .about }
            Spacer()
            Button("常用语") { model.page = .phrases }
                .help("管理常用语和方向键分配")
            Button("恢复当前方案") { SettingsDialogs.resetMapping(model) }
        }
        .padding(.horizontal, SettingsStyle.pagePadding).padding(.vertical, SettingsStyle.Spacing.groups)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

@MainActor
struct MappingEditorSheet: View {
    @ObservedObject var model: RemoteDashboardModel
    @Binding var actionFilter: ActionFilter

    @State private var draft: MappingEditorDraft
    @State private var keyboardShortcut: Binding<RecordedShortcut?>?

    init(model: RemoteDashboardModel, actionFilter: Binding<ActionFilter>) {
        self.model = model
        _actionFilter = actionFilter
        _draft = State(initialValue: MappingEditorDraft(model: model))
    }

    private var editedMapping: Binding<ButtonMapping> {
        let trigger = draft.trigger
        return Binding(get: { draft.mapping[draft.input, trigger] },
                       set: { draft.mapping[draft.input, trigger] = $0 })
    }

    var body: some View {
        Group {
            if let shortcut = keyboardShortcut {
                ShortcutKeyboardPicker(shortcut: shortcut.wrappedValue, onCancel: { keyboardShortcut = nil }) { selection in
                    shortcut.wrappedValue = selection
                    keyboardShortcut = nil
                }
            } else {
                editor
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onExitCommand {
            if keyboardShortcut != nil { keyboardShortcut = nil }
            else { model.editorVisible = false }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: SettingsStyle.Spacing.controls) {
                Image(systemName: draft.input.symbol)
                    .font(.system(size: 22)).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(draft.input.label) · \(draft.input == .options ? "语音模式" : draft.trigger.title)")
                        .font(SettingsStyle.Typography.dialogTitle)
                    Text(draft.input == .options ? "固定语音触发 · 对当前遥控器的所有方案和 Harness 生效" :
                         draft.isGlobal ? "全局按键 · 对当前遥控器的所有方案和 Harness 生效" : "按键方案：\(draft.mappingName)")
                        .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsStyle.pagePadding)
            .padding(.vertical, draft.input == .options ? 16 : SettingsStyle.pagePadding)
            Divider()
            if draft.input == .options {
                editorContent
            } else {
                ScrollView {
                    editorContent
                }
                .scrollIndicators(.hidden)
            }
            Divider()
            HStack {
                if draft.hasIncompleteShortcut {
                    Text("请为所选触发方式设置快捷键。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { model.editorVisible = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("mapping-editor-cancel")
                Button("保存") {
                    if model.saveMappingEditor(draft) { model.editorVisible = false }
                }
                    .accessibilityIdentifier("mapping-editor-save")
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(draft.hasIncompleteShortcut)
            }
            .padding(.horizontal, SettingsStyle.pagePadding)
            .padding(.vertical, draft.input == .options ? 12 : 16)
        }
        .frame(width: 560, height: editorHeight)
    }

    @ViewBuilder
    private var editorContent: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.groups) {
                    Text(draft.input == .options ? "两种模式分别绑定快捷键，请与语音工具的设置保持一致。" : "选择这个按键要执行的操作")
                        .font(.callout).foregroundStyle(.secondary)
                    if draft.input == .options {
                        HStack(alignment: .center, spacing: SettingsStyle.Spacing.controls) {
                            Toggle("使用遥控器麦克风", isOn: $model.useRemoteMicrophone)
                                .toggleStyle(.switch)
                            Text(model.useRemoteMicrophone
                                 ? "开启后使用遥控器麦克风，语音工具请选择 RcHarness 遥控器麦克风。"
                                 : "关闭后使用其他麦克风，需在语音工具内做调整。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        voiceModeCard(.hold, title: "长按模式", detail: "按住说话，松手结束。尾音排空后释放快捷键。", shortcut: $draft.voiceHoldShortcut)
                        voiceModeCard(.tap, title: "点按模式", detail: "按一次开始说话，再按语音键结束，也可按其他遥控器按键结束。", shortcut: $draft.voiceTapShortcut)
                        if !model.voiceTapAvailable {
                            Text("使用遥控器麦克风时，\(model.remoteProfile.shortName) 仅支持长按模式。关闭后可使用点按模式。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("点按模式需与输入法的点按快捷键一致。首次使用请确认松手后仍能收音；不兼容时可切回长按模式。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        if draft.input.supportedTriggers.count > 1 {
                            MappingEditorField("触发方式") {
                                Picker("触发方式", selection: $draft.trigger) {
                                    ForEach(draft.input.supportedTriggers) { trigger in Text(trigger.title).tag(trigger) }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                        MappingEditorField("动作分类") {
                            Picker("动作分类", selection: $actionFilter) {
                                ForEach(ActionFilter.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        ActionMappingEditor(value: editedMapping, model: model, filter: actionFilter,
                                            onChooseKeyboard: { keyboardShortcut = $0 })
                            .id(draft.trigger)
                    }
                }
            .padding(.horizontal, SettingsStyle.pagePadding)
            .padding(.vertical, draft.input == .options ? 16 : SettingsStyle.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editorHeight: CGFloat {
        if draft.input == .options { return 560 }
        return editedMapping.wrappedValue.action == .macro ? 460 : 420
    }

    private func voiceModeCard(_ mode: VoiceTriggerMode, title: String, detail: String, shortcut: Binding<RecordedShortcut>) -> some View {
        let unavailable = mode == .tap && !model.voiceTapAvailable
        return VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
            HStack {
                Button { draft.voiceMode = mode } label: {
                    Label(title, systemImage: draft.voiceMode == mode ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(unavailable)
                Spacer()
                if unavailable { Text("此遥控器不可用").font(.caption).foregroundStyle(.secondary) }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            VoiceShortcutPicker(mode: mode, shortcut: shortcut)
            Text(mode == .hold ? "选择一个按键。" : "选择一个按键，或两个不同按键的组合。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
    }
}

private struct MappingConnectors: View {
    @Environment(\.colorScheme) private var colorScheme
    let layout: MappingLayout
    let emphasizedInputs: Set<ControllerInput>
    let pressedInputs: Set<ControllerInput>

    var body: some View {
        Canvas { context, size in
            let column = (size.width - layout.centerColumnWidth) / 2
            let remoteOrigin = CGPoint(
                x: column + (layout.centerColumnWidth - layout.remoteWidth) / 2,
                y: layout.remoteTop
            )
            let remoteBounds = CGRect(origin: remoteOrigin, size: CGSize(
                width: layout.remoteWidth, height: layout.remoteHeight
            ))
            var darkControls = Path()
            if layout.profile.adapter == .xiaomi {
                let navigation = RemoteArtworkView.markerPositions(for: layout.profile.artwork)[.buttonA]!
                darkControls.addEllipse(in: CGRect(
                    x: remoteOrigin.x + layout.remoteWidth * (navigation.x - 0.42),
                    y: remoteOrigin.y + layout.remoteHeight * (navigation.y - 0.105),
                    width: layout.remoteWidth * 0.84,
                    height: layout.remoteHeight * 0.21
                ))
                for input: ControllerInput in [.buttonB, .home, .menu, .rightShoulder, .leftShoulder, .buttonY] {
                    darkControls.addPath(RemoteArtworkView.controlOutline(for: input, in: remoteBounds, artwork: layout.profile.artwork))
                }
                if layout.profile.artwork == .xiaomi2 {
                    for input: ControllerInput in [.power, .options] {
                        darkControls.addPath(RemoteArtworkView.controlOutline(for: input, in: remoteBounds, artwork: layout.profile.artwork))
                    }
                }
            } else {
                let darkInput: ControllerInput = layout.profile.adapter == .chromecast ? .options : .home
                darkControls.addPath(RemoteArtworkView.controlOutline(for: darkInput, in: remoteBounds, artwork: layout.profile.artwork))
            }
            let connections: [(input: ControllerInput, startY: CGFloat, isLeft: Bool)] = layout.leftInputs.enumerated().map { index, input in
                (
                    input,
                    layout.cardHeight / 2
                        + CGFloat(index) * (layout.cardHeight + layout.cardSpacing),
                    true
                )
            } + layout.rightInputs.enumerated().map { index, input in
                (
                    input,
                    layout.cardHeight / 2
                        + CGFloat(index) * (layout.cardHeight + layout.cardSpacing),
                    false
                )
            }

            for connection in connections {
                let input = connection.input
                guard let marker = RemoteArtworkView.connectorPositions(for: layout.profile.artwork)[input] else { continue }
                let start = CGPoint(
                    x: connection.isLeft ? column - 3 : column + layout.centerColumnWidth + 3,
                    y: connection.startY
                )
                let end = CGPoint(
                    x: remoteOrigin.x + marker.x * layout.remoteWidth,
                    y: remoteOrigin.y + marker.y * layout.remoteHeight
                )
                let active = emphasizedInputs.contains(input)
                let lineWidth: CGFloat = pressedInputs.contains(input) ? 2 : (active ? 1.5 : 1)
                let direction: CGFloat = connection.isLeft ? 1 : -1
                let edge = CGPoint(
                    x: connection.isLeft ? remoteBounds.minX : remoteBounds.maxX,
                    y: end.y
                )
                let laneX = edge.x - direction * 12
                // Change height in the gutter, then approach the button with a
                // short horizontal leader instead of sweeping across the body.
                var guide = Path()
                guide.move(to: start)
                guide.addCurve(
                    to: edge,
                    control1: CGPoint(x: laneX, y: start.y),
                    control2: CGPoint(x: laneX, y: edge.y)
                )
                context.stroke(
                    guide,
                    with: .color(active ? Color.accentColor : Color.primary.opacity(colorScheme == .dark ? 0.26 : 0.17)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                var leader = Path()
                leader.move(to: edge)
                leader.addLine(to: end)
                // A small open arrow lands inside the target button, away
                // from its symbol. Every connection has a definite endpoint.
                let arrowLength: CGFloat = active ? 4 : 3.5
                leader.move(to: CGPoint(x: end.x - direction * arrowLength, y: end.y - 2.5))
                leader.addLine(to: end)
                leader.addLine(to: CGPoint(x: end.x - direction * arrowLength, y: end.y + 2.5))
                context.stroke(
                    leader,
                    with: .color(active ? Color.accentColor : .black.opacity(0.25)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
                var buttonContext = context
                buttonContext.clip(to: darkControls)
                buttonContext.stroke(
                    leader,
                    with: .color(active ? Color.accentColor : .white.opacity(0.45)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
        }.allowsHitTesting(false)
    }
}

/// One label column shared by the sheet and its action-specific fields.
@MainActor
struct MappingEditorField<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: SettingsStyle.Spacing.inline) {
            Text(title)
                .frame(width: 52, alignment: .leading)
                .accessibilityHidden(true)
            content
                .labelsHidden()
                .frame(maxWidth: .infinity)
        }
        .font(SettingsStyle.Typography.body)
    }
}

struct ActionMappingEditor: View {
    @Binding var value: ButtonMapping
    @ObservedObject var model: RemoteDashboardModel
    var filter: ActionFilter
    var parentMacroID: UUID? = nil
    let onChooseKeyboard: (Binding<RecordedShortcut?>) -> Void
    @State private var selectedMacroTagIDs: Set<String> = []
    private var actions: [RemoteAction] {
        let basic: [RemoteAction] = [.enter, .backspace, .rapidDelete, .escape, .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .copy, .paste, .browserBack, .browserForward]
        let system: [RemoteAction] = [.volumeUp, .volumeDown, .mute, .playPause, .showAllWindows] + RemoteAction.harnessFocusActions
            + (SystemDesktopController.shared.isSupported ? [.showDesktop] : [])
            + [.scrollUp, .scrollDown]
            + (parentMacroID == nil ? RemoteAction.interactiveActions : [])
        let custom: [RemoteAction] = [.recordedShortcut, .openApplication, .phrase, .macro]
        let filtered: [RemoteAction]
        switch filter {
        case .basic: filtered = basic
        case .system: filtered = system
        case .custom: filtered = custom
        case .all: filtered = custom + basic + system
        }
        var ordered = [.disabled] + custom + basic + system
        let canShowDesktop = SystemDesktopController.shared.isSupported
        if !ordered.contains(value.action), value.action != .showDesktop || canShowDesktop {
            ordered.append(value.action)
        }
        return ordered.filter { $0 == .disabled || $0 == value.action || filtered.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.controls) {
            MappingEditorField("执行动作") {
                SettingsSingleSelectionPicker(selection: Binding(get: { value.action }, set: { value = ButtonMapping(action: $0) }),
                    options: actions.map {
                        SettingsSelectionOption(value: $0, title: $0.label)
                    }, accessibilityLabel: "执行动作", identifier: "mapping-action-picker")
            }
            if value.action == .rapidDelete {
                Text("按住连续退格，松开即停止。可绑定到长按手势，保留单击的原有动作；双击或组合动作中执行一次退格。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if value.action == .switchToNativeMode {
                Text("关闭遥控器映射，恢复原生按键。返回映射模式时，请在主面板开启「启用遥控器映射」，或点击菜单栏的模式项。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if value.action == .toggleMouseMode {
                Text("触发同一手势可进入或退出鼠标模式。绑定了切换手势的按键在两种模式中都执行其按键映射。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if value.action == .showDesktop && SystemDesktopController.shared.isSupported {
                Text("通过 Dock 系统通知在显示桌面和恢复窗口之间切换。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if value.action == .switchApplications {
                Text("打开 macOS 应用切换器。同一按键每按一次切换一项，按住连续切换；停止操作 2 秒后自动进入，返回或主页取消。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if value.action == .openHarnessSwitcher {
                Text("展示已启用且正在运行的 Harness。同一按键每按一次切换一项，按住连续切换；停止操作 2 秒后自动进入。左右键也可选择，确认 OK 立即进入，返回或主页取消。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if value.action == .openPhrases {
                Text("唤出独立常用语浮层。上下左右和确认键各对应一条常用语，单击输入内容1，双击输入内容2；返回或主页关闭。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if value.action == .showShortcuts {
                Text("浮层显示当前生效方案的按键配置。再次触发同一手势即可关闭。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if value.action == .recordedShortcut {
                ShortcutBindingEditor(shortcut: Binding(get: { value.shortcut }, set: { shortcut in
                    if value.action == .recordedShortcut { value.shortcut = shortcut }
                }), onChooseKeyboard: onChooseKeyboard)
            }
            if value.action == .openApplication {
                HStack {
                    Text(value.applicationPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "尚未选择 App")
                        .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
                    Spacer()
                    Button("选择 App…") { if let url = FilePanels.chooseApplication() { value.applicationPath = url.path } }
                }
            }
            if value.action == .phrase {
                MappingEditorField("常用语") {
                    SettingsSingleSelectionPicker(selection: Binding(get: { value.referenceID ?? "" }, set: { value.referenceID = $0 }),
                        options: [SettingsSelectionOption(value: "", title: "选择常用语")] + model.phrases.map {
                            SettingsSelectionOption(value: $0.id.uuidString, title: $0.title)
                        }, accessibilityLabel: "常用语", identifier: "mapping-phrase-picker",
                        missingSelectionTitle: "已删除的常用语")
                }
                if let referenceID = value.referenceID, !referenceID.isEmpty,
                   !model.phrases.contains(where: { $0.id.uuidString == referenceID }) {
                    Text("引用的常用语已删除，请重新选择。")
                        .font(.caption).foregroundStyle(.red)
                }
                Button("管理常用语") { model.page = .phrases }.buttonStyle(.link).font(.caption)
            }
            if value.action == .macro {
                MacroReferencePicker(referenceID: $value.referenceID, tagIDs: $selectedMacroTagIDs,
                                     model: model, parentMacroID: parentMacroID)
            }
        }
    }
}
