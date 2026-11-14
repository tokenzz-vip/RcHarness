import SwiftUI

struct GlobalButtonsPanel: View {
    @ObservedObject var model: RemoteDashboardModel

    var body: some View {
        SettingsPanel("全局按键 · 当前遥控器", symbol: "globe") {
            Text("仅对当前遥控器的所有方案和 Harness 生效。前三项固定保留，默认依次为电源键、主页键、\(model.remoteProfile.adapter == .chromecast ? "输入源键" : "TV 键")；第一项必选，后两项可留空。可继续增加全局按键，各项按键不能重复。动作在「按键」页配置，语音键固定用于语音触发。")
                .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(Array(model.globalButtons.buttons.enumerated()), id: \.element.id) { index, button in
                    HStack(spacing: SettingsStyle.Spacing.inline) {
                        Label(button.input?.label ?? "未设置按键",
                              systemImage: button.input?.symbol ?? "questionmark.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(button.input == nil ? .secondary : .primary)
                            .frame(width: 180, alignment: .leading)

                        Spacer(minLength: 18)

                        Picker("全局按键 \(index + 1)", selection: Binding<ControllerInput?>(
                            get: { model.globalButtons.buttons.indices.contains(index) ? model.globalButtons.buttons[index].input : nil },
                            set: { model.setGlobalInput($0, at: index) }
                        )) {
                            if index > 0 {
                                Text("未设置").tag(nil as ControllerInput?)
                            }
                            ForEach(model.globalInputChoices(at: index), id: \.self) { input in
                                Text(input.label).tag(Optional(input))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .help("选择全局按键；单击、双击和长按动作在「按键」页配置")

                        if index >= GlobalButtonSettings.requiredButtonCount {
                            Button(role: .destructive) {
                                model.removeGlobalButton(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .frame(width: 24, height: 24)
                            .help("删除此全局按键")
                        } else {
                            Color.clear.frame(width: 24, height: 20)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    model.addGlobalButton()
                } label: {
                    Label("增加全局按键", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
