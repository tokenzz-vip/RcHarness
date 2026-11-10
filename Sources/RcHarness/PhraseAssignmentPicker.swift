import SwiftUI

@MainActor
struct PhraseAssignmentPicker: View {
    let input: ControllerInput
    let phrases: [SavedPhrase]
    let selection: UUID?
    let onSelect: (UUID?) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var results: [SavedPhrase] { PhraseSearch.filter(phrases, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.controls) {
            Label("\(input.label) · 选择常用语", systemImage: input.symbol)
                .font(.system(size: 14, weight: .semibold))
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索标题或正文", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("搜索常用语")
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("清除搜索")
                }
            }
            .padding(SettingsStyle.compactControlPadding)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: SettingsStyle.controlRadius).strokeBorder(Color.primary.opacity(0.12)) }
            option("不分配", id: nil)
            Divider()
            HStack {
                Text(query.isEmpty ? "常用语库" : "搜索结果")
                Spacer()
                Text("\(results.count) 条").monospacedDigit()
            }.font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
            ScrollView {
                if results.isEmpty {
                    VStack(spacing: SettingsStyle.Spacing.inline) {
                        Image(systemName: "magnifyingglass").font(.system(size: 22))
                        Text(query.isEmpty ? "还没有常用语" : "没有匹配的常用语")
                        Text(query.isEmpty ? "先在常用语库中新建一条" : "试试更短的关键词，或清除搜索")
                            .font(SettingsStyle.Typography.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { phrase in
                            option(phrase.displayTitle, id: phrase.id, preview: phrase.text.isEmpty ? phrase.englishText : phrase.text)
                        }
                    }
                }
            }
            .frame(height: 260)
        }
        // Preserve the compact native popover's search and option layout.
        .padding(16)
        .frame(width: 300)
        .onAppear { searchFocused = true }
    }

    private func option(_ title: String, id: UUID?, preview: String = "") -> some View {
        Button { onSelect(id) } label: {
            HStack(spacing: SettingsStyle.Spacing.inline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(SettingsStyle.Typography.body.weight(.medium)).lineLimit(2)
                    if !preview.isEmpty {
                        Text(preview).font(SettingsStyle.Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if selection == id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(SettingsStyle.compactControlPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selection == id ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
