import SwiftUI

/// Filtering is local UI state; a reference changes only when an action is chosen.
@MainActor
struct MacroReferencePicker: View {
    @Binding var referenceID: String?
    @Binding var tagIDs: Set<String>
    @ObservedObject var model: RemoteDashboardModel
    var parentMacroID: UUID? = nil

    var matchingMacros: [SavedMacro] {
        model.macros.filter { tagIDs.isEmpty || !$0.tagIDs.isDisjoint(with: tagIDs) }
    }

    var selectedMacro: SavedMacro? {
        model.macros.first { $0.id.uuidString == referenceID }
    }

    var selectedOutsideFilter: SavedMacro? {
        selectedMacro.flatMap { tagIDs.isEmpty || !$0.tagIDs.isDisjoint(with: tagIDs) ? nil : $0 }
    }

    private var selectionTitle: String {
        selectedMacro?.name ?? ((referenceID ?? "").isEmpty ? "选择组合动作" : "已删除的组合动作")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.controls) {
            MappingEditorField("筛选标签") {
                MacroTagFilter(selection: $tagIDs)
            }
            MappingEditorField("组合动作") {
                SettingsSelectionPopover(title: selectionTitle, accessibilityLabel: "组合动作",
                    identifier: "macro-reference-picker") { height, dismiss in
                    MacroReferenceMenu(referenceID: $referenceID, tagIDs: tagIDs, model: model,
                        parentMacroID: parentMacroID, maximumHeight: height, dismiss: dismiss)
                }
            }
            if matchingMacros.isEmpty {
                Text("这些标签下没有组合动作，请切换标签。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if selectedOutsideFilter != nil {
                Text("当前已选动作不在这些标签下，现有绑定保持不变。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let referenceID, !referenceID.isEmpty, selectedMacro == nil {
                Text("引用的组合动作已删除，请重新选择。")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .font(SettingsStyle.Typography.body)
    }
}

@MainActor
private struct MacroReferenceMenu: View {
    @Binding var referenceID: String?
    let tagIDs: Set<String>
    @ObservedObject var model: RemoteDashboardModel
    let parentMacroID: UUID?
    let maximumHeight: CGFloat
    let dismiss: () -> Void

    private var matchingMacros: [SavedMacro] {
        model.macros.filter { tagIDs.isEmpty || !$0.tagIDs.isDisjoint(with: tagIDs) }
    }

    private var selectedOutsideFilter: SavedMacro? {
        model.macros.first {
            $0.id.uuidString == referenceID && !tagIDs.isEmpty && $0.tagIDs.isDisjoint(with: tagIDs)
        }
    }

    private var hasDeletedReference: Bool {
        guard let referenceID, !referenceID.isEmpty else { return false }
        return !model.macros.contains { $0.id.uuidString == referenceID }
    }

    private var listHeight: CGFloat {
        let count = matchingMacros.count + (selectedOutsideFilter == nil ? 0 : 1) + (hasDeletedReference ? 1 : 0)
        return min(maximumHeight - 45, CGFloat(max(1, count)) * 28)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsSelectionRow(title: "选择组合动作", selected: (referenceID ?? "").isEmpty) {
                referenceID = ""
                dismiss()
            }
            Divider().padding(.horizontal, SettingsStyle.Spacing.inline).padding(.vertical, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let macro = selectedOutsideFilter { option(macro, suffix: "（当前已选）") }
                        if hasDeletedReference {
                            SettingsSelectionRow(title: "已删除的组合动作", selected: true, action: {})
                                .disabled(true)
                        }
                        ForEach(matchingMacros) { macro in option(macro) }
                        if matchingMacros.isEmpty && selectedOutsideFilter == nil && !hasDeletedReference {
                            Text("没有匹配的组合动作")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .padding(.horizontal, SettingsStyle.Spacing.inline)
                        }
                    }
                }
                .frame(height: max(28, listHeight))
                .onAppear { if let referenceID { proxy.scrollTo(referenceID, anchor: .center) } }
            }
        }
        .padding(4)
    }

    private func option(_ macro: SavedMacro, suffix: String = "") -> some View {
        let createsCycle = parentMacroID.map { !model.canNestMacro(macro.id, in: $0) } ?? false
        return SettingsSelectionRow(title: macro.name + suffix + (createsCycle ? "（循环引用）" : ""),
                                    selected: referenceID == macro.id.uuidString) {
            guard model.macros.contains(where: { $0.id == macro.id }),
                  parentMacroID.map({ model.canNestMacro(macro.id, in: $0) }) ?? true else { return }
            referenceID = macro.id.uuidString
            dismiss()
        }
        .disabled(createsCycle)
        .id(macro.id.uuidString)
    }
}
