import AppKit
import ApplicationServices
import Foundation
import SwiftUI

extension Notification.Name {
    static let rcHarnessShowDashboard = Notification.Name("vip.tokenzz.rcharness.showDashboard")
}

@MainActor
final class RcHarnessApp: NSObject, NSApplicationDelegate {
    private var hid = XiaomiRemoteHIDManager()
    private var settingsDefaults: UserDefaults = .standard
    private lazy var voice = XiaomiRemoteVoice(defaults: settingsDefaults)
    private lazy var microphone = RemoteMicrophoneOutput(outputUID: { [weak self] in
        self?.dashboardModel?.outputUID ?? RemoteMicrophoneOutput.deviceUID
    })
    private let sender = SystemEventSender()
    private var renderDefaultsSuite: String?
    private var mapping = RemoteMapping.defaults
    private let gestures = RemoteGestureController()
    private var heldVoiceInput: ControllerInput?
    private var voiceStopInputs: Set<ControllerInput> = []
    private lazy var harnessSwitcher = HarnessSwitcherController(
        harnesses: { [weak self] in self?.dashboardModel?.harnesses ?? [] },
        onSelection: { [weak self] item in
            self?.dashboardModel?.matchApplication(item.application.applicationPath, bundleIdentifier: item.application.bundleIdentifier)
        },
        onError: { [weak self] message in self?.dashboardModel?.actionMessage = message }
    )
    private var macroWork: [DispatchWorkItem] = []
    private lazy var voiceSession = RemoteVoiceSessionController(output: microphone) { [weak self] mapping, pressed in
        if let shortcut = mapping.shortcutForVoice {
            self?.sender.sendShortcut(shortcut, pressed: pressed)
        }
    }
    private var mode: ControllerOperationMode = .mapping
    private var inputPermissionsWereReady = false
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var windowController: DashboardWindowController!
    private var dashboardModel: RemoteDashboardModel!
    private var shouldShowWindowAfterLaunch = false
    private var remoteSelectionRevision = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--render-settings") {
            let suite = "RcHarness.Render." + UUID().uuidString
            renderDefaultsSuite = suite
            settingsDefaults = UserDefaults(suiteName: suite)!
            if let flag = CommandLine.arguments.firstIndex(of: "--remote-profile"),
               CommandLine.arguments.count > flag + 1,
               let profile = RemoteProfiles.all.first(where: { $0.id == CommandLine.arguments[flag + 1] }) {
                settingsDefaults.set(profile.id, forKey: SettingsKeys.selectedRemoteProfileID)
            }
        }
        NSApp.setActivationPolicy(.regular)
        configureMenu()
        // The legacy per-device mapping only seeds the default profile on first launch.
        let initialMapping = RemoteMapping.legacy(profileID: RemoteProfiles.xiaomiRC003.id, defaults: settingsDefaults) ?? .defaults
        dashboardModel = RemoteDashboardModel(mapping: initialMapping, defaults: settingsDefaults)
        hid = XiaomiRemoteHIDManager(profiles: [dashboardModel.remoteProfile])
        voice = XiaomiRemoteVoice(profile: dashboardModel.remoteProfile, defaults: settingsDefaults)
        configureInput()
        statusMenu.item(withTag: 101)?.title = "RcHarness · \(dashboardModel.remoteProfile.model)"
        mapping = dashboardModel.effectiveMapping
        dashboardModel.onRemoteProfileChange = { [weak self] profile in
            self?.switchRemote(to: profile)
        }
        // Voice sessions and gestures capture their mapping at press time and
        // release exactly what they pressed. Profile switches (including the
        // foreground app changing mid-dictation) must not interrupt them.
        dashboardModel.onMappingChange = { [weak self] mapping in
            self?.mapping = mapping
        }
        dashboardModel.onHarnessesChange = { [weak self] in self?.harnessSwitcher.refresh() }
        dashboardModel.onInstallMicrophone = { [weak self] in self?.installMicrophone() }
        dashboardModel.onUninstallMicrophone = { [weak self] in self?.uninstallMicrophone() }
        dashboardModel.onRescan = { [weak self] in
            self?.harnessSwitcher.model.reset(reason: "rescan")
            self?.hid.rescan()
            self?.voice.stop()
            self?.voice.start()
        }
        dashboardModel.onToggleMode = { [weak self] in self?.toggleMode() }
        dashboardModel.onAudioChange = { [weak self] in
            self?.heldVoiceInput = nil
            self?.voiceSession.cancel()
            self?.voice.cancelActiveStream()
        }
        dashboardModel.onVoiceTriggerChange = { [weak self] in
            self?.heldVoiceInput = nil
            self?.voiceSession.cancel()
            self?.voice.cancelActiveStream()
        }
        dashboardModel.onGainChange = { [weak self] in self?.voice.gainDB = Float($0) }
        voice.gainDB = Float(dashboardModel.gain)
        microphone.onStateChange = { [weak self] state in
            self?.dashboardModel?.audioOutputState = state
            if case .failed(let message) = state {
                self?.dashboardModel?.actionMessage = message
                self?.heldVoiceInput = nil
                self?.voiceSession.cancel()
                self?.voice.cancelActiveStream()
            }
        }
        gestures.onOutput = { [weak self] mapping, pressed in self?.sendAction(mapping, pressed: pressed) }
        windowController = DashboardWindowController(model: dashboardModel)
        windowController.onWindowClose = { [weak self] in
            // Closing the only window leaves RcHarness running from the menu
            // bar, so it should no longer occupy a Dock slot.
            self?.setDockVisibility(false)
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showExistingWindow(_:)), name: .rcHarnessShowDashboard, object: String(getuid())
        )
        NSApp.setActivationPolicy(dashboardModel.showDockIcon ? .regular : .accessory)
        if renderSettingsIfRequested() { return }
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(self, selector: #selector(suspendVoice), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(resumeVoice), name: NSWorkspace.didWakeNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(foregroundApplicationChanged(_:)),
                                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if dashboardModel.openAtLaunch {
            // Finder/login-item launches can finish before AppKit has made the
            // process active. Defer the first presentation until the app is
            // active, then retry once from the next run-loop turn as a
            // fallback for launches that do not emit a separate activation
            // notification.
            shouldShowWindowAfterLaunch = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.shouldShowWindowAfterLaunch else { return }
                self.shouldShowWindowAfterLaunch = false
                self.showWindow()
            }
        }
        hid.start()
        voice.start()
        AudioDiagnostics.log("[RcHarness] voice permissions input=\(CGPreflightListenEventAccess()) accessibility=\(AXIsProcessTrusted())")
        inputPermissionsWereReady = dashboardModel.inputGranted && dashboardModel.accessibilityGranted
        if !dashboardModel.inputGranted || !dashboardModel.accessibilityGranted {
            dashboardModel.actionMessage = "语音按键权限未就绪，请到「权限」页面开启输入监控和辅助功能。"
        } else if dashboardModel.microphoneUpdateAvailable {
            dashboardModel.actionMessage = "麦克风组件有新版本，请在「连接与语音」中更新。"
        }
        updateStatusItem()
    }

    private func switchRemote(to profile: RemoteProfile) {
        remoteSelectionRevision += 1
        let revision = remoteSelectionRevision
        hid.onConnectionChange = nil
        hid.onButtonInput = nil
        hid.onButtonCancelled = nil
        hid.onSuppressionFailure = nil
        voice.onStatus = nil
        voice.onSamples = nil
        voice.onStreamEvent = nil
        voice.onVoiceButtonInput = nil
        harnessSwitcher.model.reset(reason: "remote-changed")
        gestures.cancel()
        cancelMacros()
        heldVoiceInput = nil
        voiceStopInputs.removeAll()
        hid.stop()
        voice.stop()
        voiceSession.cancel { [weak self] in
            guard let self, self.remoteSelectionRevision == revision else { return }
            self.hid = XiaomiRemoteHIDManager(profiles: [profile])
            self.voice = XiaomiRemoteVoice(profile: profile, defaults: self.settingsDefaults)
            self.voice.gainDB = Float(self.dashboardModel.gain)
            self.voice.enabled = self.mode == .mapping
            self.configureInput()
            self.hid.setOperationMode(self.mode)
            self.statusMenu.item(withTag: 101)?.title = "RcHarness · \(profile.model)"
            if self.renderDefaultsSuite == nil {
                self.hid.start()
                if profile.supportsBLEVoice { self.voice.start() }
            }
            self.updateStatusItem()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let model = dashboardModel, renderDefaultsSuite == nil else { return }
        if shouldShowWindowAfterLaunch {
            shouldShowWindowAfterLaunch = false
            showWindow()
        }
        model.refreshPermissions()
        let ready = model.inputGranted && model.accessibilityGranted
        if !inputPermissionsWereReady, ready {
            hid.rescan()
            model.actionMessage = "语音按键权限已就绪"
            AudioDiagnostics.log("[RcHarness] voice permissions restored; HID restarted")
        }
        inputPermissionsWereReady = ready
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if renderDefaultsSuite != nil { return .terminateNow }
        hid.stop()
        voice.stop()
        voiceSession.cancel {
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        harnessSwitcher.model.reset(reason: "termination")
        dashboardModel?.flushPendingWrites()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        gestures.cancel()
        cancelMacros()
        dashboardModel?.stopTestTone()
        dashboardModel?.setStreaming(false)
        heldVoiceInput = nil
        voiceSession.cancel()
        hid.stop()
        voice.stop()
        microphone.stop()
        if let renderDefaultsSuite { UserDefaults.standard.removePersistentDomain(forName: renderDefaultsSuite) }
    }

    /// Switch to the key profile bound to the newly active application.
    @objc private func foregroundApplicationChanged(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        harnessSwitcher.model.dismiss(reason: "foreground-application-changed")
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        dashboardModel?.matchApplication(app?.bundleURL?.path, bundleIdentifier: app?.bundleIdentifier)
    }

    @objc private func suspendVoice() {
        harnessSwitcher.model.reset(reason: "sleep")
        dashboardModel?.flushPendingWrites()
        gestures.cancel()
        cancelMacros()
        heldVoiceInput = nil
        voiceSession.cancel()
        dashboardModel?.stopTestTone()
        voice.stop()
        microphone.stop()
        AudioDiagnostics.log("[RcHarness] Xiaomi voice suspended for sleep")
    }

    @objc private func resumeVoice() {
        heldVoiceInput = nil
        voiceSession.cancel()
        voice.start()
        hid.rescan()
        AudioDiagnostics.log("[RcHarness] Xiaomi voice reconnecting after wake")
    }

    // Finder/Dock sends a reopen event when the app is already running. This
    // matters after the user closes the only window: the status item remains
    // alive, but a second double-click must bring the dashboard back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showWindow)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.image = MenuBarIcon.make()
        statusItem.button?.title = ""
        statusItem.button?.setAccessibilityLabel("RcHarness")
        updateStatusItem()
        statusMenu = NSMenu()
        statusMenu.addItem(NSMenuItem(title: "RcHarness · \(RemoteProfiles.xiaomiRC003.model)", action: nil, keyEquivalent: ""))
        statusMenu.items.last?.tag = 101
        let openItem = NSMenuItem(title: "打开 RcHarness", action: #selector(showWindow), keyEquivalent: "o")
        openItem.target = self
        statusMenu.addItem(openItem)
        statusMenu.addItem(.separator())
        let modeItem = NSMenuItem(title: "模式：映射", action: #selector(toggleMode), keyEquivalent: "")
        modeItem.target = self
        modeItem.tag = 100
        statusMenu.addItem(modeItem)
        let resetItem = NSMenuItem(title: "恢复当前方案的默认映射…", action: #selector(resetMapping), keyEquivalent: "")
        resetItem.target = self
        statusMenu.addItem(resetItem)
        statusMenu.addItem(.separator())
        for (title, url) in [("GitHub", AppInfo.repository), ("官网", AppInfo.website)] {
            let item = NSMenuItem(title: title, action: #selector(openProjectLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            statusMenu.addItem(item)
        }
        statusMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 RcHarness", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private func configureInput() {
        hid.onSuppressionFailure = { [weak self] message in
            self?.dashboardModel?.actionMessage = message
        }
        hid.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.dashboardModel?.setConnected(connected)
            if !connected {
                self.harnessSwitcher.model.reset(reason: "remote-disconnected")
                self.gestures.cancel()
                self.cancelMacros()
                self.heldVoiceInput = nil
                self.voiceStopInputs.removeAll()
                self.voiceSession.cancel()
                self.voice.cancelActiveStream()
                self.microphone.stop()
            }
            self.updateStatusItem()
        }
        hid.onButtonInput = { [weak self] input, pressed in
            self?.dashboardModel?.setInput(input, pressed: pressed)
            self?.handle(input: input, pressed: pressed)
        }
        hid.onButtonCancelled = { [weak self] input in
            guard let self else { return }
            self.gestures.cancel(input)
            if self.heldVoiceInput == input {
                self.heldVoiceInput = nil
                self.voiceSession.cancel()
                self.voice.cancelActiveStream()
            }
        }
        voice.onStatus = { [weak self] in
            guard let self else { return }
            self.hid.updateModelNumber(self.voice.detectedModelNumber)
            self.dashboardModel?.setVoice(status: self.voice.status, ready: self.voice.isReady,
                                         battery: self.hid.isConnected ? self.voice.batteryLevel : nil)
            self.dashboardModel?.voiceDiagnostics = self.voice.diagnostics
            self.dashboardModel?.microphoneInstalled = RemoteMicrophoneOutput.installed
            self.updateStatusItem()
        }
        voice.onVoiceButtonInput = { [weak self] pressed in
            self?.dashboardModel?.setInput(.options, pressed: pressed)
            self?.handle(input: .options, pressed: pressed)
        }
        voice.onStreamEvent = { [weak self] event in
            guard self?.harnessSwitcher.model.isPresented != true else { return }
            if case .started = event {
                self?.dashboardModel?.stopTestTone()
            }
            self?.dashboardModel?.setStreaming({ if case .started = event { return true }; return false }())
            if case .cancelled = event { self?.heldVoiceInput = nil }
            self?.voiceSession.handle(event)
        }
        voice.onSamples = { [weak self] samples in
            guard self?.harnessSwitcher.model.isPresented != true else { return }
            self?.voiceSession.append(samples)
        }
    }

    private func handle(input: ControllerInput, pressed: Bool) {
        if voiceStopInputs.contains(input) {
            if !pressed { voiceStopInputs.remove(input) }
            return
        }
        if mode == .mapping, pressed, heldVoiceInput != input, voiceSession.finishToggle() {
            heldVoiceInput = nil
            voiceStopInputs.insert(input)
            voice.releaseRemappedPress()
            return
        }
        let consumed = harnessSwitcher.model.handle(input, pressed: pressed)
        if input == dashboardModel?.globalButtons.input {
            Log.switcher.notice("Global input=\(input.rawValue, privacy: .public) down=\(pressed) consumed=\(consumed) mapping_mode=\(self.mode == .mapping) single=\(self.mapping[input, .single].action.rawValue, privacy: .public) double=\(self.mapping[input, .double].action.rawValue, privacy: .public) long=\(self.mapping[input, .long].action.rawValue, privacy: .public)")
        }
        if consumed { return }
        // Keep routing the fixed voice key release to its active session.
        if !pressed {
            if heldVoiceInput == input {
                heldVoiceInput = nil
                voiceSession.release()
            } else {
                gestures.handle(input, pressed: false, mapping: mapping)
            }
            return
        }
        if heldVoiceInput == input { return }
        if mode == .native || input != .options {
            gestures.handle(input, pressed: pressed, mapping: mapping)
            return
        }
        guard !voice.identityRejected else {
            heldVoiceInput = nil
            voiceSession.cancel()
            voice.cancelActiveStream()
            dashboardModel.actionMessage = voice.status
            return
        }
        AudioDiagnostics.log("[RcHarness] voice button down=\(pressed) action=\(mapping[.options].action.rawValue) tap=\(dashboardModel.voiceFnTap) accessibility=\(AXIsProcessTrusted())")
        if pressed {
            guard CGPreflightListenEventAccess(), AXIsProcessTrusted() else {
                heldVoiceInput = nil
                voiceSession.cancel()
                voice.cancelActiveStream()
                dashboardModel.actionMessage = "语音按键权限未就绪，请到「权限」页面开启输入监控和辅助功能。"
                return
            }
            guard heldVoiceInput == nil else { return }
            heldVoiceInput = input
            dashboardModel.stopTestTone()
            voice.prepareForPress(requestMicrophone: false)
            voiceSession.press(mapping: mapping[.options], fnTap: false, toggle: dashboardModel.voiceMode == .tap)
        }
    }

    private func sendAction(_ button: ButtonMapping, pressed: Bool) {
        if button.action == .openHarnessSwitcher {
            guard pressed, mode == .mapping else { return }
            if harnessSwitcher.model.isPresented {
                harnessSwitcher.model.dismiss(reason: "open-action-toggle")
            } else {
                harnessSwitcher.show()
                gestures.cancel()
                cancelMacros()
                heldVoiceInput = nil
                voiceSession.cancel()
                voice.cancelActiveStream()
            }
        } else if button.action == .switchToNativeMode {
            if pressed { setOperationMode(.native) }
        } else if button.action == .phrase {
            if pressed, let phrase = dashboardModel?.phrases.first(where: { $0.id.uuidString == button.referenceID }) { sender.typeText(phrase.text) }
        } else if button.action == .macro {
            if pressed, let macro = dashboardModel?.macros.first(where: { $0.id.uuidString == button.referenceID }) { runMacro(macro) }
        } else {
            sender.send(button, pressed: pressed)
        }
    }

    private func cancelMacros() {
        for work in macroWork { work.cancel() }
        macroWork.removeAll()
    }

    private func runMacro(_ macro: SavedMacro) {
        cancelMacros()
        let plan: MacroExecutionPlan
        do {
            plan = try MacroExecutionPlan(macro, macros: dashboardModel?.macros ?? [], phrases: dashboardModel?.phrases ?? [])
        } catch {
            dashboardModel?.actionMessage = error.localizedDescription
            return
        }
        let start = DispatchTime.now()
        for event in plan.events {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.mode == .mapping else { return }
                if let text = event.text { self.sender.typeText(text) }
                else {
                    self.sendAction(event.mapping, pressed: true)
                    self.sendAction(event.mapping, pressed: false)
                }
            }
            macroWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: start + event.offset, execute: work)
        }
    }

    @objc private func toggleMode() {
        setOperationMode(mode == .mapping ? .native : .mapping)
    }

    private func setOperationMode(_ newMode: ControllerOperationMode) {
        guard mode != newMode else { return }
        harnessSwitcher.model.reset(reason: "mode-changed")
        gestures.cancel()
        cancelMacros()
        heldVoiceInput = nil
        voiceStopInputs.removeAll()
        voiceSession.cancel()
        mode = newMode
        gestures.setOperationMode(mode)
        voice.enabled = mode == .mapping
        hid.setOperationMode(mode)
        dashboardModel?.operationMode = mode
        if mode == .native { microphone.stop() }
        if let item = statusMenu.item(withTag: 100) {
            item.title = mode == .mapping ? "模式：映射" : "模式：原生"
        }
        updateStatusItem()
    }

    @objc func resetMapping() {
        if let dashboardModel { SettingsDialogs.resetMapping(dashboardModel) }
    }

    @objc func installMicrophone() {
        Task { @MainActor in
            do {
                try await RemoteMicrophoneInstallation.install()
                dashboardModel?.refreshDevices()
                showAlert(title: "安装完成", message: "请在系统声音设置中选择 RcHarness 遥控器麦克风。")
            } catch is CancellationError {
                return
            } catch {
                showAlert(title: "安装失败", message: error.localizedDescription)
            }
        }
    }

    func uninstallMicrophone() {
        // Release the HAL device before coreaudiod unloads it.
        heldVoiceInput = nil
        voiceSession.cancel()
        voice.cancelActiveStream()
        dashboardModel?.stopTestTone()
        microphone.stop()
        Task { @MainActor in
            do {
                try await RemoteMicrophoneInstallation.uninstall()
                dashboardModel?.refreshDevices()
                showAlert(title: "已卸载", message: "RcHarness 麦克风组件已移除。语音应用中如仍选择该设备，请改为其他麦克风。")
            } catch is CancellationError {
                return
            } catch {
                showAlert(title: "卸载失败", message: error.localizedDescription)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func openProjectLink(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showExistingWindow(_ notification: Notification) { showWindow() }

    @objc private func showWindow() {
        harnessSwitcher.model.dismiss(reason: "dashboard-opened")
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        // Activate before ordering the window. On a cold Finder/login-item
        // launch, ordering first can leave the window behind the app that
        // launched RcHarness; a second Dock click then appears to fix it.
        setDockVisibility(dashboardModel?.showDockIcon == true)
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        windowController?.window?.orderFrontRegardless()
    }

    private func setDockVisibility(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }

    // Render actual SwiftUI pages without connecting hardware or changing permissions.
    private func renderSettingsIfRequested() -> Bool {
        guard let flag = CommandLine.arguments.firstIndex(of: "--render-settings"),
              CommandLine.arguments.count > flag + 1 else { return false }
        let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--narrow") { windowController.window?.setContentSize(SettingsStyle.minimumWindowSize) }
        NSApp.activate(ignoringOtherApps: true)
        let pages = SettingsPage.allCases
        func render(_ index: Int) {
            guard index <= pages.count + 4 else { NSApp.terminate(nil); return }
            let codexPreview = index == pages.count
            let switcherPreview = index == pages.count + 1
            let voiceEditorPreview = index == pages.count + 2
            let profileNamePreview = index >= pages.count + 3
            if switcherPreview {
                harnessSwitcher.showPreview(narrow: CommandLine.arguments.contains("--narrow"))
            } else if voiceEditorPreview || profileNamePreview {
                harnessSwitcher.model.dismiss(reason: "render-voice-editor")
                dashboardModel.page = .mapping
                dashboardModel.selectedInput = .options
                dashboardModel.selectedTrigger = .single
                windowController.window?.makeKeyAndOrderFront(nil)
            } else {
                if codexPreview {
                    dashboardModel.activateHarness("codex")
                    dashboardModel.page = .mapping
                } else {
                    dashboardModel.page = pages[index]
                }
                windowController.window?.makeKeyAndOrderFront(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                let filename = profileNamePreview ? (index == pages.count + 3 ? "profile-create" : "profile-rename") : voiceEditorPreview ? "voice-editor" : switcherPreview ? "harness-switcher" : codexPreview ? "mapping-codex" : pages[index].rawValue
                let voiceEditor = voiceEditorPreview ? NSHostingView(rootView: MappingEditorSheet(model: dashboardModel, actionFilter: .constant(.all))) : nil
                voiceEditor?.frame = NSRect(x: 0, y: 0, width: 560, height: 560)
                let isNewProfile = index == pages.count + 3
                let nameEditor = profileNamePreview ? NSHostingView(rootView: ProfileNameSheet(
                    title: isNewProfile ? "新建按键方案" : "重命名按键方案", symbol: isNewProfile ? "plus" : "pencil",
                    confirmTitle: isNewProfile ? "创建" : "保存", name: .constant(isNewProfile ? "" : dashboardModel.activeProfileName),
                    prefix: dashboardModel.profileDisplayPrefix, validateName: { _ in nil }, onCancel: {}, onConfirm: {})
                    .background(Color(nsColor: .windowBackgroundColor))) : nil
                nameEditor?.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
                if let view: NSView = nameEditor ?? voiceEditor ?? (switcherPreview ? harnessSwitcher.renderView : windowController.window?.contentView) {
                    view.layoutSubtreeIfNeeded()
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: directory.appendingPathComponent(filename + ".png"))
                        }
                    }
                }
                render(index + 1)
            }
        }
        render(0)
        return true
    }

    private func updateStatusItem() {
        DispatchQueue.main.async {
            let connection = self.hid.isConnected ? "遥控器已连接" : "遥控器未连接"
            let voice = self.voice.isReady ? " · 语音已就绪" : ""
            let mode = self.mode == .mapping ? "映射模式" : "原生模式"
            let description = "RcHarness · \(connection)\(voice) · \(mode)"
            self.statusItem.button?.toolTip = description
            self.statusItem.button?.setAccessibilityHelp(description)
        }
    }
}

@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    var onWindowClose: (() -> Void)?

    init(model: RemoteDashboardModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "RcHarness"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.center()
        window.isReleasedWhenClosed = false
        window.contentMinSize = SettingsStyle.minimumWindowSize
        super.init(window: window)
        window.delegate = self
        let hostingView = NSHostingView(rootView: RemoteDashboardView(model: model))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hostingView
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        onWindowClose?()
    }
}
