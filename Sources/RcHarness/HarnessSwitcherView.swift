import AppKit
import SwiftUI

struct HarnessSwitcherView: View {
    @ObservedObject var model: HarnessSwitcherModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                HarnessIcon(size: 15)
                Text("运行中的 Harness").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.items.count)").font(.caption).foregroundStyle(.secondary)
            }
            if model.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "app.dashed").font(.system(size: 38)).foregroundStyle(.secondary)
                    Text("没有正在运行的 Harness").font(.headline)
                    Text("先打开已启用的 Harness 应用，再使用运行列表。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(model.items) { item in
                                Button { model.confirm(item.id) } label: {
                                    VStack(spacing: 10) {
                                        applicationIcon(item)
                                            .frame(width: 76, height: 76)
                                        Text(item.name).font(.system(size: 12, weight: .medium))
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    .frame(width: 108, height: 124)
                                    .padding(8)
                                    .background(model.selectedID == item.id ? Color.primary.opacity(0.12) : .clear,
                                                in: RoundedRectangle(cornerRadius: SettingsStyle.panelRadius))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: SettingsStyle.panelRadius)
                                            .strokeBorder(model.selectedID == item.id ? Color.accentColor.opacity(0.75) : .clear, lineWidth: 2)
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: SettingsStyle.panelRadius))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.name)
                                .accessibilityAddTraits(model.selectedID == item.id ? .isSelected : [])
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { if let id = model.selectedID { scroll.scrollTo(id, anchor: .center) } }
                    .onChange(of: model.selectedID) { _, id in
                        if let id { scroll.scrollTo(id, anchor: .center) }
                    }
                }
            }
            HStack(spacing: 16) {
                Text("← → 选择")
                Text("确认 OK 切换")
                Text("返回 / 主页 关闭")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.18))
    }

    @ViewBuilder
    private func applicationIcon(_ item: HarnessSwitcherItem) -> some View {
        if let path = item.application.applicationPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high)
        } else {
            Image(systemName: "app.fill").resizable().scaledToFit().foregroundStyle(.secondary)
                .padding(8)
        }
    }
}
