import SwiftUI

struct MacrosPage: View {
    private enum ScrollTarget: Hashable { case addStep }

    @ObservedObject var model: RemoteDashboardModel
    @Binding var actionFilter: ActionFilter
    @State private var selectedMacroID: UUID?
    @State private var macroNameDraft: String
    @State private var selectedTagIDs: Set<String> = []

    private var visibleMacros: [SavedMacro] {
        model.macros.filter { macro in
            selectedTagIDs.isEmpty || !macro.tagIDs.isDisjoint(with: selectedTagIDs)
        }
    }

    init(model: RemoteDashboardModel, actionFilter: Binding<ActionFilter>) {
        self.model = model
        _actionFilter = actionFilter
        _selectedMacroID = State(initialValue: model.macros.first?.id)
        _macroNameDraft = State(initialValue: model.macros.first?.name ?? "")
    }

    var body: some View {
        GeometryReader { geometry in
            let columnsWidth = max(0, geometry.size.width - SettingsStyle.Spacing.groups)
            // Widen the library with the window, while reserving room for step editing.
            let listWidth = min(min(360, max(260, columnsWidth * 0.32)), max(0, columnsWidth - 520))
            HStack(alignment: .top, spacing: SettingsStyle.Spacing.groups) {
                macroList.frame(width: listWidth)
                if let index = model.macros.firstIndex(where: { $0.id == selectedMacroID }) {
                    editor(index).id(model.macros[index].id)
                } else {
                    SettingsPanel {
                        SettingsEmpty(symbol: "point.3.connected.trianglepath.dotted", title: "一次按键，依次完成", detail: "添加键盘、应用和媒体操作，再回到按键映射绑定单击、双击或长按。")
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: selectedMacroID) { _, id in
            macroNameDraft = model.macros.first(where: { $0.id == id })?.name ?? ""
        }
        .onChange(of: model.macros.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == selectedMacroID }) {
                selectedMacroID = visibleMacros.first?.id
            }
        }
        .onChange(of: selectedTagIDs) { _, _ in
            if !visibleMacros.contains(where: { $0.id == selectedMacroID }) {
                selectedMacroID = visibleMacros.first?.id
            }
        }
    }

    private var macroList: some View {
        SettingsPanel(contentPadding: EdgeInsets(top: SettingsStyle.panelPadding, leading: SettingsStyle.panelPadding,
                                               bottom: SettingsStyle.controlPadding, trailing: SettingsStyle.compactControlPadding)) {
            HStack(spacing: SettingsStyle.Spacing.inline) {
                Text("我的组合动作").font(SettingsStyle.Typography.panelTitle)
                Spacer(minLength: 4)
                if !model.macros.isEmpty {
                    Button { addMacro() } label: { Label("新建", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel("新建组合动作")
                }
            }
            .padding(.trailing, SettingsStyle.panelPadding - SettingsStyle.compactControlPadding)
            tagFilterPicker
                .accessibilityLabel("按标签筛选组合动作")
                .padding(.trailing, SettingsStyle.panelPadding - SettingsStyle.compactControlPadding)
            Divider().padding(.trailing, SettingsStyle.panelPadding - SettingsStyle.compactControlPadding)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.macros.isEmpty {
                            SettingsEmpty(symbol: SettingsPage.macros.symbol, title: "还没有组合动作", detail: "把多个本机操作连成一次顺手的按键。")
                            Button { addMacro() } label: {
                                Text("创建第一个组合动作").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent)
                        }
                        if !model.macros.isEmpty && visibleMacros.isEmpty {
                            SettingsEmpty(symbol: "tag", title: "此标签下还没有动作", detail: "切换标签，或新建一个组合动作。")
                            Button("显示全部动作") { selectedTagIDs.removeAll() }
                                .buttonStyle(.link)
                        }
                        ForEach(visibleMacros) { macro in
                            Button { selectedMacroID = macro.id } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(macro.name).font(.system(size: 13, weight: .medium))
                                            .lineLimit(2)
                                        Text("\(macro.steps.count) 个步骤").font(.caption).foregroundStyle(.secondary)
                                        if !macro.tagIDs.isEmpty {
                                            Text(tagSummary(macro))
                                                .font(SettingsStyle.Typography.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                                .help(tagSummary(macro))
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, SettingsStyle.controlPadding).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedMacroID == macro.id ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
                                .contentShape(RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selectedMacroID == macro.id ? .isSelected : [])
                            .id(macro.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: selectedMacroID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func addMacro() {
        selectedMacroID = model.addMacro(tagIDs: selectedTagIDs.isEmpty ? [MacroTag.general.id] : selectedTagIDs)
    }

    private var tagFilterPicker: some View {
        MacroTagFilter(selection: $selectedTagIDs)
    }

    private func tagSummary(_ macro: SavedMacro) -> String {
        MacroTag.all.filter { macro.tagIDs.contains($0.id) }.map(\.name).joined(separator: " · ")
    }

    private func tagEditor(_ macro: SavedMacro) -> some View {
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
            HStack(spacing: SettingsStyle.Spacing.inline) {
                Text("标签").font(SettingsStyle.Typography.body.weight(.semibold))
                Text("可多选，仅用于筛选").font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), alignment: .leading)],
                      alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
                ForEach(MacroTag.all) { tag in
                    Toggle(tag.name, isOn: Binding(
                        get: { model.macros.first(where: { $0.id == macro.id })?.tagIDs.contains(tag.id) ?? false },
                        set: { isOn in
                            guard var tags = model.macros.first(where: { $0.id == macro.id })?.tagIDs else { return }
                            if isOn { tags.insert(tag.id) } else { tags.remove(tag.id) }
                            model.updateMacroTags(tags, for: macro.id)
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(SettingsStyle.Typography.body)
                    .accessibilityLabel("\(tag.name)标签")
                }
            }
        }
    }

    private func editor(_ index: Int) -> some View {
        let macro = model.macros[index]
        let nameError = model.macroNameError(macroNameDraft, excluding: macro.id)
        let steps = Binding(
            get: { model.macros.first(where: { $0.id == macro.id })?.steps ?? [] },
            set: { model.updateMacroSteps($0, for: macro.id) }
        )
        return SettingsPanel("编辑组合动作", symbol: "slider.horizontal.3") {
            HStack {
                TextField("组合动作名称", text: $macroNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveName(macro.id) }
                Button("保存名称") { saveName(macro.id) }
                    .disabled(nameError != nil || macroNameDraft.trimmingCharacters(in: .whitespacesAndNewlines) == macro.name)
            }
            if let nameError {
                Text(nameError).font(.caption).foregroundStyle(.red)
            }
            tagEditor(macro)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: SettingsStyle.Spacing.controls) {
                        if steps.wrappedValue.isEmpty {
                            Text("还没有步骤，点击下方“添加步骤”开始配置。")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                        }
                        ForEach(steps) { $step in
                            VStack(alignment: .leading, spacing: SettingsStyle.Spacing.inline) {
                                HStack {
                                    Text("步骤 \((macro.steps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1)")
                                        .font(SettingsStyle.Typography.body.weight(.semibold))
                                    Spacer()
                                    Button { steps.wrappedValue.removeAll { $0.id == step.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("移除步骤")
                                }
                                ActionMappingEditor(value: $step.mapping, model: model, filter: .all, parentMacroID: macro.id)
                                HStack {
                                    Text("执行后等待").font(.caption).foregroundStyle(.secondary)
                                    Slider(value: $step.delay, in: 0...3, step: 0.1)
                                    Text(String(format: "%.1f 秒", step.delay)).font(.caption.monospacedDigit()).frame(width: 45)
                                }
                            }
                            .padding(SettingsStyle.controlPadding).background(SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
                            .id(step.id)
                        }
                        Button { steps.wrappedValue.append(MacroStep()) } label: {
                            Label("添加步骤", systemImage: "plus")
                        }
                        .id(ScrollTarget.addStep)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: macro.steps.map(\.id)) { old, new in
                    if new.count > old.count { proxy.scrollTo(ScrollTarget.addStep, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Button("删除组合动作", role: .destructive) {
                    model.requestDeletion(.macro(macro.id))
                }.buttonStyle(.link)
                Spacer()
                Button("绑定到遥控器") { model.page = .mapping; model.editorVisible = true; actionFilter = .custom }
                    .buttonStyle(.borderedProminent).disabled(macro.steps.isEmpty)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func saveName(_ id: UUID) {
        if model.renameMacro(id, name: macroNameDraft) {
            macroNameDraft = model.macros.first(where: { $0.id == id })?.name ?? ""
        }
    }
}
