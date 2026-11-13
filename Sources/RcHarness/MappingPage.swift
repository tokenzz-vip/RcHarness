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
    var contentScale: CGFloat { min(1.25, max(1, size.height / 468)) * (profile.adapter == .xiaomi ? 1 : 0.88) }
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
                    Spacer(minLength: 0)
                    ProfileBindingStatus(harnesses: model.selectedProfileID.map { model.boundHarnesses(for: $0) } ?? [])
                    Button("管理绑定") { model.page = .harness }
                }
            }
            MappingCanvas(model: model, live: model.live)
        }
    }
}

/// Keep live input observation within the mapping canvas, away from the
/// profile controls and the rest of the dashboard.
@MainActor
private struct MappingCanvas: View {
    @ObservedObject var model: RemoteDashboardModel
    @ObservedObject var live: RemoteLiveStatus
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredCardInput: ControllerInput?
    @State private var hoveredArtworkInput: ControllerInput?

    private var emphasizedInputs: Set<ControllerInput> {
        RemoteArtworkView.highlightedInputs(
            pressed: live.pressedInputs,
            preview: hoveredArtworkInput ?? hoveredCardInput ?? model.selectedInput
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = MappingLayout(size: proxy.size, profile: model.remoteProfile)
            let columnWidth = (proxy.size.width - layout.centerColumnWidth) / 2
            ZStack {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: layout.cardSpacing) {
                        ForEach(layout.leftInputs, id: \.self) { mappingCard($0, layout: layout) }
                    }.frame(width: columnWidth)
                    VStack(spacing: SettingsStyle.Spacing.controls) {
                        LiveRemoteArtwork(
                            live: live,
                            highlightedInput: hoveredArtworkInput ?? hoveredCardInput ?? model.selectedInput,
                            onHoverInput: { input in
                                guard !model.editorVisible else { return }
                                hoveredArtworkInput = input
                            },
                            onSelectInput: { input in
                                clearHover()
                                model.openButtonEditor(input)
                            },
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
                    selectedInputs: emphasizedInputs
                )
            }
        }
        .onDisappear(perform: clearHover)
        .onChange(of: model.editorVisible) { _, visible in
            if visible { clearHover() }
        }
    }

    private func clearHover() {
        hoveredCardInput = nil
        hoveredArtworkInput = nil
    }

    private func mappingCard(_ input: ControllerInput, layout: MappingLayout) -> some View {
        Group {
            if input == .options { voiceCard(input, layout: layout) }
            else { mappingButton(input, layout: layout) }
        }
        .onHover { hovering in
            guard !model.editorVisible else { return }
            if hovering { hoveredCardInput = input }
            else if hoveredCardInput == input { hoveredCardInput = nil }
        }
    }

    private func globalButtonBadge(scale: CGFloat) -> some View {
        Text("全局按键")
            .font(.system(size: 10 * scale, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.10), in: Capsule())
    }

    private func voiceCard(_ input: ControllerInput, layout: MappingLayout) -> some View {
        Button {
            model.openButtonEditor(input)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(input.label, systemImage: "mic").font(.system(size: max(11, 12 * layout.contentScale), weight: .semibold))
                    Spacer()
                    globalButtonBadge(scale: layout.contentScale)
                }
                Text(model.mappingTitle(model.effectiveMapping[.options])).font(.system(size: max(11, 11 * layout.contentScale))).foregroundStyle(.secondary).lineLimit(1)
            }.padding(8 * layout.contentScale).frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: layout.cardHeight)
                .background(emphasizedInputs.contains(input) ? Color.accentColor.opacity(0.09) : SettingsStyle.subtle,
                            in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsStyle.controlRadius)
                        .strokeBorder(emphasizedInputs.contains(input) ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.06))
                }
        }.buttonStyle(.plain)
    }

    private func mappingButton(_ input: ControllerInput, layout: MappingLayout) -> some View {
        let selected = emphasizedInputs.contains(input)
        return VStack(alignment: .leading, spacing: 4 * layout.contentScale) {
            HStack(spacing: 6) {
                Image(systemName: input.symbol)
                Text(input.label).fontWeight(.semibold)
                Spacer()
                if model.isGlobalInput(input) { globalButtonBadge(scale: layout.contentScale) }
                LivePressIndicator(live: model.live, input: input)
            }.font(.system(size: max(11, 11 * layout.contentScale)))
            HStack(spacing: 3) {
                ForEach(input.supportedTriggers) { trigger in
                    let mapping = model.effectiveMapping[input, trigger]
                    let configured = mapping.action != .disabled
                    Button {
                        model.openButtonEditor(input, trigger: trigger)
                    } label: {
                        VStack(spacing: 2) {
                            Text(trigger.title).foregroundStyle(SettingsStyle.mappingTriggerLabel(in: colorScheme))
                            Text(cardTitle(mapping))
                                .fontWeight(configured ? .medium : .regular)
                                .foregroundStyle(configured ? .primary : .secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .font(.system(size: max(11, 10 * layout.contentScale)))
                        .frame(maxWidth: .infinity, minHeight: 28 * layout.contentScale)
                        .padding(.horizontal, 2).padding(.vertical, 2)
                        .background(SettingsStyle.mappingTriggerBackground(in: colorScheme, configured: configured), in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(input.label) · \(trigger.title)：\(model.mappingTitle(model.effectiveMapping[input, trigger]))")
                    .accessibilityLabel("\(input.label)\(trigger.title)")
                    .accessibilityValue(model.mappingTitle(mapping))
                }
            }
        }
        .padding(.horizontal, 8 * layout.contentScale)
        .padding(.vertical, 4 * layout.contentScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: layout.cardHeight)
        .background(selected ? Color.accentColor.opacity(0.09) : SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
        .overlay { RoundedRectangle(cornerRadius: SettingsStyle.controlRadius).strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.07)) }
    }

    private func cardTitle(_ mapping: ButtonMapping) -> String {
        switch mapping.action {
        case .openHarnessSwitcher: "Harness 列表"
        case .screenshot: "区域截图 ⌘⇧4"
        case .switchToNativeMode: "原生模式"
        case .macro:
            if let macro = model.macros.first(where: { $0.id.uuidString == mapping.referenceID }) {
                DefaultMacros.cardTitle(for: macro)
            } else {
                model.mappingTitle(mapping)
            }
        default: model.mappingTitle(mapping)
        }
    }
}

private struct ProfileBindingStatus: View {
    let harnesses: [HarnessConfiguration]

    var body: some View {
        Group {
            if harnesses.isEmpty {
                HStack(spacing: 6) {
                    HarnessIcon(size: 14)
                        .frame(width: 20, height: 20)
                        .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                        .overlay { Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1) }
                    Text("未绑定 Harness").font(SettingsStyle.Typography.caption)
                }
                .foregroundStyle(.secondary)
            } else {
                boundIcons
            }
        }
        .frame(width: MappingLayout.profileBindingStatusWidth, height: 35)
        .help(statusDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusDescription)
    }

    private var statusDescription: String {
        harnesses.isEmpty ? "未绑定 Harness" : "已绑定 \(harnesses.count) 个 Harness：\(harnesses.map(\.name).joined(separator: "、"))"
    }

    private var boundIcons: some View {
        HStack(spacing: -4) {
            ForEach(Array(harnesses.prefix(5))) { harness in
                icon(for: harness)
                    .frame(width: 20, height: 20)
                    .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                    .overlay { Circle().stroke(Color.accentColor.opacity(0.32), lineWidth: 1) }
                    .zIndex(Double(5 - (harnesses.firstIndex(where: { $0.id == harness.id }) ?? 0)))
            }
            if harnesses.count > 5 {
                Text("+\(harnesses.count - 5)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(Color.accentColor.opacity(0.10), in: Capsule())
                    .padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private func icon(for harness: HarnessConfiguration) -> some View {
        if let url = harness.installedApplicationURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().scaledToFit().padding(2)
        } else {
            HarnessIcon(size: 14).foregroundStyle(Color.accentColor)
        }
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

struct MappingEditorSheet: View {
    @ObservedObject var model: RemoteDashboardModel
    @Binding var actionFilter: ActionFilter

    private var editedMapping: Binding<ButtonMapping> {
        Binding(get: { model.effectiveMapping[model.selectedInput, model.selectedTrigger] },
                set: { model.update($0, for: model.selectedInput, trigger: model.selectedTrigger) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SettingsStyle.Spacing.controls) {
                Image(systemName: model.selectedInput.symbol)
                    .font(.system(size: 22)).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(model.selectedInput.label) · \(model.selectedInput == .options ? "语音模式" : model.selectedTrigger.title)")
                        .font(SettingsStyle.Typography.dialogTitle)
                    Text(model.selectedInput == .options ? "固定语音触发 · 对当前遥控器的所有方案和 Harness 生效" :
                         model.isGlobalInput(model.selectedInput) ? "全局按键 · 对当前遥控器的所有方案和 Harness 生效" : "按键方案：\(model.activeMappingName)")
                        .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(SettingsStyle.pagePadding)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsStyle.Spacing.groups) {
                    Text(model.selectedInput == .options ? "两种模式分别绑定快捷键，请与语音工具的设置保持一致。" : "选择这个按键要执行的操作")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.selectedInput == .options {
                        voiceModeCard(.hold, title: "长按模式", detail: "按住说话，松手结束。尾音排空后释放快捷键。", shortcut: $model.voiceHoldShortcut)
                        voiceModeCard(.tap, title: "点按模式", detail: "按一次开始说话，再按语音键结束，也可按其他遥控器按键结束。", shortcut: $model.voiceTapShortcut)
                        if !model.remoteProfile.supportsVoiceTap {
                            Text("\(model.remoteProfile.shortName) 松手后会停止收音，仅可启用长按模式。点按快捷键仍可配置。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("点按模式需与输入法的点按快捷键一致。首次使用请确认松手后仍能收音；不兼容时可切回长按模式。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        if model.selectedInput.supportedTriggers.count > 1 {
                            MappingEditorField("触发方式") {
                                Picker("触发方式", selection: $model.selectedTrigger) {
                                    ForEach(model.selectedInput.supportedTriggers) { trigger in Text(trigger.title).tag(trigger) }
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
                        ActionMappingEditor(value: editedMapping, model: model, filter: actionFilter)
                            .id(model.selectedTrigger)
                    }
                }
                .padding(SettingsStyle.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("更改会自动保存").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { model.editorVisible = false }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, SettingsStyle.pagePadding).padding(.vertical, 16)
        }
        .frame(width: 560, height: model.selectedInput == .options ? 560 : editedMapping.wrappedValue.action == .macro ? 460 : 420)
        .background(Color(nsColor: .controlBackgroundColor))
        .onExitCommand { model.editorVisible = false }
    }

    private func voiceModeCard(_ mode: VoiceTriggerMode, title: String, detail: String, shortcut: Binding<RecordedShortcut>) -> some View {
        let unavailable = mode == .tap && !model.remoteProfile.supportsVoiceTap
        return VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
            HStack {
                Button { model.voiceMode = mode } label: {
                    Label(title, systemImage: model.voiceMode == mode ? "largecircle.fill.circle" : "circle")
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
        .padding(SettingsStyle.controlPadding)
        .background(SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
    }
}

private struct MappingConnectors: View {
    let layout: MappingLayout
    let selectedInputs: Set<ControllerInput>

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
                let active = selectedInputs.contains(input)
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
                    with: .color(active ? Color.accentColor : Color.primary.opacity(0.32)),
                    style: StrokeStyle(lineWidth: active ? 1.5 : 1, lineCap: .round)
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
                    with: .color(active ? Color.accentColor : .black.opacity(0.46)),
                    style: StrokeStyle(lineWidth: active ? 1.5 : 1, lineCap: .round, lineJoin: .round)
                )
                var buttonContext = context
                buttonContext.clip(to: darkControls)
                buttonContext.stroke(
                    leader,
                    with: .color(active ? Color.accentColor : .white.opacity(0.72)),
                    style: StrokeStyle(lineWidth: active ? 1.5 : 1, lineCap: .round, lineJoin: .round)
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
    @State private var capturing = false
    @State private var selectedMacroTagIDs: Set<String> = []
    private var actions: [RemoteAction] {
        let basic: [RemoteAction] = [.enter, .backspace, .rapidDelete, .escape, .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .copy, .paste, .browserBack, .browserForward]
        let system: [RemoteAction] = [.volumeUp, .volumeDown, .mute, .playPause, .screenshot, .showAllWindows, .mouseLeft, .mouseRight, .pointerUp, .pointerDown, .pointerLeft, .pointerRight, .scrollUp, .scrollDown] + (parentMacroID == nil ? [.switchToNativeMode, .switchApplications, .openHarnessSwitcher, .openPhrases] : [])
        let custom: [RemoteAction] = [.recordedShortcut, .openApplication, .phrase, .macro]
        let filtered: [RemoteAction]
        switch filter {
        case .basic: filtered = basic
        case .system: filtered = system
        case .custom: filtered = custom
        case .all: filtered = custom + basic + system
        }
        var ordered = [.disabled] + custom + basic + system
        if !ordered.contains(value.action) { ordered.append(value.action) }
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
            if value.action == .recordedShortcut {
                ShortcutBindingEditor(shortcut: $value.shortcut, capturing: $capturing)
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
