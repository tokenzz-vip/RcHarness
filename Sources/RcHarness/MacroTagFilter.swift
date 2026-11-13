import SwiftUI

@MainActor
struct MacroTagFilter: View {
    @Binding var selection: Set<String>

    private var names: [String] {
        MacroTag.all.filter { selection.contains($0.id) }.map(\.name)
    }

    private var summary: String {
        names.isEmpty ? "全部标签" : names.joined(separator: "、")
    }

    var body: some View {
        SettingsSelectionPopover(title: summary, accessibilityLabel: "按标签筛选组合动作",
            identifier: "macro-tag-filter",
            accessibilityValue: names.isEmpty ? "全部标签" : names.joined(separator: "、"),
            accessibilityHelp: "可选择多个标签，再次点击可取消",
            label: { MacroTagSelectionLabel(names: names) }) { height, _ in
            MacroTagFilterMenu(selection: $selection, maximumHeight: height)
        }
    }
}

@MainActor
private struct MacroTagSelectionLabel: View {
    let names: [String]

    var body: some View {
        if names.isEmpty {
            Text("全部标签")
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach((1...names.count).reversed(), id: \.self) { count in
                    HStack(spacing: 4) {
                        ForEach(names.prefix(count), id: \.self) { name in
                            tag(name)
                        }
                        if count < names.count { tag("+\(names.count - count)") }
                    }
                    .fixedSize()
                }
                tag("+\(names.count)")
            }
        }
    }

    private func tag(_ title: String) -> some View {
        Text(title)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.primary.opacity(0.12))
            }
    }
}

@MainActor
struct MacroTagFilterMenu: View {
    @Binding var selection: Set<String>
    var maximumHeight: CGFloat = 320

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                row("全部标签", selected: selection.isEmpty) { selection.removeAll() }
                Divider().padding(.horizontal, SettingsStyle.Spacing.inline).padding(.vertical, 4)
                ForEach(MacroTag.all) { tag in
                    row(tag.name, selected: selection.contains(tag.id)) {
                        if selection.contains(tag.id) { selection.remove(tag.id) }
                        else { selection.insert(tag.id) }
                    }
                }
            }
            .padding(4)
        }
        .frame(height: min(maximumHeight, CGFloat(MacroTag.all.count + 1) * 28 + 17))
    }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        SettingsSelectionRow(title: title, selected: selected, action: action)
    }
}
