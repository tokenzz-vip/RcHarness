import SwiftUI

@MainActor
struct MouseModePanel: View {
    @ObservedObject var model: RemoteDashboardModel

    var body: some View {
        SettingsPanel("鼠标模式设置", symbol: "computermouse") {
            HStack(spacing: SettingsStyle.Spacing.groups) {
                clickPicker("鼠标左键", selection: \.leftClick, other: \.rightClick)
                clickPicker("鼠标右键", selection: \.rightClick, other: \.leftClick)
            }
            Text("按住方向键移动指针。左右键可选未设为全局按键的实体键，方向键和语音键除外。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SettingsStyle.Spacing.controls) {
                Text("指针速度")
                Slider(value: Binding(
                    get: { Double(model.mouseSettings.speed) },
                    set: { value in
                        var settings = model.mouseSettings
                        settings.speed = Int(value.rounded())
                        model.setMouseSettings(settings)
                    }
                ), in: Double(RemoteMouseSettings.speedRange.lowerBound)...Double(RemoteMouseSettings.speedRange.upperBound)) {
                    Text("指针速度")
                }
                    .labelsHidden()
                    .accessibilityValue(Text("\(model.mouseSettings.speed)"))
                Text("\(model.mouseSettings.speed)")
                    .monospacedDigit()
                    .frame(minWidth: 26, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            Button(model.mouseModeEnabled ? "退出鼠标模式" : "进入鼠标模式") {
                model.onSetMouseMode?(!model.mouseModeEnabled)
            }
            .disabled(model.operationMode != .mapping)
            .help("启用遥控器映射后可进入鼠标模式")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(SettingsStyle.Typography.body)
    }

    private func clickPicker(_ title: String, selection: WritableKeyPath<RemoteMouseSettings, ControllerInput?>,
                             other: KeyPath<RemoteMouseSettings, ControllerInput?>) -> some View {
        HStack(spacing: SettingsStyle.Spacing.controls) {
            Text(title)
            Picker(title, selection: Binding(
                get: { model.mouseSettings[keyPath: selection] },
                set: { input in
                    var settings = model.mouseSettings
                    settings[keyPath: selection] = input
                    model.setMouseSettings(settings)
                }
            )) {
                Text("未设置").tag(nil as ControllerInput?)
                ForEach(RemoteMouseSettings.buttonChoices(for: model.remoteProfile, globals: model.globalButtons)
                    .filter { $0 != model.mouseSettings[keyPath: other] }, id: \.self) { input in
                    Text(input.label).tag(Optional(input))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }
}
