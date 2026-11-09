import AppKit
import SwiftUI

/// Window root: sidebar, page header, message banner and page routing. Each
/// page lives in its own file; sheets shared by several pages are owned here.
struct RemoteDashboardView: View {
    @ObservedObject var model: RemoteDashboardModel
    @State private var actionFilter = ActionFilter.all
    @State private var statisticsRange = StatisticsRange.week
    @State private var clearStatisticsVisible = false
    @State private var newProfileVisible = false
    @State private var newProfileName = ""
    @State private var renameProfileVisible = false
    @State private var renameProfileDraft = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: SettingsStyle.sidebarWidth)
            Color.primary.opacity(0.08).frame(width: 1)
            VStack(spacing: 0) {
                pageHeader
                Divider()
                if model.page == .mapping || model.page == .macros {
                    // These pages own their bounded scrolling regions.
                    pageContent
                        .padding(SettingsStyle.pagePadding)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        pageContent
                            .padding(SettingsStyle.pagePadding)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .scrollIndicators(model.page == .statistics ? .never : .automatic)
                    .id(model.page)
                }
                if model.page == .mapping { MappingFooter(model: model) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: SettingsStyle.minimumWindowSize.width, minHeight: SettingsStyle.minimumWindowSize.height)
        .tint(.blue)
        .overlay(alignment: .topTrailing) {
            if !model.actionMessage.isEmpty {
                messageBanner
                    .padding(.top, 92)
                    .padding(.trailing, 24)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.actionMessage)
        .sheet(isPresented: $model.editorVisible) { MappingEditorSheet(model: model, actionFilter: $actionFilter) }
        .sheet(isPresented: $newProfileVisible) {
            ProfileNameSheet(title: "新建按键方案", symbol: "plus", confirmTitle: "创建", name: $newProfileName,
                             prefix: model.profileDisplayPrefix,
                             validateName: { $0.isEmpty ? nil : model.profileNameError($0) }) {
                newProfileVisible = false
            } onConfirm: {
                if model.saveProfile(name: newProfileName) {
                    newProfileVisible = false
                    model.page = .mapping
                }
            }
        }
        .sheet(isPresented: $renameProfileVisible) {
            ProfileNameSheet(title: "重命名按键方案", symbol: "pencil", confirmTitle: "保存", name: $renameProfileDraft,
                             prefix: model.profileDisplayPrefix,
                             validateName: { model.profileNameError($0, excluding: model.selectedProfileID) }) {
                renameProfileVisible = false
            } onConfirm: {
                guard let id = model.selectedProfileID else { return }
                if model.renameProfile(id, name: renameProfileDraft) { renameProfileVisible = false }
            }
        }
        .confirmationDialog("清除使用统计？", isPresented: $clearStatisticsVisible, titleVisibility: .visible) {
            Button("清除统计", role: .destructive) { model.usageStore.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除所有按键次数和语音时长记录，且无法恢复。")
        }
        .onChange(of: model.page) { _, page in
            model.editorVisible = false
        }
        .onChange(of: model.actionMessage) { _, message in
            guard !message.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard model.actionMessage == message else { return }
                withAnimation { model.actionMessage = "" }
            }
        }
    }

    private func openRenameSheet() {
        renameProfileDraft = model.activeProfileName
        renameProfileVisible = true
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Text("RcHarness")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.top, 12).padding(.bottom, 20)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(SettingsPage.navigation) { page in navigationButton(page) }
                }
            }
            navigationButton(.statistics).padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func navigationButton(_ page: SettingsPage) -> some View {
        let selected = (model.page == .phrases ? .mapping : model.page) == page
        return Button {
            model.page = page
            model.actionMessage = ""
        } label: {
            VStack(spacing: 8) {
                Group {
                    if page == .harness {
                        HarnessIcon()
                    } else {
                        Image(systemName: page.symbol)
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 22, weight: .regular))
                    }
                }.frame(width: 28, height: 28)
                Text(page.shortTitle).font(.system(size: 12, weight: .medium)).frame(height: 16)
            }
            .frame(maxWidth: .infinity).frame(height: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.76))
        .background(selected ? Color.accentColor.opacity(0.10) : .clear)
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .center, spacing: 28) {
                Text(model.page.title).font(.system(size: 25, weight: .bold))
                if model.page != .statistics {
                    mappingToggle
                }
            }
            .fixedSize()
            Spacer(minLength: 8)
            if model.page == .statistics {
                Picker("时间范围", selection: $statisticsRange) {
                    ForEach(StatisticsRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 180)
                Button("清除统计") { clearStatisticsVisible = true }
                    .buttonStyle(.bordered).controlSize(.small)
                Label("数据仅存本机", systemImage: "lock")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                deviceCard
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .frame(minHeight: 82)
    }

    private var mappingToggle: some View {
        Toggle("启用遥控器映射", isOn: Binding(
            get: { model.operationMode == .mapping },
            set: { _ in model.toggleMode() }
        ))
        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
        .fixedSize()
        .help("关闭后，遥控器按原生方式工作；重新开启此开关可恢复映射。")
        .accessibilityHint("关闭后，遥控器按原生方式工作；重新开启此开关可恢复映射。")
    }

    private var deviceCard: some View {
        Menu {
            RemoteProfileMenuItems(model: model)
        } label: {
            deviceCardLabel
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更换遥控器")
        .accessibilityLabel("更换遥控器，当前：\(model.remoteProfile.shortName)")
        .accessibilityHint("选择要使用的遥控器型号")
    }

    private var deviceCardLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "appletvremote.gen4.fill").font(.system(size: 24)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.remoteProfile.shortName).font(.system(size: 12, weight: .semibold))
                HStack(spacing: 6) {
                    Circle().fill(model.isConnected ? .green : .secondary).frame(width: 6, height: 6)
                    Text(model.isConnected ? "已连接" : "未连接")
                        .foregroundStyle(model.isConnected ? Color.green : Color.secondary)
                    if model.isConnected, let battery = model.batteryLevel {
                        Image(systemName: batterySymbol(for: battery))
                        Text("\(Int(battery * 100))%")
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
        }
        .foregroundStyle(.primary)
        .padding(12)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.25)) }
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var messageBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
            Text(model.actionMessage).font(.system(size: 12)).textSelection(.enabled).lineLimit(2)
            Spacer()
            Button { model.actionMessage = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.3)) }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
    }

    @ViewBuilder private var pageContent: some View {
        switch model.page {
        case .mapping: MappingPage(model: model, onRenameProfile: openRenameSheet)
        case .harness: HarnessSettingsView(model: model)
        case .connection: ConnectionPage(model: model)
        case .macros: MacrosPage(model: model, actionFilter: $actionFilter)
        case .profiles:
            ProfilesPage(model: model) {
                newProfileName = ""
                newProfileVisible = true
            } onDuplicate: { id in
                guard model.duplicateProfile(id) != nil else { return }
                model.page = .mapping
                // Present after the page switch so the sheet attaches to the new page.
                DispatchQueue.main.async { openRenameSheet() }
            }
        case .phrases: PhrasesPage(model: model)
        case .about: AboutPage(model: model)
        case .statistics: StatisticsPage(store: model.usageStore, range: statisticsRange, inputs: model.remoteProfile.inputs)
        }
    }
}

/// Name entry for creating or renaming a key profile, with inline validation.
@MainActor
struct ProfileNameSheet: View {
    let title: String
    let symbol: String
    let confirmTitle: String
    @Binding var name: String
    var prefix: String = ""
    let validateName: (String) -> String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    // Sheet content can outlive the parent's render. Read the binding here so
    // the field, validation message and submit state always use the same draft.
    var error: String? { validateName(name) }
    var canConfirm: Bool {
        error == nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: symbol)
                .font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    if !prefix.isEmpty {
                        Text(prefix)
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                            .help("遥控器固定前缀，不可修改或删除")
                            .accessibilityLabel("固定前缀 \(prefix)，不可修改或删除")
                    }
                    TextField("方案名称", text: $name)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .onSubmit { if canConfirm { onConfirm() } }
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
