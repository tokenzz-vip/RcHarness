import AppKit
import SwiftUI

struct HarnessSettingsView: View {
    @ObservedObject var model: RemoteDashboardModel
    @State private var runningApplications: [NSRunningApplication] = []
    @State private var removalCandidate: HarnessConfiguration?

    var body: some View {
        VStack(spacing: SettingsStyle.Spacing.groups) {
            SettingsPanel {
                HStack(spacing: SettingsStyle.Spacing.inline) {
                    HarnessIcon(size: 15).foregroundStyle(.secondary)
                    Text("应用 Harness").font(SettingsStyle.Typography.panelTitle)
                }
                Text("当前遥控器：\(model.remoteProfile.shortName)。每个 Harness 可为不同遥控器分别绑定方案，同一方案可绑定多个 Harness。")
                    .font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
                ForEach(model.harnesses) { harness in
                    Divider()
                    applicationRow(harness)
                }
            }
            Label("停用会保留方案绑定；移除 Harness 后，按键方案仍会保留。", systemImage: "info.circle")
                .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: refreshApplications)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshApplications() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshApplications() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshApplications() }
        .confirmationDialog("移除应用 Harness？", isPresented: Binding(
            get: { removalCandidate != nil },
            set: { if !$0 { removalCandidate = nil } }
        ), titleVisibility: .visible, presenting: removalCandidate) { harness in
            Button("移除 Harness", role: .destructive) {
                model.removeHarness(harness.id)
                removalCandidate = nil
            }
            Button("取消", role: .cancel) { removalCandidate = nil }
        } message: { harness in
            Text("将移除「\(harness.name)」并解除方案绑定。按键方案和应用本身会保留。")
        }
    }

    private func applicationRow(_ harness: HarnessConfiguration) -> some View {
        let url = harness.installedApplicationURL
        let running = runningApplications.contains {
            harness.matches(applicationPath: $0.bundleURL?.path, bundleIdentifier: $0.bundleIdentifier)
        }
        let status = !harness.isEnabled ? "已停用" : running ? "运行中" : url == nil ? "未安装" : "未运行"
        return HStack(spacing: SettingsStyle.Spacing.controls) {
            Button {
                model.activateHarness(harness.id)
            } label: {
                HStack(spacing: SettingsStyle.Spacing.controls) {
                    applicationIcon(url)
                        .opacity(harness.isEnabled ? 1 : 0.45)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: SettingsStyle.Spacing.inline) {
                            Text(harness.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            // Reserve the badge's space so foreground changes never resize a row.
                            SettingsStatus(title: "当前", color: .accentColor)
                                .opacity(model.selectedHarnessID == harness.id ? 1 : 0)
                                .accessibilityHidden(model.selectedHarnessID != harness.id)
                        }
                        HStack(spacing: 5) {
                            Circle().fill(harness.isEnabled && running ? Color.green : Color.secondary).frame(width: 5, height: 5)
                            Text(status)
                            if harness.isBuiltIn { Text("· 内置") }
                        }.font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!harness.isEnabled || harness.profileID == nil)
            Spacer(minLength: 12)
            Picker("按键方案", selection: Binding(
                get: { model.harnesses.first(where: { $0.id == harness.id })?.profileID },
                set: { model.bindProfile($0, to: harness.id) }
            )) {
                Text("未绑定方案").tag(nil as UUID?)
                ForEach(model.profiles) { profile in
                    Text(model.profileDisplayName(profile))
                        .tag(Optional(profile.id))
                }
            }
            .labelsHidden().frame(width: 190)
            .help("仅显示「\(model.remoteProfile.shortName)」的按键方案")
            Button("编辑方案") {
                model.editHarnessProfile(harness.id)
            }
            .controlSize(.small).disabled(harness.profileID == nil)
            Toggle("启用 \(harness.name) Harness", isOn: Binding(
                get: { model.harnesses.first(where: { $0.id == harness.id })?.isEnabled ?? false },
                set: { model.setHarnessEnabled(harness.id, enabled: $0) }
            ))
            .labelsHidden().toggleStyle(SettingsSwitchStyle()).controlSize(.small)
            .help("启用 \(harness.name) Harness")
            Menu {
                Button("打开应用") { if let url { NSWorkspace.shared.open(url) } }.disabled(url == nil)
                if !harness.isBuiltIn {
                    Divider()
                    Button("移除 Harness…", role: .destructive) { removalCandidate = harness }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 18)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("\(harness.name) 的更多操作")
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder private func applicationIcon(_ url: URL?) -> some View {
        if let url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().scaledToFit().frame(width: 40, height: 40)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 24)).foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
                .accessibilityHidden(true)
        }
    }

    private func refreshApplications() {
        runningApplications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleURL != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }
}
