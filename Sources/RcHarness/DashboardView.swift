import AppKit
import SwiftUI

/// Window root: sidebar, page header, message banner and page routing. Each
/// page lives in its own file; sheets shared by several pages are owned here.
struct RemoteDashboardView: View {
    @ObservedObject var model: RemoteDashboardModel
    @State private var actionFilter = ActionFilter.all
    @State private var statisticsRange = StatisticsRange.lastSevenDays
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
                if model.page == .mapping || model.page == .macros || model.page == .phrases {
                    // These pages own their bounded scrolling regions.
                    pageContent
                        .padding(SettingsStyle.pagePadding)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            pageContent
                                .padding(SettingsStyle.pagePadding)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .scrollIndicators(model.page == .statistics ? .never : .automatic)
                        .onAppear {
                            scrollToPermissions(using: proxy)
                            scrollToNoticeRecovery(using: proxy)
                        }
                        .onChange(of: model.permissionsNavigationRequest) { _, _ in
                            scrollToPermissions(using: proxy)
                        }
                        .onChange(of: model.noticeNavigationRequest?.id) { _, _ in
                            scrollToNoticeRecovery(using: proxy)
                        }
                    }
                    .id(model.page)
                }
                if model.page == .mapping { MappingFooter(model: model) }
                if let deleted = model.deletionUndoStack.last {
                    DeletionUndoBar(model: model, deleted: deleted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: SettingsStyle.minimumWindowSize.width, minHeight: SettingsStyle.minimumWindowSize.height)
        .tint(.blue)
        .overlay(alignment: .topTrailing) {
            if let notice = model.actionNotices.first {
                ActionNoticeBanner(notice: notice, count: model.actionNotices.count,
                                   onDismiss: { model.dismissNotice(notice.id) },
                                   onNext: model.showNextNotice,
                                   onRecovery: model.performNoticeRecovery,
                                   onCopy: { model.copy(notice.message) })
                    .id(notice.id)
                    .padding(.top, 92)
                    .padding(.trailing, SettingsStyle.pagePadding)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.actionNotices.first?.id)
        .sheet(isPresented: $model.editorVisible) { MappingEditorSheet(model: model, actionFilter: $actionFilter) }
        .sheet(item: $model.pendingConfigurationImport) { preview in
            ConfigurationImportSheet(model: model, preview: preview)
        }
        .sheet(item: $model.pendingDeletion) { pending in
            DeletionConfirmationSheet(model: model, pending: pending)
        }
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
    }

    private func openRenameSheet() {
        renameProfileDraft = model.activeProfileName
        renameProfileVisible = true
    }

    private func scrollToPermissions(using proxy: ScrollViewProxy) {
        guard model.page == .about, let request = model.permissionsNavigationRequest else { return }
        // Wait until the newly selected page has laid out its anchors.
        DispatchQueue.main.async {
            guard model.page == .about, model.permissionsNavigationRequest == request else { return }
            proxy.scrollTo(AboutPage.permissionsSectionID, anchor: .top)
            model.finishPermissionsNavigation(request)
        }
    }

    private func scrollToNoticeRecovery(using proxy: ScrollViewProxy) {
        guard let request = model.noticeNavigationRequest else { return }
        let anchor: String
        switch request.action {
        case .connection where model.page == .connection: anchor = ConnectionPage.audioSectionID
        case .configuration where model.page == .about: anchor = AboutPage.configurationSectionID
        default: return
        }
        let targetPage = model.page
        DispatchQueue.main.async {
            guard model.page == targetPage, model.noticeNavigationRequest?.id == request.id else { return }
            proxy.scrollTo(anchor, anchor: .top)
            model.finishNoticeNavigation(request.id)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text("RcHarness")
                    .font(.system(size: 15, weight: .semibold))
            }
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
        let selected = model.page == page || (page == .mapping && model.page == .phrases)
        return Button {
            model.page = page
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
        HStack(alignment: .center, spacing: SettingsStyle.Spacing.groups) {
            HStack(alignment: .center, spacing: 28) {
                Text(model.page.title).font(SettingsStyle.Typography.pageTitle)
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
                .pickerStyle(.segmented).frame(width: 230)
                Button("清除统计") { clearStatisticsVisible = true }
                    .buttonStyle(.bordered).controlSize(.small)
                Label("数据仅存本机", systemImage: "lock")
                    .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
            } else {
                deviceCard
            }
        }
        .padding(.horizontal, SettingsStyle.pagePadding).padding(.vertical, 18)
        .frame(height: SettingsStyle.pageHeaderHeight)
    }

    private var mappingToggle: some View {
        Toggle("启用遥控器映射", isOn: Binding(
            get: { model.operationMode == .mapping },
            set: { _ in model.toggleMode() }
        ))
        .toggleStyle(SettingsSwitchStyle()).controlSize(.small).font(SettingsStyle.Typography.body)
        .fixedSize()
        .help("关闭后，遥控器按原生方式工作；重新开启此开关可恢复映射。")
        .accessibilityHint("关闭后，遥控器按原生方式工作；重新开启此开关可恢复映射。")
    }

    private var deviceCard: some View {
        RemoteProfileMenu(model: model) {
            deviceCardLabel
        }
        .fixedSize()
        .help("更换遥控器")
        .accessibilityLabel("更换遥控器，当前：\(model.remoteProfile.shortName)")
        .accessibilityHint("选择要使用的遥控器型号")
    }

    private var deviceCardLabel: some View {
        HStack(spacing: SettingsStyle.Spacing.inline) {
            Image(systemName: "appletvremote.gen4.fill").font(.system(size: 24)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.remoteProfile.shortName).font(SettingsStyle.Typography.body.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(model.isConnected ? .green : .secondary).frame(width: 6, height: 6)
                    Text(model.isConnected ? "已连接" : "未连接")
                        .foregroundStyle(model.isConnected ? Color.green : Color.secondary)
                    if model.isConnected, let battery = model.batteryLevel {
                        Image(systemName: batterySymbol(for: battery))
                        Text("\(Int(battery * 100))%")
                    }
                }.font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.down")
                .font(SettingsStyle.Typography.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, SettingsStyle.controlPadding)
        }
        .foregroundStyle(.primary)
        .padding(SettingsStyle.controlPadding)
        .background(SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
        .overlay { RoundedRectangle(cornerRadius: SettingsStyle.controlRadius).strokeBorder(Color.primary.opacity(0.1)) }
        .contentShape(RoundedRectangle(cornerRadius: SettingsStyle.controlRadius))
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
        case .statistics: StatisticsPage(store: model.usageStore, range: statisticsRange)
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
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.groups) {
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
                        .padding(SettingsStyle.compactControlPadding)
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
        .padding(SettingsStyle.pagePadding)
        .frame(width: 420)
    }
}
