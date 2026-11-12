import SwiftUI

@MainActor
struct PhrasesPage: View {
    @ObservedObject var model: RemoteDashboardModel
    @State private var selectedPhraseID: UUID?
    @State private var assignmentInput: ControllerInput?

    init(model: RemoteDashboardModel) {
        self.model = model
        _selectedPhraseID = State(initialValue: model.orderedPhrases.first?.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsStyle.Spacing.groups) {
            assignmentPanel.frame(width: 252)
            phraseListPanel.frame(width: 232)
            phraseEditorPanel.frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.phrases.map(\.id)) { _, _ in ensureSelection() }
    }

    private var assignmentPanel: some View {
        SettingsPanel("按键分配", symbol: "gamecontroller") {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: SettingsStyle.Spacing.groups) {
                    Text("把常用语放到遥控器的五个输入位置。")
                        .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: SettingsStyle.Spacing.inline) {
                        Image(systemName: "circle.grid.2x2.fill")
                        Text("\(boundPhraseCount) / \(PhraseAssignments.inputs.count) 个位置已绑定")
                            .monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .font(SettingsStyle.Typography.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(SettingsStyle.compactControlPadding)
                    .background(SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
                }
                Spacer(minLength: 24)
                PhrasePadView(title: assignmentTitle, isAssigned: { input in
                    model.phraseAssignments[input] != nil
                }, selectedInput: assignmentInput) { input in
                    assignmentInput = input
                }
                .popover(isPresented: Binding(get: { assignmentInput != nil }, set: { if !$0 { assignmentInput = nil } }),
                         attachmentAnchor: .point(PhrasePadLayout.anchor(for: assignmentInput ?? .dpadUp)),
                         arrowEdge: .trailing) {
                    if let input = assignmentInput {
                        PhraseAssignmentPicker(input: input, phrases: model.orderedPhrases,
                                               selection: model.phraseAssignments[input]) { id in
                            model.phraseAssignments[input] = id
                            assignmentInput = nil
                        }
                        .id(input)
                    }
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 24)
                VStack(alignment: .leading, spacing: SettingsStyle.Spacing.controls) {
                    instructionRow("1.circle", title: "单击", detail: "输入内容 1")
                    instructionRow("2.circle", title: "双击", detail: "输入内容 2")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SettingsStyle.controlPadding)
                .background(SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsStyle.controlRadius)
                        .strokeBorder(Color.primary.opacity(0.10))
                }
                Spacer(minLength: 24)
                VStack(alignment: .leading, spacing: SettingsStyle.Spacing.controls) {
                    Divider()
                    Text("如何唤出").font(SettingsStyle.Typography.body.weight(.medium))
                    Text("先在按键映射中绑定“唤出常用语”，再用遥控器打开浮层。")
                        .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                Button {
                    model.page = .mapping
                } label: {
                    Label("返回按键映射", systemImage: "arrow.left")
                }
                .buttonStyle(.link)
                .font(SettingsStyle.Typography.body.weight(.medium))
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var boundPhraseCount: Int {
        PhraseAssignments.inputs.filter { model.phraseAssignments[$0] != nil }.count
    }

    private func instructionRow(_ symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: SettingsStyle.Spacing.inline) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(title).font(SettingsStyle.Typography.body.weight(.semibold))
            Text(detail).font(SettingsStyle.Typography.body.weight(.medium))
        }
        .foregroundStyle(.primary)
    }

    private func assignmentTitle(_ input: ControllerInput) -> String {
        guard let id = model.phraseAssignments[input] else { return "未分配" }
        return model.phrases.first(where: { $0.id == id })?.displayTitle ?? "已删除"
    }

    private var phraseListPanel: some View {
        SettingsPanel(contentPadding: EdgeInsets(top: SettingsStyle.panelPadding, leading: SettingsStyle.controlPadding,
                                               bottom: SettingsStyle.Spacing.groups, trailing: SettingsStyle.controlPadding)) {
            HStack(spacing: SettingsStyle.Spacing.inline) {
                Image(systemName: "text.quote").foregroundStyle(.secondary)
                Text("常用语库").font(SettingsStyle.Typography.panelTitle)
                Spacer(minLength: 4)
                Button {
                    let phrase = SavedPhrase(title: "新常用语", text: "")
                    model.phrases.append(phrase)
                    selectedPhraseID = phrase.id
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            HStack(alignment: .firstTextBaseline, spacing: SettingsStyle.Spacing.inline) {
                Text("已绑定置顶，其余可拖动排序")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(model.phrases.count) 条")
                    .monospacedDigit()
                    .fixedSize()
            }
            .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
            Divider()
            if model.phrases.isEmpty {
                VStack(spacing: SettingsStyle.Spacing.inline) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text("还没有常用语")
                        .font(SettingsStyle.Typography.body.weight(.medium))
                    Text("点击“新建”开始添加")
                        .font(SettingsStyle.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                Spacer(minLength: 0)
            } else {
                PhraseListView(model: model, selectedPhraseID: $selectedPhraseID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var phraseEditorPanel: some View {
        if let phrase = selectedPhraseBinding {
            SettingsPanel("常用语内容", symbol: "pencil") {
                HStack(alignment: .firstTextBaseline, spacing: SettingsStyle.Spacing.inline) {
                    Text(phrase.wrappedValue.displayTitle)
                        .font(SettingsStyle.Typography.body.weight(.medium))
                        .lineLimit(1)
                    Text("·").foregroundStyle(.tertiary)
                    Text("修改后自动保存")
                        .font(SettingsStyle.Typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: SettingsStyle.Spacing.groups) {
                        contentEditor("内容 1", title: phrase.title, text: phrase.text,
                                       titlePlaceholder: "内容1标题", textPlaceholder: "内容1正文")
                        Divider()
                        contentEditor("内容 2", title: phrase.englishTitle, text: phrase.englishText,
                                       titlePlaceholder: "内容2标题", textPlaceholder: "内容2正文")
                    }
                }
                Divider()
                HStack {
                    Spacer()
                    Button("删除", role: .destructive) {
                        guard let id = selectedPhraseID else { return }
                        model.requestDeletion(.phrase(id))
                    }.controlSize(.small)
                }
            }
            .id(selectedPhraseID)
        } else {
            SettingsPanel("常用语内容", symbol: "pencil") {
                Spacer(minLength: 0)
                SettingsEmpty(symbol: "text.quote", title: "选择一条常用语", detail: "选择后可编辑内容1和内容2的标题及正文。")
                Spacer(minLength: 0)
            }
        }
    }

    private func contentEditor(_ heading: String, title: Binding<String>, text: Binding<String>,
                                titlePlaceholder: String, textPlaceholder: String) -> some View {
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
            HStack {
                Text(heading).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    model.copy(text.wrappedValue)
                    model.postNotice("常用语已复制", level: .success)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(SettingsStyle.Typography.caption.weight(.medium))
                .disabled(text.wrappedValue.isEmpty)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("标题").font(SettingsStyle.Typography.caption.weight(.medium)).foregroundStyle(.secondary)
                TextField(titlePlaceholder, text: title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(titlePlaceholder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("正文").font(SettingsStyle.Typography.caption.weight(.medium)).foregroundStyle(.secondary)
                TextEditor(text: text)
                    .font(.system(size: 13)).frame(height: 116).scrollContentBackground(.hidden)
                    .padding(7)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
                    .overlay { RoundedRectangle(cornerRadius: SettingsStyle.controlRadius).strokeBorder(Color.primary.opacity(0.12)) }
                    .overlay(alignment: .topLeading) {
                        if text.wrappedValue.isEmpty {
                            Text(textPlaceholder).font(.system(size: 13)).foregroundStyle(.tertiary)
                                .padding(SettingsStyle.controlPadding).allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel(textPlaceholder)
            }
        }
    }

    private var selectedPhraseBinding: Binding<SavedPhrase>? {
        guard let id = selectedPhraseID, model.phrases.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.phrases.first(where: { $0.id == id }) ?? SavedPhrase(id: id, title: "", text: "") },
            set: { updated in
                guard let index = model.phrases.firstIndex(where: { $0.id == id }) else { return }
                model.phrases[index] = updated
            }
        )
    }

    private func ensureSelection() {
        if let selectedPhraseID, model.phrases.contains(where: { $0.id == selectedPhraseID }) { return }
        selectedPhraseID = model.orderedPhrases.first?.id
    }
}

/// Five-position diagram shared by settings and the compact phrase panel.
@MainActor
struct PhrasePadView: View {
    let title: (ControllerInput) -> String
    let isAssigned: (ControllerInput) -> Bool
    let showsAssignmentMarks: Bool
    let diameter: CGFloat
    let onSelect: (ControllerInput) -> Void
    let selectedInput: ControllerInput?
    @State private var hoveredInput: ControllerInput?
    @State private var pressedInput: ControllerInput?
    @FocusState private var focusedInput: ControllerInput?
    private var contentScale: CGFloat { diameter / 212 }

    init(title: @escaping (ControllerInput) -> String,
         isAssigned: @escaping (ControllerInput) -> Bool = { _ in false },
         showsAssignmentMarks: Bool = true,
         diameter: CGFloat = 212,
         selectedInput: ControllerInput? = nil,
         onSelect: @escaping (ControllerInput) -> Void) {
        self.title = title
        self.isAssigned = isAssigned
        self.showsAssignmentMarks = showsAssignmentMarks
        self.diameter = diameter
        self.onSelect = onSelect
        self.selectedInput = selectedInput
    }

    var body: some View {
        ZStack {
            directionButton(.dpadUp, angle: -90)
            directionButton(.dpadLeft, angle: 180)
            directionButton(.dpadRight, angle: 0)
            directionButton(.dpadDown, angle: 90)
            Button { onSelect(.buttonA) } label: {
                keyLabel(.buttonA).frame(width: 66 * contentScale, height: 66 * contentScale)
            }
            .buttonStyle(PhrasePadKeyStyle(shape: Circle(), hovered: hoveredInput == .buttonA,
                                          pressed: pressedInput == .buttonA,
                                          focused: focusedInput == .buttonA || selectedInput == .buttonA))
            .focused($focusedInput, equals: .buttonA)
            .help("\(ControllerInput.buttonA.label)：\(title(.buttonA))")
            .accessibilityLabel("\(ControllerInput.buttonA.label)：\(title(.buttonA))")
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            PhrasePadInputSurface(onSelect: onSelect, onHover: { hoveredInput = $0 },
                                  onPress: { pressedInput = $0 })
        }
    }

    private func directionButton(_ input: ControllerInput, angle: Double) -> some View {
        Button { onSelect(input) } label: {
            ZStack {
                keyLabel(input).frame(width: 66 * contentScale, height: 66 * contentScale)
                    .position(x: PhrasePadLayout.position(for: input).x * contentScale,
                              y: PhrasePadLayout.position(for: input).y * contentScale)
            }
            .frame(width: diameter, height: diameter)
        }
        .buttonStyle(PhrasePadKeyStyle(shape: PhrasePadSector(angle: angle), hovered: hoveredInput == input,
                                      pressed: pressedInput == input,
                                      focused: focusedInput == input || selectedInput == input))
        .focused($focusedInput, equals: input)
        .help("\(input.label)：\(title(input))")
        .accessibilityLabel("\(input.label)：\(title(input))")
    }

    private func keyLabel(_ input: ControllerInput) -> some View {
        VStack(spacing: 6 * contentScale) {
            if input == .buttonA {
                Text("OK").font(.system(size: 15 * contentScale, weight: .semibold))
            } else {
                Image(systemName: input.symbol).font(.system(size: 15 * contentScale, weight: .medium))
            }
            HStack(spacing: 3 * contentScale) {
                Text(title(input)).font(.system(size: 11 * contentScale, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                if showsAssignmentMarks && isAssigned(input) {
                    Image(systemName: "checkmark").font(.system(size: 7 * contentScale, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isAssigned(input) ? .primary : .secondary)
        }
        .accessibilityHidden(true)
    }
}

enum PhrasePadLayout {
    static func position(for input: ControllerInput) -> CGPoint {
        switch input {
        case .dpadUp: CGPoint(x: 106, y: 38)
        case .dpadDown: CGPoint(x: 106, y: 174)
        case .dpadLeft: CGPoint(x: 38, y: 106)
        case .dpadRight: CGPoint(x: 174, y: 106)
        default: CGPoint(x: 106, y: 106)
        }
    }

    static func anchor(for input: ControllerInput) -> UnitPoint {
        let point = position(for: input)
        return UnitPoint(x: point.x / 212, y: point.y / 212)
    }

    static func input(at point: CGPoint, in bounds: CGRect) -> ControllerInput? {
        guard bounds.contains(point) else { return nil }
        let centerSize = min(bounds.width, bounds.height) * 66 / 212
        let center = CGRect(x: bounds.midX - centerSize / 2, y: bounds.midY - centerSize / 2,
                            width: centerSize, height: centerSize)
        if Path(ellipseIn: center).contains(point) { return .buttonA }
        for (input, angle): (ControllerInput, Double) in [(.dpadUp, -90), (.dpadLeft, 180), (.dpadRight, 0), (.dpadDown, 90)] {
            if PhrasePadSector(angle: angle).path(in: bounds).contains(point) { return input }
        }
        return nil
    }
}

private struct PhrasePadSector: Shape {
    let angle: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1
        let start = Angle.degrees(angle - 43.5)
        let end = Angle.degrees(angle + 43.5)
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: radius * 0.36, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct PhrasePadKeyStyle<S: Shape>: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S
    let hovered: Bool
    let pressed: Bool
    let focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background {
                shape.fill(SettingsStyle.mappingTriggerBackground(in: colorScheme))
                    .overlay {
                        shape.fill(Color.primary.opacity(configuration.isPressed || pressed ? 0.10 : hovered ? 0.05 : 0))
                    }
            }
            .overlay {
                shape.stroke(focused ? Color.accentColor : Color.primary.opacity(hovered ? 0.24 : 0.16),
                             lineWidth: focused ? 2 : 1)
            }
            .contentShape(shape)
    }
}
