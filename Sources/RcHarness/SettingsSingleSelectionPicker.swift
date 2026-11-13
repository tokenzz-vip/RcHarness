import SwiftUI

struct SettingsSelectionOption<Value: Hashable> {
    let value: Value
    let title: String
}

/// A single choice list using the same below-field popover as the tag filter.
@MainActor
struct SettingsSingleSelectionPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SettingsSelectionOption<Value>]
    let accessibilityLabel: String
    let identifier: String
    var missingSelectionTitle = "未选择"

    var body: some View {
        SettingsSelectionPopover(title: options.first { $0.value == selection }?.title ?? missingSelectionTitle,
            accessibilityLabel: accessibilityLabel, identifier: identifier) { height, dismiss in
            SettingsSingleSelectionMenu(selection: $selection, options: options,
                                        maximumHeight: height, dismiss: dismiss)
        }
    }
}

@MainActor
private struct SettingsSingleSelectionMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SettingsSelectionOption<Value>]
    let maximumHeight: CGFloat
    let dismiss: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(options, id: \.value) { option in
                        SettingsSelectionRow(title: option.title, selected: option.value == selection) {
                            if selection != option.value { selection = option.value }
                            dismiss()
                        }
                        .id(option.value)
                    }
                }
                .padding(4)
            }
            .frame(height: min(maximumHeight, CGFloat(options.count) * 28 + 8))
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }
}
