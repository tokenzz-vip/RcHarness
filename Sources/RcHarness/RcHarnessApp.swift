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
    private lazy var applicationSwitcher = ApplicationSwitcherController { [weak self] mapping, pressed in
        self?.sender.send(mapping, pressed: pressed)
    }
    private var heldVoiceInput: ControllerInput?
    private var voiceStopInputs: Set<ControllerInput> = []
    private lazy var harnessSwitcher = HarnessSwitcherController(
        harnesses: { [weak self] in self?.dashboardModel?.harnesses ?? [] },
        onSelection: { [weak self] item in
            self?.dashboardModel?.matchApplication(item.application.applicationPath, bundleIdentifier: item.application.bundleIdentifier)
        },
        onError: { [weak self] message in self?.dashboardModel?.postNotice(message, level: .error) }
    )
    private lazy var phrasePicker = PhrasePickerController { [weak self] text in
        self?.sender.typeText(text)
    }
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
        NSApp.appearance = dashboardModel.themeMode.appearance
        dashboardModel.onThemeModeChange = { NSApp.appearance = $0.appearance }
        hid = XiaomiRemoteHIDManager(profiles: [dashboardModel.remoteProfile])
        voice = XiaomiRemoteVoice(profile: dashboardModel.remoteProfile, defaults: settingsDefaults)
        voice.setVoiceMode(dashboardModel.voiceMode)
        hid.setVoiceMode(dashboardModel.voiceMode)
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
            self?.applicationSwitcher.reset()
            self?.harnessSwitcher.model.reset(reason: "rescan")
            self?.phrasePicker.model.reset()
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
            if let self {
                self.voice.setVoiceMode(self.dashboardModel.voiceMode)
                self.hid.setVoiceMode(self.dashboardModel.voiceMode)
            }
        }
        dashboardModel.onGainChange = { [weak self] in self?.voice.gainDB = Float($0) }
        voice.gainDB = Float(dashboardModel.gain)
        microphone.onStateChange = { [weak self] state in
            self?.dashboardModel?.audioOutputState = state
            if case .failed = state {
                self?.heldVoiceInput = nil
                self?.voiceSession.cancel()
                self?.voice.cancelActiveStream()
            }
        }
        gestures.onOutput = { [weak self] mapping, pressed, input in
            self?.sendAction(mapping, pressed: pressed, input: input)
        }
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
        dashboardModel.updates.start()
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
            dashboardModel.showVoicePermissionNotice()
        } else if dashboardModel.microphoneUpdateAvailable {
            dashboardModel.postNotice("麦克风组件有新版本，请在「连接与语音」中更新。", level: .warning,
                                      recoveryAction: .connection, source: .microphoneUpdate)
        }
        updateStatusItem()
        if dashboardModel.microphoneComponentPresent && dashboardModel.microphoneUpdateAvailable {
            DispatchQueue.main.async { [weak self] in self?.installMicrophone(synchronizing: true) }
        }
    }

    private func switchRemote(to profile: RemoteProfile) {
        applicationSwitcher.reset()
        remoteSelectionRevision += 1
        let revision = remoteSelectionRevision
        hid.onConnectionChange = nil
        hid.onProfileConnectionsChange = nil
        dashboardModel.setConnectedRemoteProfiles([])
        hid.onButtonInput = nil
        hid.onButtonCancelled = nil
        hid.onSuppressionFailure = nil
        voice.onStatus = nil
        voice.onSamples = nil
        voice.onStreamEvent = nil
        voice.onVoiceButtonInput = nil
        voice.onCaptureFailure = nil
        voice.canStartCapture = nil
        harnessSwitcher.model.reset(reason: "remote-changed")
        phrasePicker.model.reset()
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
            self.voice.setVoiceMode(self.dashboardModel.voiceMode)
            self.hid.setVoiceMode(self.dashboardModel.voiceMode)
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
            model.postNotice("语音按键权限已就绪", level: .success)
            AudioDiagnostics.log("[RcHarness] voice permissions restored; HID restarted")
        }
        inputPermissionsWereReady = ready
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if renderDefaultsSuite != nil { return .terminateNow }
        applicationSwitcher.reset()
        hid.stop()
        voice.stop()
        voiceSession.cancel {
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        applicationSwitcher.reset()
        harnessSwitcher.model.reset(reason: "termination")
        phrasePicker.model.reset()
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
        applicationSwitcher.confirm()
        harnessSwitcher.model.dismiss(reason: "foreground-application-changed")
        phrasePicker.model.dismiss()
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        dashboardModel?.matchApplication(app?.bundleURL?.path, bundleIdentifier: app?.bundleIdentifier)
    }

    @objc private func suspendVoice() {
        applicationSwitcher.reset()
        harnessSwitcher.model.reset(reason: "sleep")
        phrasePicker.model.reset()
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
        hid.onProfileConnectionsChange = { [weak self] ids in
            self?.dashboardModel?.setConnectedRemoteProfiles(ids)
        }
        hid.onSuppressionFailure = { [weak self] message in
            self?.dashboardModel?.postNotice(message, level: .error)
        }
        hid.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.dashboardModel?.setConnected(connected)
            if !connected {
                self.applicationSwitcher.reset()
                self.harnessSwitcher.model.reset(reason: "remote-disconnected")
                self.phrasePicker.model.reset()
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
            if input == .options, self?.voice.voiceMode == .tap, self?.applicationSwitcher.isPresented != true {
                self?.voice.receiveTapButton(pressed: pressed)
                return
            }
            self?.dashboardModel?.setInput(input, pressed: pressed)
            self?.handle(input: input, pressed: pressed)
        }
        hid.onButtonCancelled = { [weak self] input in
            guard let self else { return }
            self.applicationSwitcher.cancel(input)
            self.gestures.cancel(input)
            self.phrasePicker.model.cancel(input)
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
        voice.onCaptureFailure = { [weak self] message in
            self?.dashboardModel?.postNotice(message, level: .error, recoveryAction: .connection, source: .voiceConnection)
        }
        voice.canStartCapture = { [weak self] in
            guard let self else { return false }
            return self.mode == .mapping && self.voiceSession.isIdle
                && self.dashboardModel?.microphoneOperationInProgress != true
                && !self.harnessSwitcher.model.isPresented && !self.phrasePicker.model.isPresented
                && !self.applicationSwitcher.isPresented
        }
        voice.onStreamEvent = { [weak self] event in
            guard self?.harnessSwitcher.model.isPresented != true,
                  self?.applicationSwitcher.isPresented != true,
                  self?.phrasePicker.model.isPresented != true else { return }
            if case .started = event {
                self?.dashboardModel?.stopTestTone()
            }
            self?.dashboardModel?.setStreaming({ if case .started = event { return true }; return false }())
            if case .cancelled = event { self?.heldVoiceInput = nil }
            self?.voiceSession.handle(event)
        }
        voice.onSamples = { [weak self] samples in
            guard self?.harnessSwitcher.model.isPresented != true,
                  self?.applicationSwitcher.isPresented != true,
                  self?.phrasePicker.model.isPresented != true else { return }
            self?.voiceSession.append(samples)
        }
    }

    private func handle(input: ControllerInput, pressed: Bool) {
        if applicationSwitcher.handle(input, pressed: pressed) {
            // Keep the other modal routers' physical key tracking up to date.
            _ = phrasePicker.model.handle(input, pressed: pressed)
            _ = harnessSwitcher.model.handle(input, pressed: pressed)
            return
        }
        if voiceStopInputs.contains(input) {
            if !pressed { voiceStopInputs.remove(input) }
            return
        }
        if mode == .mapping, pressed, heldVoiceInput != input,
           voiceSession.finishToggle(waitForStreamEnd: dashboardModel.voiceMode == .tap) {
            heldVoiceInput = nil
            voiceStopInputs.insert(input)
            voice.releaseRemappedPress()
            return
        }
        let phraseConsumed = phrasePicker.model.handle(input, pressed: pressed)
        let switcherConsumed = harnessSwitcher.model.handle(input, pressed: pressed)
        let consumed = phraseConsumed || switcherConsumed
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
        guard !dashboardModel.microphoneOperationInProgress else { return }
        guard !voice.identityRejected else {
            heldVoiceInput = nil
            voiceSession.cancel()
            voice.cancelActiveStream()
            dashboardModel.postNotice(voice.status, level: .error, recoveryAction: .connection, source: .voiceConnection)
            return
        }
        AudioDiagnostics.log("[RcHarness] voice button down=\(pressed) action=\(mapping[.options].action.rawValue) tap=\(dashboardModel.voiceFnTap) accessibility=\(AXIsProcessTrusted())")
        if pressed {
            guard CGPreflightListenEventAccess(), AXIsProcessTrusted() else {
                heldVoiceInput = nil
                voiceSession.cancel()
                voice.cancelActiveStream()
                dashboardModel.showVoicePermissionNotice()
                return
            }
            guard heldVoiceInput == nil else { return }
            heldVoiceInput = input
            dashboardModel.stopTestTone()
            voice.prepareForPress(requestMicrophone: false)
            voiceSession.press(mapping: mapping[.options], fnTap: false, toggle: dashboardModel.voiceMode == .tap,
                               endToggleWithStream: dashboardModel.voiceMode == .tap)
        }
    }

    private func sendAction(_ button: ButtonMapping, pressed: Bool, input: ControllerInput? = nil) {
        if button.action == .switchApplications {
            guard pressed, mode == .mapping, let input else { return }
            harnessSwitcher.model.dismiss(reason: "application-switcher-opened")
            phrasePicker.model.dismiss()
            gestures.cancel()
            cancelMacros()
            heldVoiceInput = nil
            voiceSession.cancel()
            voice.cancelActiveStream()
            applicationSwitcher.present(input: input)
        } else if button.action == .openPhrases {
            guard pressed, mode == .mapping else { return }
            applicationSwitcher.cancel()
            if phrasePicker.model.isPresented {
                phrasePicker.model.dismiss()
            } else {
                harnessSwitcher.model.dismiss(reason: "phrases-opened")
                gestures.cancel()
                cancelMacros()
                heldVoiceInput = nil
                voiceSession.cancel()
                voice.cancelActiveStream()
                phrasePicker.show(phrases: dashboardModel.phrases, assignments: dashboardModel.phraseAssignments)
            }
        } else if button.action == .openHarnessSwitcher {
            guard pressed, mode == .mapping else { return }
            applicationSwitcher.cancel()
            if harnessSwitcher.model.isPresented {
                harnessSwitcher.model.dismiss(reason: "open-action-toggle")
            } else {
                phrasePicker.model.dismiss()
                harnessSwitcher.show(input: input)
                gestures.cancel()
                cancelMacros()
                heldVoiceInput = nil
                voiceSession.cancel()
                voice.cancelActiveStream()
            }
        } else if button.action == .switchToNativeMode {
            if pressed { setOperationMode(.native) }
        } else if button.action == .phrase {
            if pressed, let phrase = dashboardModel?.phrases.first(where: { $0.id.uuidString == button.referenceID }) {
                sender.typeText(phrase.text)
            }
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
            dashboardModel?.postNotice(error.localizedDescription, level: .error, recoveryAction: .macros)
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
        applicationSwitcher.reset()
        guard mode != newMode else { return }
        harnessSwitcher.model.reset(reason: "mode-changed")
        phrasePicker.model.reset()
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
        installMicrophone(synchronizing: false)
    }

    private func installMicrophone(synchronizing: Bool) {
        guard let dashboardModel, !dashboardModel.microphoneOperationInProgress else { return }
        guard !synchronizing || (dashboardModel.microphoneComponentPresent && dashboardModel.microphoneUpdateAvailable) else { return }
        dashboardModel.microphoneOperationInProgress = true
        // Release the device before replacement and the coreaudiod restart.
        heldVoiceInput = nil
        voiceSession.cancel()
        voice.cancelActiveStream()
        dashboardModel.stopTestTone()
        microphone.stop()
        Task { @MainActor in
            defer { dashboardModel.microphoneOperationInProgress = false }
            do {
                try await RemoteMicrophoneInstallation.install()
                dashboardModel.refreshDevices()
                if synchronizing {
                    dashboardModel.postNotice("虚拟麦克风组件已同步更新。系统音频服务已重启，请在语音应用中确认输入设备。", level: .success)
                    return
                }
                let receiver = dashboardModel.outputDevices.first { $0.id == dashboardModel.outputUID }?.name
                let alert = NSAlert()
                alert.messageText = "安装完成"
                alert.informativeText = VoiceSetupGuidance.installationComplete(receiverName: receiver)
                alert.addButton(withTitle: "打开连接与语音")
                alert.addButton(withTitle: "完成")
                if alert.runModal() == .alertFirstButtonReturn {
                    dashboardModel.page = .connection
                    showWindow()
                }
            } catch is CancellationError {
                if synchronizing {
                    dashboardModel.postNotice("麦克风组件更新已取消，可在「连接与语音」中继续更新。", level: .warning,
                                              recoveryAction: .connection, source: .microphoneUpdate)
                }
                return
            } catch {
                dashboardModel.postNotice("麦克风组件安装失败：\(error.localizedDescription)", level: .error,
                                          recoveryAction: .connection, source: .microphoneUpdate)
            }
        }
    }

    func uninstallMicrophone() {
        guard let dashboardModel, !dashboardModel.microphoneOperationInProgress else { return }
        dashboardModel.microphoneOperationInProgress = true
        // Release the HAL device before coreaudiod unloads it.
        heldVoiceInput = nil
        voiceSession.cancel()
        voice.cancelActiveStream()
        dashboardModel.stopTestTone()
        microphone.stop()
        Task { @MainActor in
            defer { dashboardModel.microphoneOperationInProgress = false }
            do {
                try await RemoteMicrophoneInstallation.uninstall()
                dashboardModel.refreshDevices()
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
        applicationSwitcher.cancel()
        harnessSwitcher.model.dismiss(reason: "dashboard-opened")
        phrasePicker.model.dismiss()
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
        dashboardModel.themeMode = CommandLine.arguments.contains("--dark") ? .dark : .light
        if CommandLine.arguments.contains("--narrow") { windowController.window?.setContentSize(SettingsStyle.minimumWindowSize) }
        NSApp.activate(ignoringOtherApps: true)
        dashboardModel.phrases = DefaultPhrases.all
        dashboardModel.phraseAssignments = DefaultPhrases.assignments(for: dashboardModel.phrases)
        // Include both remote families and records outside the recent window.
        func seedStatistics(historyDays: Int) {
            dashboardModel.usageStore.clear()
            let now = Date()
            let calendar = Calendar.current
            for offset in [0, 1, 2, 4, 6, historyDays] {
                guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
                for _ in 0..<(offset % 5 + 1) { dashboardModel.usageStore.record(.buttonA, at: date) }
                dashboardModel.usageStore.record(offset.isMultiple(of: 2) ? .buttonY : .netflix, at: date)
                dashboardModel.usageStore.recordVoice(seconds: Double(offset % 20 + 5), at: date)
            }
        }
        seedStatistics(historyDays: 400)
        let pages = SettingsPage.allCases
        func render(_ index: Int) {
            guard index <= pages.count + 19 else { NSApp.terminate(nil); return }
            let applicationSwitcherPreview = index == pages.count + 19
            let codexPreview = index == pages.count
            let switcherPreview = index == pages.count + 1
            let voiceEditorPreview = index == pages.count + 2
            let profileNamePreview = (pages.count + 3...pages.count + 4).contains(index)
            let phrasePreview = index == pages.count + 5
            let phraseEmptyPreview = index == pages.count + 6
            let rapidDeletePreview = index == pages.count + 7
            let configurationImportPreview = index == pages.count + 8
            let deletionPreview = index == pages.count + 9
            let deletionUndoPreview = index == pages.count + 10
            let permissionNoticePreview = index == pages.count + 11
            let permissionsDestinationPreview = index == pages.count + 12
            let importFailurePreview = index == pages.count + 13
            let importFailureDetailsPreview = index == pages.count + 14
            let audioFailurePreview = index == pages.count + 15
            let statisticsYearsPreview = index == pages.count + 16
            let statisticsMonthsPreview = index == pages.count + 17
            let macroEditorPreview = index == pages.count + 18
            if macroEditorPreview {
                for notice in dashboardModel.actionNotices { dashboardModel.dismissNotice(notice.id) }
                dashboardModel.page = .mapping
                dashboardModel.selectedInput = .buttonY
                dashboardModel.selectedTrigger = .long
                dashboardModel.update(ButtonMapping(action: .macro, referenceID: dashboardModel.macros.first?.id.uuidString),
                                      for: .buttonY, trigger: .long)
                windowController.window?.makeKeyAndOrderFront(nil)
            } else if statisticsYearsPreview || statisticsMonthsPreview {
                for notice in dashboardModel.actionNotices { dashboardModel.dismissNotice(notice.id) }
                dashboardModel.audioOutputState = .idle
                dashboardModel.page = .statistics
                seedStatistics(historyDays: statisticsMonthsPreview ? 60 : 400)
            } else if importFailurePreview {
                for notice in dashboardModel.actionNotices { dashboardModel.dismissNotice(notice.id) }
                dashboardModel.page = .about
                let details = (1...12).map {
                    "第 \($0) 项：配置文件包含无法识别的按键方案。请检查备份版本、文件访问权限，以及对应遥控器的方案设置。"
                }.joined(separator: "\n")
                dashboardModel.postNotice("导入失败：\n" + details + "\n错误详情结束。", level: .error,
                    recoveryAction: .configuration, source: .configurationImport)
            } else if importFailureDetailsPreview {
                dashboardModel.page = .about
            } else if audioFailurePreview {
                for notice in dashboardModel.actionNotices { dashboardModel.dismissNotice(notice.id) }
                dashboardModel.page = .connection
                dashboardModel.audioOutputState = .failed("无法启动所选接收设备：设备已断开或麦克风组件未加载。请刷新音频设备，重新选择接收设备，必要时重新安装麦克风组件后发送测试音。")
            } else if permissionNoticePreview {
                dashboardModel.dismissDeletionUndo()
                dashboardModel.page = .connection
                dashboardModel.showVoicePermissionNotice()
                windowController.window?.makeKeyAndOrderFront(nil)
            } else if permissionsDestinationPreview {
                dashboardModel.openPermissions()
                windowController.window?.makeKeyAndOrderFront(nil)
            } else if deletionPreview {
                let phrase = dashboardModel.phrases[0]
                let macro = dashboardModel.addMacro()
                dashboardModel.renameMacro(macro, name: "检查并提交结果")
                dashboardModel.updateMacroSteps([MacroStep(mapping: ButtonMapping(action: .phrase,
                    referenceID: phrase.id.uuidString))], for: macro)
                let originalRemoteID = dashboardModel.remoteProfile.id
                for profile in dashboardModel.availableRemoteProfiles.prefix(2) {
                    dashboardModel.selectRemoteProfile(profile.id)
                    dashboardModel.update(ButtonMapping(action: .phrase, referenceID: phrase.id.uuidString),
                                          for: .buttonA, trigger: .double)
                    dashboardModel.update(ButtonMapping(action: .macro, referenceID: macro.uuidString),
                                          for: .buttonB, trigger: .long)
                }
                dashboardModel.selectRemoteProfile(originalRemoteID)
                dashboardModel.page = .phrases
                windowController.window?.makeKeyAndOrderFront(nil)
            } else if deletionUndoPreview {
                dashboardModel.deleteConfigurationObject(.phrase(dashboardModel.phrases[0].id))
                dashboardModel.page = .phrases
                windowController.window?.makeKeyAndOrderFront(nil)
            } else if configurationImportPreview {
                dashboardModel.page = .about
                dashboardModel.phrases = DefaultPhrases.all
                dashboardModel.phraseAssignments = DefaultPhrases.assignments(for: dashboardModel.phrases)
                windowController.window?.makeKeyAndOrderFront(nil)
            } else if applicationSwitcherPreview {
                dashboardModel.page = .mapping
                dashboardModel.selectedInput = .home
                dashboardModel.selectedTrigger = .single
                dashboardModel.update(ButtonMapping(action: .switchApplications), for: .home, trigger: .single)
                windowController.window?.makeKeyAndOrderFront(nil)
            } else if rapidDeletePreview {
                dashboardModel.page = .mapping
                dashboardModel.selectedInput = .buttonB
                dashboardModel.selectedTrigger = .long
                dashboardModel.update(ButtonMapping(action: .rapidDelete), for: .buttonB, trigger: .long)
                windowController.window?.makeKeyAndOrderFront(nil)
            } else if phrasePreview {
                phrasePicker.show(phrases: dashboardModel.phrases, assignments: dashboardModel.phraseAssignments)
            } else if phraseEmptyPreview {
                phrasePicker.model.dismiss()
                dashboardModel.phrases = []
                dashboardModel.phraseAssignments = PhraseAssignments()
                dashboardModel.page = .phrases
                windowController.window?.makeKeyAndOrderFront(nil)
            } else if switcherPreview {
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
                let filename = applicationSwitcherPreview ? "application-switcher-editor" : macroEditorPreview ? "macro-editor" : statisticsMonthsPreview ? "statistics-all-months" : statisticsYearsPreview ? "statistics-all-years" : audioFailurePreview ? "audio-failure-notice" : importFailureDetailsPreview ? "import-failure-details" : importFailurePreview ? "import-failure-notice" : permissionsDestinationPreview ? "permissions-destination" : permissionNoticePreview ? "permission-notice" : deletionUndoPreview ? "deletion-undo" : deletionPreview ? "deletion-confirmation" : configurationImportPreview ? "configuration-import" : rapidDeletePreview ? "rapid-delete-editor" : phrasePreview ? "phrase-picker" : phraseEmptyPreview ? "phrases-empty" : profileNamePreview ? (index == pages.count + 3 ? "profile-create" : "profile-rename") : voiceEditorPreview ? "voice-editor" : switcherPreview ? "harness-switcher" : codexPreview ? "mapping-codex" : pages[index].rawValue
                let voiceEditor = voiceEditorPreview || rapidDeletePreview || macroEditorPreview || applicationSwitcherPreview ? NSHostingView(rootView: MappingEditorSheet(model: dashboardModel, actionFilter: .constant(applicationSwitcherPreview ? .system : .all))) : nil
                voiceEditor?.frame = NSRect(x: 0, y: 0, width: 560, height: macroEditorPreview ? 460 : 560)
                let isNewProfile = index == pages.count + 3
                let nameEditor = profileNamePreview ? NSHostingView(rootView: ProfileNameSheet(
                    title: isNewProfile ? "新建按键方案" : "重命名按键方案", symbol: isNewProfile ? "plus" : "pencil",
                    confirmTitle: isNewProfile ? "创建" : "保存", name: .constant(isNewProfile ? "" : dashboardModel.activeProfileName),
                    prefix: dashboardModel.profileDisplayPrefix, validateName: { _ in nil }, onCancel: {}, onConfirm: {})
                    .background(Color(nsColor: .windowBackgroundColor))) : nil
                nameEditor?.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
                var configurationEditor: NSView?
                if statisticsYearsPreview || statisticsMonthsPreview {
                    let content = NSHostingView(rootView: StatisticsPage(store: dashboardModel.usageStore, range: .all)
                        .padding(SettingsStyle.pagePadding)
                        .frame(width: (windowController.window?.contentView?.bounds.width ?? 1120) - SettingsStyle.sidebarWidth - 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(Color(nsColor: .controlBackgroundColor)))
                    content.frame.size = content.fittingSize
                    configurationEditor = content
                } else if importFailureDetailsPreview, let notice = dashboardModel.actionNotices.first {
                    let content = NSHostingView(rootView: ActionNoticeBanner(notice: notice,
                        count: dashboardModel.actionNotices.count, onDismiss: {}, onNext: {}, onRecovery: { _ in },
                        onCopy: {}, initiallyExpanded: true)
                        .padding(24)
                        .frame(width: 468)
                        .background(Color(nsColor: .controlBackgroundColor)))
                    content.frame.size = content.fittingSize
                    configurationEditor = content
                } else if deletionPreview {
                    let target = DeletionTarget.phrase(dashboardModel.phrases[0].id)
                    let pending = PendingDeletion(target: target, name: dashboardModel.phrases[0].displayTitle,
                        impact: dashboardModel.deletionImpact(for: target))
                    let content = NSHostingView(rootView: DeletionConfirmationSheet(model: dashboardModel, pending: pending)
                        .background(Color(nsColor: .windowBackgroundColor)))
                    content.frame.size = content.fittingSize
                    configurationEditor = content
                }
                if configurationImportPreview {
                    var backup = dashboardModel.configurationBackup()
                    backup.phrases = Array(backup.phrases.prefix(3))
                    if let prepared = try? PreparedConfiguration(backup, remoteProfile: dashboardModel.remoteProfile) {
                        let preview = ConfigurationImportPreview(source: "RcHarness-配置备份.json", isRecovery: false,
                            current: ConfigurationCounts(dashboardModel.configurationBackup()), prepared: prepared)
                        let content = NSHostingView(rootView: ConfigurationImportSheet(model: dashboardModel, preview: preview)
                            .background(Color(nsColor: .windowBackgroundColor)))
                        content.frame.size = content.fittingSize
                        configurationEditor = content
                    }
                }
                if let view: NSView = configurationEditor ?? nameEditor ?? voiceEditor ?? (phrasePreview ? phrasePicker.renderView : switcherPreview ? harnessSwitcher.renderView : windowController.window?.contentView) {
                    view.layoutSubtreeIfNeeded()
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: directory.appendingPathComponent(filename + ".png"))
                        }
                    }
                }
                if macroEditorPreview {
                    for width in [636, 456, 240, 180] {
                        let tags = NSHostingView(rootView: MacroTagFilter(selection: .constant(Set(MacroTag.all.map(\.id))))
                            .frame(width: CGFloat(width))
                            .padding(SettingsStyle.pagePadding)
                            .background(Color(nsColor: .controlBackgroundColor)))
                        tags.frame.size = tags.fittingSize
                        tags.layoutSubtreeIfNeeded()
                        if let bitmap = tags.bitmapImageRepForCachingDisplay(in: tags.bounds) {
                            tags.cacheDisplay(in: tags.bounds, to: bitmap)
                            if let data = bitmap.representation(using: .png, properties: [:]) {
                                try? data.write(to: directory.appendingPathComponent("macro-tags-\(width).png"))
                            }
                        }
                    }
                    for tagID in ["codex", "cursor", MacroTag.general.id] {
                        let picker = NSHostingView(rootView: MacroReferencePicker(
                            referenceID: .constant(dashboardModel.macros.first?.id.uuidString), tagIDs: .constant([tagID]), model: dashboardModel)
                            .padding(SettingsStyle.pagePadding)
                            .frame(width: 560)
                            .background(Color(nsColor: .controlBackgroundColor)))
                        picker.frame.size = picker.fittingSize
                        picker.layoutSubtreeIfNeeded()
                        if let bitmap = picker.bitmapImageRepForCachingDisplay(in: picker.bounds) {
                            picker.cacheDisplay(in: picker.bounds, to: bitmap)
                            if let data = bitmap.representation(using: .png, properties: [:]) {
                                try? data.write(to: directory.appendingPathComponent("macro-picker-" + tagID + ".png"))
                            }
                        }
                    }
                }
                if voiceEditorPreview {
                    // Export the same content used by the popover, including a
                    // constrained height to inspect the fixed action row.
                    for (name, mode, height, shortcut) in [
                        ("voice-keys-hold", VoiceTriggerMode.hold, VoiceShortcutPopoverLayout.height, dashboardModel.voiceHoldShortcut),
                        ("voice-keys-tap", .tap, VoiceShortcutPopoverLayout.height, VoiceShortcutChoice.pairs[6].shortcut),
                        ("voice-keys-compact", .tap, CGFloat(220), VoiceShortcutChoice.pairs[6].shortcut)
                    ] {
                        let panel = NSHostingView(rootView: VoiceShortcutSelectionPanel(mode: mode, shortcut: shortcut,
                            height: height, onCancel: {}, onConfirm: { _ in })
                            .background(Color(nsColor: .windowBackgroundColor)))
                        panel.frame = NSRect(x: 0, y: 0, width: VoiceShortcutPopoverLayout.width, height: height)
                        panel.layoutSubtreeIfNeeded()
                        if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                            panel.cacheDisplay(in: panel.bounds, to: bitmap)
                            if let data = bitmap.representation(using: .png, properties: [:]) {
                                try? data.write(to: directory.appendingPathComponent(name + ".png"))
                            }
                        }
                    }
                }
                if index < pages.count, pages[index] == .about {
                    // The general preferences sit below the window's initial scroll position.
                    // Export the complete page as well so every preference can be inspected.
                    let content = NSHostingView(rootView: AboutPage(model: dashboardModel)
                        .padding(SettingsStyle.pagePadding)
                        .frame(width: (windowController.window?.contentView?.bounds.width ?? 1120) - SettingsStyle.sidebarWidth - 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(Color(nsColor: .controlBackgroundColor)))
                    content.frame.size = content.fittingSize
                    content.layoutSubtreeIfNeeded()
                    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: directory.appendingPathComponent("about-content.png"))
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
    private let model: RemoteDashboardModel

    init(model: RemoteDashboardModel) {
        self.model = model
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
        // TextField and TextEditor use different AppKit editing notifications.
        for name in [NSControl.textDidEndEditingNotification, NSText.didEndEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(editorDidEndEditing(_:)), name: name, object: nil)
        }
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

    @objc private func editorDidEndEditing(_ notification: Notification) {
        guard let view = notification.object as? NSView, view.window === window else { return }
        model.flushPendingWrites()
    }

    func windowDidResignKey(_ notification: Notification) { model.flushPendingWrites() }

    func windowWillClose(_ notification: Notification) {
        model.flushPendingWrites()
        onWindowClose?()
    }
}
