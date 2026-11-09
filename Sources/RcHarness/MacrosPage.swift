import SwiftUI

struct MacrosPage: View {
    private enum ScrollTarget: Hashable { case addStep }

    @ObservedObject var model: RemoteDashboardModel
    @Binding var actionFilter: ActionFilter
    @State private var selectedMacroID: UUID?
    @State private var macroNameDraft: String

    init(model: RemoteDashboardModel, actionFilter: Binding<ActionFilter>) {
        self.model = model
        _actionFilter = actionFilter
        _selectedMacroID = State(initialValue: model.macros.first?.id)
        _macroNameDraft = State(initialValue: model.macros.first?.name ?? "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            macroList.frame(width: 230)
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
        .onChange(of: selectedMacroID) { _, id in
            macroNameDraft = model.macros.first(where: { $0.id == id })?.name ?? ""
        }
        .onChange(of: model.macros.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == selectedMacroID }) {
                selectedMacroID = ids.first
            }
        }
    }

    private var macroList: some View {
        SettingsPanel(contentPadding: EdgeInsets(top: 20, leading: 20, bottom: 12, trailing: 8)) {
            HStack(spacing: 8) {
                Text("我的组合动作").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 4)
                if !model.macros.isEmpty {
                    Button { addMacro() } label: { Label("新建", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel("新建组合动作")
                }
            }
            .padding(.trailing, 12)
            Divider().padding(.trailing, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.macros.isEmpty {
                            SettingsEmpty(symbol: SettingsPage.macros.symbol, title: "还没有组合动作", detail: "把多个本机操作连成一次顺手的按键。")
                            Button { addMacro() } label: {
                                Text("创建第一个组合动作").frame(maxWidth: .infinity)
                            }.buttonStyle(.borderedProminent)
                        }
                        ForEach(model.macros) { macro in
                            Button { selectedMacroID = macro.id } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(macro.name).font(.system(size: 13, weight: .medium))
                                            .lineLimit(2)
                                        Text("\(macro.steps.count) 个步骤").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedMacroID == macro.id ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
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
        selectedMacroID = model.addMacro()
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
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if steps.wrappedValue.isEmpty {
                            Text("还没有步骤，点击下方“添加步骤”开始配置。")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                        }
                        ForEach(steps) { $step in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("步骤 \((macro.steps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1)")
                                        .font(.system(size: 12, weight: .semibold))
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
                            .padding(12).background(SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: 10))
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
                    model.deleteMacro(macro.id)
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
