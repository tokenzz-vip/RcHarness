import SwiftUI

struct PhrasesPage: View {
    @ObservedObject var model: RemoteDashboardModel

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("保存常用表达，绑定到遥控器后直接输入到当前 App。")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("返回按键映射") { model.page = .mapping }
                Button {
                    model.phrases.append(SavedPhrase(title: "新常用语", text: ""))
                } label: { Label("添加常用语", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            if model.phrases.isEmpty {
                SettingsPanel { SettingsEmpty(symbol: "text.quote", title: "把常用的话，放在手边", detail: "常用语保存在当前 Mac，支持直接输入或复制。") }
            }
            ForEach($model.phrases) { $phrase in
                SettingsPanel {
                    HStack {
                        TextField("常用语名称", text: $phrase.title).textFieldStyle(.plain).font(.headline)
                        Spacer()
                        Button("复制") { model.copy(phrase.text); model.actionMessage = "常用语已复制" }.controlSize(.small)
                        Button { model.phrases.removeAll { $0.id == phrase.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("删除常用语")
                    }
                    TextEditor(text: $phrase.text).font(.system(size: 13)).frame(minHeight: 80).scrollContentBackground(.hidden)
                        .padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
