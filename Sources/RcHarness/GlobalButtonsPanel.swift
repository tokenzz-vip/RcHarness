import SwiftUI

struct GlobalButtonsPanel: View {
    @ObservedObject var model: RemoteDashboardModel

    var body: some View {
        SettingsPanel("全局按键 · 当前遥控器", symbol: "globe") {
            Text("仅对当前遥控器的所有方案和 Harness 生效；切换遥控器后使用独立设置。动作在「按键」页配置，语音键固定用于语音触发。")
                .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
            HStack {
                Label("全局按键", systemImage: model.globalButtons.input.symbol)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Picker("全局按键", selection: Binding(
                    get: { model.globalButtons.input }, set: { model.setGlobalInput($0) }
                )) {
                    ForEach(model.remoteProfile.inputs.filter { $0 != .options }, id: \.self) { input in
                        Text(input.label).tag(input)
                    }
                }
                .labelsHidden().frame(width: 180)
                .help("选择全局按键；单击、双击和长按动作在「按键」页配置")
            }
        }
    }
}
