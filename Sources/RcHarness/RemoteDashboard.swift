import AppKit
import ApplicationServices
import AVFoundation
import CoreBluetooth
import ServiceManagement
import SwiftUI

/// Settings and dashboard state. Profiles own their mappings; shared buttons
/// are overlaid only when resolving the effective mapping for the device.
/// High-frequency state lives in `live` and `usageStore`, so a button press
/// re-renders only the views that show it.
@MainActor
final class RemoteDashboardModel: ObservableObject {
    @Published var page: SettingsPage = .mapping {
        didSet { if page != oldValue { flushPendingWrites() } }
    }
    @Published private(set) var permissionsNavigationRequest: UUID?
    @Published private(set) var noticeNavigationRequest: ActionNotice.NavigationRequest?
    @Published var isConnected = false
    @Published private(set) var connectedRemoteProfileIDs: Set<String> = []
    @Published var operationMode: ControllerOperationMode = .mapping
    @Published var voiceStatus = "遥控器麦克风未连接"
    @Published var voiceReady = false
    var voiceDiagnostics = ""
    @Published var isStreaming = false
    @Published var audioOutputState: RemoteAudioOutputState = .idle {
        didSet {
            switch audioOutputState {
            case .failed(let message):
                postNotice(message, level: .error, recoveryAction: .connection, source: .audioOutput)
            case .streaming:
                resolveNotices(from: .audioOutput)
            default: break // Cancellation/idle does not prove that the fault is fixed.
            }
        }
    }
    @Published var batteryLevel: Float?
    @Published var microphoneInstalled = RemoteMicrophoneOutput.installed
    /// The HAL plug-in exists on disk (it may not be loaded until coreaudiod restarts).
    @Published var microphoneComponentPresent = RemoteMicrophoneInstallation.isInstalledOnDisk
    @Published var microphoneUpdateAvailable = RemoteMicrophoneInstallation.updateRequired
    @Published private(set) var globalButtons: GlobalButtonSettings {
        didSet {
            guard !isCommittingConfiguration else { return }
            settingsWrites.save(globalButtons, SettingsKeys.Stored.globalButtons)
            persistRemoteKeyConfiguration()
            if !isRestoringRemoteConfiguration { onMappingChange?(effectiveMapping) }
        }
    }
    @Published var mapping: RemoteMapping
    @Published private(set) var actionNotices: [ActionNotice] = []
    var actionMessage: String { actionNotices.first?.message ?? "" }
    var actionOpensPermissions: Bool { actionNotices.first?.recoveryAction == .permissions }
    private let settingsWrites: SettingsWriteBuffer
    private let noticeSchedule: RemoteVoiceSessionController.Scheduler
    private var noticeDismissals: [UUID: DispatchWorkItem] = [:]
    @Published var pendingConfigurationImport: ConfigurationImportPreview?
    @Published private(set) var configurationRecoveryDate: Date?
    @Published var pendingDeletion: PendingDeletion?
    @Published var deletionUndoStack: [DeletedConfigurationObject] = []
    @Published var selectedInput: ControllerInput = .buttonA
    @Published var selectedTrigger: ButtonTrigger = .single
    @Published var editorVisible = false
    /// Only the selected remote's schemes are exposed to editors and pickers.
    @Published private(set) var profiles: [SavedKeyProfile] {
        didSet {
            guard !isCommittingConfiguration else { return }
            settingsWrites.save(profiles, SettingsKeys.Stored.profiles)
            persistRemoteKeyConfiguration()
        }
    }
    @Published private(set) var macros: [SavedMacro] {
        didSet {
            guard !isCommittingConfiguration else { return }
            settingsWrites.debounce(SettingsKeys.Stored.macros) { [weak self] in self?.macros ?? [] }
        }
    }
    @Published var phrases: [SavedPhrase] {
        didSet {
            guard !isCommittingConfiguration else { return }
            settingsWrites.debounce(SettingsKeys.Stored.phrases) { [weak self] in self?.phrases ?? [] }
        }
    }
    @Published var phraseAssignments: PhraseAssignments {
        didSet { if !isCommittingConfiguration { settingsWrites.save(phraseAssignments, SettingsKeys.Stored.phraseAssignments) } }
    }
    @Published private(set) var harnesses: [HarnessConfiguration] {
        didSet {
            guard !isCommittingConfiguration else { return }
            settingsWrites.save(harnesses, SettingsKeys.Stored.harnesses)
            persistRemoteKeyConfiguration()
            if !isRestoringRemoteConfiguration { onHarnessesChange?() }
        }
    }
    @Published private(set) var selectedHarnessID: String? {
        didSet {
            guard !isCommittingConfiguration, selectedHarnessID != oldValue else { return }
            defaults.set(selectedHarnessID, forKey: SettingsKeys.selectedHarnessID)
            persistRemoteKeyConfiguration()
        }
    }
    @Published private(set) var selectedProfileID: UUID? {
        didSet {
            guard !isCommittingConfiguration, selectedProfileID != oldValue else { return }
            defaults.set(selectedProfileID?.uuidString, forKey: SettingsKeys.selectedProfileID)
            persistRemoteKeyConfiguration()
        }
    }
    @Published var outputDevices: [RemoteAudioDevice] = []
    @Published var outputUID: String { didSet { stopTestTone(); defaults.set(outputUID, forKey: SettingsKeys.outputUID); onAudioChange?() } }
    @Published var gain: Double {
        didSet {
            let normalized = gain.isFinite ? min(24, max(0, gain)) : 0
            // Only write back when normalization is needed. An unconditional
            // self-assignment here re-enters didSet forever and exhausts the
            // main thread stack when the slider changes.
            if gain != normalized {
                gain = normalized
                return
            }
            defaults.set(gain, forKey: SettingsKeys.gain)
            onGainChange?(gain)
        }
    }
    var voiceFnTap: Bool {
        get { remoteProfile.supportsVoiceTap && globalButtons.voiceFnTap }
        set {
            var settings = globalButtons
            settings.voiceFnTap = newValue
            let normalized = settings.normalized(for: remoteProfile)
            guard normalized != globalButtons else { return }
            globalButtons = normalized
            onVoiceTriggerChange?()
        }
    }
    var voiceMode: VoiceTriggerMode {
        get { remoteProfile.supportsVoiceTap ? (globalButtons.voiceMode ?? .hold) : .hold }
        set {
            var settings = globalButtons
            settings.voiceMode = newValue
            setGlobalButtons(settings)
        }
    }
    var voiceHoldShortcut: RecordedShortcut {
        get { globalButtons.holdShortcut }
        set { update(ButtonMapping(action: .recordedShortcut, shortcut: newValue), for: .options, trigger: .single) }
    }
    var voiceTapShortcut: RecordedShortcut {
        get { globalButtons.voiceTapShortcut ?? .voiceTapDefault }
        set {
            var settings = globalButtons
            settings.voiceTapShortcut = newValue
            setGlobalButtons(settings)
        }
    }
    @Published var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: SettingsKeys.showDockIcon); NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory) } }
    @Published var showKeyProfilePrefix: Bool { didSet { defaults.set(showKeyProfilePrefix, forKey: SettingsKeys.showKeyProfilePrefix) } }
    @Published var openAtLaunch: Bool { didSet { defaults.set(openAtLaunch, forKey: SettingsKeys.openAtLaunch) } }
    @Published var themeMode: AppThemeMode {
        didSet {
            defaults.set(themeMode.rawValue, forKey: SettingsKeys.themeMode)
            onThemeModeChange?(themeMode)
        }
    }
    @Published private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var inputGranted = CGPreflightListenEventAccess()
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var bluetoothGranted = CBManager.authorization == .allowedAlways

    let live = RemoteLiveStatus()
    let usageStore: UsageStore
    var pressedInputs: Set<ControllerInput> { live.pressedInputs }

    private var voiceStartedAt: TimeInterval?
    private let monotonicTime: () -> TimeInterval
    private var testOutput: RemoteMicrophoneOutput?
    let defaults: UserDefaults
    @Published private(set) var remoteProfile: RemoteProfile
    let availableRemoteProfiles: [RemoteProfile]
    private var deviceObserver: NSObjectProtocol?
    private var remoteKeyConfigurations: [String: RemoteKeyConfiguration] = [:]
    private var isRestoringRemoteConfiguration = true
    private var isCommittingConfiguration = false
    private var isUpdatingKeySelection = false

    var onMappingChange: ((RemoteMapping) -> Void)?
    var onHarnessesChange: (() -> Void)?
    var onInstallMicrophone: (() -> Void)?
    var onUninstallMicrophone: (() -> Void)?
    var onRescan: (() -> Void)?
    var onToggleMode: (() -> Void)?
    var onAudioChange: (() -> Void)?
    var onGainChange: ((Double) -> Void)?
    var onVoiceTriggerChange: (() -> Void)?
    var onRemoteProfileChange: ((RemoteProfile) -> Void)?
    var onThemeModeChange: ((AppThemeMode) -> Void)?

    /// - Parameter mapping: used only on first launch, as the default profile's mapping.
    init(mapping: RemoteMapping, defaults: UserDefaults = .standard, remoteProfile: RemoteProfile = RemoteProfiles.xiaomiRC003,
         availableRemoteProfiles: [RemoteProfile] = RemoteProfiles.all,
         monotonicTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         noticeSchedule: @escaping RemoteVoiceSessionController.Scheduler = RemoteVoiceSessionController.mainQueue,
         settingsSchedule: @escaping RemoteVoiceSessionController.Scheduler = RemoteVoiceSessionController.mainQueue) {
        self.defaults = defaults
        self.monotonicTime = monotonicTime
        self.noticeSchedule = noticeSchedule
        self.settingsWrites = SettingsWriteBuffer(defaults: defaults, schedule: settingsSchedule)
        self.availableRemoteProfiles = availableRemoteProfiles.contains(where: { $0.id == remoteProfile.id })
            ? availableRemoteProfiles : [remoteProfile] + availableRemoteProfiles
        let remoteProfile = self.availableRemoteProfiles.first { $0.id == defaults.string(forKey: SettingsKeys.selectedRemoteProfileID) } ?? remoteProfile
        self.remoteProfile = remoteProfile
        self.mapping = mapping
        globalButtons = GlobalButtonSettings()
        // Configurations saved before profiles owned the default mapping kept it separately.
        let legacyDefaultMapping = SettingsStorage.load(RemoteMapping.self, SettingsKeys.Stored.legacyBaseMapping, defaults: defaults) ?? mapping
        profiles = SettingsStorage.load([SavedKeyProfile].self, SettingsKeys.Stored.profiles, defaults: defaults) ?? []
        macros = SavedMacro.normalizingNames(in: SettingsStorage.load([SavedMacro].self, SettingsKeys.Stored.macros, defaults: defaults) ?? [])
        phrases = SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults) ?? []
        phraseAssignments = SettingsStorage.load(PhraseAssignments.self, SettingsKeys.Stored.phraseAssignments, defaults: defaults) ?? PhraseAssignments()
        usageStore = UsageStore(defaults: defaults)
        harnesses = SettingsStorage.load([HarnessConfiguration].self, SettingsKeys.Stored.harnesses, defaults: defaults) ?? HarnessConfiguration.defaults
        selectedHarnessID = defaults.string(forKey: SettingsKeys.selectedHarnessID)
        let savedGain = defaults.double(forKey: SettingsKeys.gain)
        gain = savedGain.isFinite ? min(24, max(0, savedGain)) : 0
        outputUID = defaults.string(forKey: SettingsKeys.outputUID) ?? RemoteMicrophoneOutput.deviceUID
        showDockIcon = defaults.object(forKey: SettingsKeys.showDockIcon) as? Bool ?? true
        showKeyProfilePrefix = defaults.bool(forKey: SettingsKeys.showKeyProfilePrefix)
        openAtLaunch = defaults.object(forKey: SettingsKeys.openAtLaunch) as? Bool ?? true
        themeMode = defaults.string(forKey: SettingsKeys.themeMode).flatMap(AppThemeMode.init(rawValue:)) ?? .system
        selectedProfileID = defaults.string(forKey: SettingsKeys.selectedProfileID).flatMap(UUID.init(uuidString:))
        let legacyBindings = defaults.integer(forKey: SettingsKeys.profileBindingsVersion) < 2
        let hasSavedConfiguration = SettingsStorage.contains(SettingsKeys.Stored.harnesses, defaults: defaults)
            || SettingsStorage.contains(SettingsKeys.Stored.profiles, defaults: defaults)
        // Detect legacy settings before normalization writes the initial profiles.
        let hasLegacyGlobalSettings = hasSavedConfiguration || legacyDefaultMapping != .defaults
            || SettingsStorage.contains(SettingsKeys.Stored.legacyBaseMapping, defaults: defaults)
            || RemoteProfiles.all.contains { SettingsStorage.contains(SettingsKeys.Stored.legacyMapping(profileID: $0.id), defaults: defaults) }
            || defaults.object(forKey: SettingsKeys.voiceFnTap) != nil
        settingsWrites.batch {
            initializeDefaultMacros(version: configurationMacroPresetsVersion)
            initializeDefaultPhrases()
            remoteKeyConfigurations = SettingsStorage.load([String: RemoteKeyConfiguration].self,
                                                           SettingsKeys.Stored.remoteKeyConfigurations, defaults: defaults)?.mapValues { $0.normalized() } ?? [:]
            let remoteConfiguration = remoteKeyConfigurations[remoteProfile.id]
            if remoteConfiguration != nil || !remoteKeyConfigurations.isEmpty {
                restoreRemoteKeyConfiguration(remoteConfiguration)
            }
            normalizeProfiles(migrateLegacy: remoteKeyConfigurations.isEmpty && legacyBindings && hasSavedConfiguration,
                              defaultMapping: remoteKeyConfigurations.isEmpty ? legacyDefaultMapping : .defaults)
            if let harness = harnesses.first(where: { $0.id == selectedHarnessID && $0.isEnabled }),
               let profile = profiles.first(where: { $0.id == harness.profileID }) {
                selectedProfileID = profile.id
                self.mapping = profile.mapping
            } else {
                selectedHarnessID = nil
                let profile = profiles.first(where: { $0.id == selectedProfileID }) ?? profiles[0]
                selectedProfileID = profile.id
                self.mapping = profile.mapping
            }
            globalButtons = remoteConfiguration?.globalButtons
                ?? (!remoteKeyConfigurations.isEmpty ? GlobalButtonSettings() : SettingsStorage.load(GlobalButtonSettings.self, SettingsKeys.Stored.globalButtons, defaults: defaults))
                ?? (hasLegacyGlobalSettings
                    ? .migrating(self.mapping, voiceFnTap: defaults.bool(forKey: SettingsKeys.voiceFnTap))
                    : GlobalButtonSettings())
            globalButtons = globalButtons.normalized(for: remoteProfile)
            isRestoringRemoteConfiguration = false
            settingsWrites.save(globalButtons, SettingsKeys.Stored.globalButtons)
            persistProfileConfiguration()
            settingsWrites.save(macros, SettingsKeys.Stored.macros)
        }
        configurationRecoveryDate = SettingsStorage.configurationRecovery(defaults: defaults)?.date
        refreshDevices()
        deviceObserver = NotificationCenter.default.addObserver(
            forName: .rcHarnessAudioDevicesChanged, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshDevices() } }
    }

    deinit {
        noticeDismissals.values.forEach { $0.cancel() }
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
    }

    /// Flush before editor focus loss, window close, application exit or sleep.
    func flushPendingWrites() {
        settingsWrites.flush()
        usageStore.flush()
    }

    func setConnected(_ connected: Bool) {
        isConnected = connected
        if !connected {
            batteryLevel = nil
            live.pressedInputs.removeAll()
            setStreaming(false)
        }
    }

    func setConnectedRemoteProfiles(_ ids: Set<String>) {
        let supported = ids.intersection(availableRemoteProfiles.map(\.id))
        if connectedRemoteProfileIDs != supported { connectedRemoteProfileIDs = supported }
    }

    func isRemoteConnected(_ profile: RemoteProfile) -> Bool {
        profile.id == remoteProfile.id ? isConnected : connectedRemoteProfileIDs.contains(profile.id)
    }

    func selectRemoteProfile(_ id: String) {
        guard let profile = availableRemoteProfiles.first(where: { $0.id == id }),
              profile.id != remoteProfile.id else { return }
        cancelConfigurationImport()
        stopTestTone()
        editorVisible = false
        setConnected(false)
        setVoice(status: "遥控器麦克风未连接", ready: false, battery: nil)
        voiceDiagnostics = ""
        settingsWrites.batch {
            persistRemoteKeyConfiguration()
            isRestoringRemoteConfiguration = true
            remoteProfile = profile
            restoreRemoteKeyConfiguration(remoteKeyConfigurations[profile.id])
            normalizeProfiles(migrateLegacy: false, defaultMapping: .defaults)
            restoreKeySelection()
            globalButtons = globalButtons.normalized(for: profile)
            isRestoringRemoteConfiguration = false
            if !profile.inputs.contains(selectedInput) { selectedInput = .buttonA }
            defaults.set(profile.id, forKey: SettingsKeys.selectedRemoteProfileID)
            // The legacy unscoped key must not be reused after a profile switch;
            // profile-scoped keys retain each model's remembered peripheral.
            defaults.removeObject(forKey: SettingsKeys.voicePeripheralUUID)
            persistProfileConfiguration()
        }
        onRemoteProfileChange?(profile)
        onHarnessesChange?()
        onMappingChange?(effectiveMapping)
    }
    func setInput(_ input: ControllerInput, pressed: Bool) {
        if pressed {
            if live.pressedInputs.insert(input).inserted { usageStore.record(input) }
            // Assign only on change: every @Published write re-renders the dashboard.
            if !editorVisible, selectedInput != input { selectedInput = input }
        } else {
            live.pressedInputs.remove(input)
        }
    }
    func setVoice(status: String, ready: Bool, battery: Float?) {
        if voiceStatus != status { voiceStatus = status }
        if voiceReady != ready { voiceReady = ready }
        if ready { resolveNotices(from: .voiceConnection) }
        if batteryLevel != battery { batteryLevel = battery }
    }
    func setStreaming(_ active: Bool) {
        if active, !isStreaming { voiceStartedAt = monotonicTime() }
        if !active, let start = voiceStartedAt {
            usageStore.recordVoice(seconds: monotonicTime() - start)
            voiceStartedAt = nil
        }
        if isStreaming != active { isStreaming = active }
    }
    var audioBusy: Bool {
        if isStreaming { return true }
        return audioOutputState == .preparing || audioOutputState == .streaming || audioOutputState == .draining
    }
    var audioOutputDescription: String {
        switch audioOutputState {
        case .preparing: "正在准备音频设备"
        case .streaming: "正在传输语音"
        case .draining: "正在输出尾音"
        case .failed: "输出失败"
        case .idle: outputDevices.contains(where: { $0.id == outputUID }) ? "设备可用" : "等待音频设备"
        }
    }
    func choose(_ action: RemoteAction, for input: ControllerInput) {
        update(ButtonMapping(action: action), for: input, trigger: .single)
    }
    var effectiveMapping: RemoteMapping { globalButtons.applying(to: mapping, profile: remoteProfile) }

    func isGlobalInput(_ input: ControllerInput) -> Bool {
        input == globalButtons.input
    }

    func setGlobalInput(_ input: ControllerInput) {
        guard input != .options, remoteProfile.inputs.contains(input) else { return }
        globalButtons.input = input
    }

    func setGlobalButtons(_ settings: GlobalButtonSettings) {
        let normalized = settings.normalized(for: remoteProfile)
        guard normalized != globalButtons else { return }
        globalButtons = normalized
        onVoiceTriggerChange?()
    }

    func update(_ value: ButtonMapping, for input: ControllerInput, trigger: ButtonTrigger) {
        if input == .options {
            guard trigger == .single, value.shortcutForVoice != nil else { return }
            globalButtons.voice = value
        } else if input == globalButtons.input {
            switch trigger {
            case .single: globalButtons.single = value
            case .double: globalButtons.double = value
            case .long: globalButtons.long = value
            }
        } else {
            mapping[input, trigger] = value
            persistMapping()
        }
    }
    func openButtonEditor(_ input: ControllerInput, trigger: ButtonTrigger = .single) {
        selectedInput = input
        selectedTrigger = trigger
        editorVisible = true
    }
    func persistMapping() {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        profiles[index].mapping = mapping
        onMappingChange?(effectiveMapping)
    }
    func resetMapping() {
        if let profile = profiles.first(where: { $0.id == selectedProfileID }),
           profile.id != SavedKeyProfile.defaultID,
           let harness = profile.builtInHarness
                ?? harnesses.first(where: { $0.id == "codex" && $0.profileID == profile.id }) {
            mapping = harness.defaultMapping(macros: macros)
        } else {
            mapping = .defaults
        }
        persistMapping()
        postNotice("已恢复当前按键方案的默认映射", level: .success)
    }

    // MARK: Key profiles

    /// Only the suffix is editable and stored; the remote owns the prefix.
    var profileDisplayPrefix: String {
        showKeyProfilePrefix ? remoteProfile.keyProfilePrefix : ""
    }

    func profileDisplayName(_ profile: SavedKeyProfile) -> String {
        profileDisplayPrefix + profile.name
    }

    /// Profile names must be non-empty and unique, ignoring surrounding
    /// whitespace and letter case.
    func profileNameError(_ name: String, excluding id: UUID? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "方案名称不能为空" }
        if profiles.contains(where: { $0.id != id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "已存在同名方案，请使用其他名称"
        }
        return nil
    }
    @discardableResult
    func saveProfile(name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = profileNameError(name) {
            if !name.isEmpty { postNotice(error, level: .error) }
            return false
        }
        let profile = SavedKeyProfile(name: name, mapping: mapping)
        profiles.append(profile)
        activateProfile(profile.id)
        postNotice("已创建按键方案「\(profileDisplayName(profile))」", level: .success)
        return true
    }
    @discardableResult
    func duplicateProfile(_ id: UUID) -> UUID? {
        guard let source = profiles.first(where: { $0.id == id }) else { return nil }
        let name = uniqueName(source.name + "的复制", existingNames: profiles.map(\.name), fallback: "新方案")
        let copy = SavedKeyProfile(name: name, mapping: source.mapping)
        profiles.append(copy)
        activateProfile(copy.id)
        postNotice("已复制按键方案「\(profileDisplayName(copy))」", level: .success)
        return copy.id
    }
    @discardableResult
    func renameProfile(_ id: UUID, name: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }), id != SavedKeyProfile.defaultID else { return false }
        if let error = profileNameError(name, excluding: id) {
            postNotice(error, level: .error)
            return false
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if profiles[index].name != trimmed { profiles[index].protectedBuiltInID = nil }
        profiles[index].name = trimmed
        return true
    }
    func activateProfile(_ id: UUID?) {
        let id = id ?? SavedKeyProfile.defaultID
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        selectKeyProfile(profile, harnessID: nil)
    }
    func matchApplication(_ path: String?, bundleIdentifier: String? = nil) {
        guard !editorVisible else { return }
        let identifier = bundleIdentifier ?? path.flatMap { Bundle(path: $0)?.bundleIdentifier }
        if let harness = harnesses.first(where: {
            $0.isEnabled && $0.profileID != nil && $0.matches(applicationPath: path, bundleIdentifier: identifier)
        }) {
            activateHarness(harness.id)
        } else {
            activateProfile(nil)
        }
    }
    var activeMappingName: String {
        profileDisplayPrefix + activeProfileName
    }
    var activeProfileName: String {
        profiles.first(where: { $0.id == selectedProfileID })?.name ?? "默认方案"
    }
    func boundHarnesses(for profileID: UUID) -> [HarnessConfiguration] {
        harnesses.filter { $0.profileID == profileID }
    }
    @discardableResult
    func bindProfile(_ profileID: UUID?, to harnessID: String) -> Bool {
        guard let index = harnesses.firstIndex(where: { $0.id == harnessID }) else { return false }
        if let profileID {
            guard profiles.contains(where: { $0.id == profileID }) else { return false }
        }
        harnesses[index].profileID = profileID
        if selectedHarnessID == harnessID {
            if profileID != nil { activateHarness(harnessID) }
            else { activateProfile(nil) }
        }
        postNotice(profileID == nil ? "已解除 \(harnesses[index].name) 的方案绑定" : "已更新 \(harnesses[index].name) 的按键方案", level: .success)
        return true
    }
    func activateHarness(_ id: String?) {
        guard let id else { activateProfile(nil); return }
        guard let harness = harnesses.first(where: { $0.id == id && $0.isEnabled }),
              let profile = profiles.first(where: { $0.id == harness.profileID }) else { return }
        selectKeyProfile(profile, harnessID: id)
    }

    private func selectKeyProfile(_ profile: SavedKeyProfile, harnessID: String?) {
        guard selectedHarnessID != harnessID || selectedProfileID != profile.id || mapping != profile.mapping else { return }
        // Commit the two selection IDs together, so the saved remote snapshot
        // never contains a new Harness with the previous profile.
        isUpdatingKeySelection = true
        if selectedHarnessID != harnessID { selectedHarnessID = harnessID }
        if selectedProfileID != profile.id { selectedProfileID = profile.id }
        if mapping != profile.mapping { mapping = profile.mapping }
        isUpdatingKeySelection = false
        persistRemoteKeyConfiguration()
        onMappingChange?(effectiveMapping)
    }
    func editHarnessProfile(_ id: String) {
        guard let harness = harnesses.first(where: { $0.id == id }),
              let profileID = harness.profileID,
              profiles.contains(where: { $0.id == profileID }) else { return }
        activateProfile(profileID)
        page = .mapping
    }
    func setHarnessEnabled(_ id: String, enabled: Bool) {
        guard let index = harnesses.firstIndex(where: { $0.id == id }) else { return }
        harnesses[index].isEnabled = enabled
        if !enabled, selectedHarnessID == id { activateProfile(nil) }
    }
    @discardableResult
    func addHarness(applicationURL: URL) -> String {
        let url = applicationURL.standardizedFileURL
        let bundle = Bundle(url: url)
        let identifier = bundle?.bundleIdentifier
        if let index = harnesses.firstIndex(where: { $0.matches(applicationPath: url.path, bundleIdentifier: identifier) }) {
            harnesses[index].applicationPath = url.path
            harnesses[index].isEnabled = true
            postNotice("「\(harnesses[index].name)」已在 Harness 列表中", level: .warning)
            return harnesses[index].id
        }
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let harness = HarnessConfiguration(id: UUID().uuidString, name: name, bundleIdentifier: identifier, applicationPath: url.path)
        harnesses.append(harness)
        postNotice("已添加 \(name)，请选择要绑定的按键方案", level: .warning)
        return harness.id
    }
    func removeHarness(_ id: String) {
        guard let harness = harnesses.first(where: { $0.id == id }), !harness.isBuiltIn else { return }
        if selectedHarnessID == id { activateProfile(nil) }
        harnesses.removeAll { $0.id == id }
        postNotice("已移除 \(harness.name) Harness", level: .success)
    }
    func canDeleteProfile(_ id: UUID) -> Bool {
        guard id != SavedKeyProfile.defaultID,
              let profile = profiles.first(where: { $0.id == id }),
              !harnesses.contains(where: { $0.profileID == id }) else { return false }
        return profile.builtInHarness == nil
    }
    func deleteProfile(_ id: UUID) {
        deleteConfigurationObject(.profile(id, remoteID: remoteProfile.id))
    }

    /// Mapping of the default profile, used when no Harness matches.
    var defaultMapping: RemoteMapping {
        profiles.first(where: { $0.id == SavedKeyProfile.defaultID })?.mapping ?? .defaults
    }

    /// Deduplicate, ensure the default profile exists first, and drop dangling
    /// bindings. With `migrateLegacy`, move mappings stored on old Harnesses
    /// and app paths stored on old profiles into profile bindings.
    func normalizeProfiles(migrateLegacy: Bool, defaultMapping: RemoteMapping) {
        settingsWrites.batch {
            let normalized = NormalizedKeyProfiles(profiles: profiles, harnesses: harnesses,
                selectedHarnessID: selectedHarnessID, macros: macros,
                migrateLegacy: migrateLegacy, defaultMapping: defaultMapping)
            profiles = normalized.profiles
            harnesses = normalized.harnesses
            selectedHarnessID = normalized.selectedHarnessID
        }
    }

    func persistProfileConfiguration() {
        settingsWrites.save(profiles, SettingsKeys.Stored.profiles)
        settingsWrites.save(harnesses, SettingsKeys.Stored.harnesses)
        defaults.set(selectedProfileID?.uuidString, forKey: SettingsKeys.selectedProfileID)
        defaults.set(selectedHarnessID, forKey: SettingsKeys.selectedHarnessID)
        defaults.set(2, forKey: SettingsKeys.profileBindingsVersion)
        persistRemoteKeyConfiguration()
    }

    func keyConfigurationsForBackup() -> [String: RemoteKeyConfiguration] {
        var configurations = remoteKeyConfigurations
        configurations[remoteProfile.id] = currentRemoteKeyConfiguration
        return configurations
    }

    private var currentRemoteKeyConfiguration: RemoteKeyConfiguration {
        RemoteKeyConfiguration(profiles: profiles,
                               harnessProfileIDs: Dictionary(uniqueKeysWithValues: harnesses.compactMap { harness in
                                   harness.profileID.map { (harness.id, $0) }
                               }),
                               initializedHarnessIDs: harnesses.filter(\.didInitializeDefaultProfile).map(\.id),
                               globalButtons: globalButtons, selectedProfileID: selectedProfileID,
                               selectedHarnessID: selectedHarnessID)
    }

    private func persistRemoteKeyConfiguration() {
        guard !isRestoringRemoteConfiguration, !isUpdatingKeySelection else { return }
        let configuration = currentRemoteKeyConfiguration
        remoteKeyConfigurations[remoteProfile.id] = configuration
        settingsWrites.save(remoteKeyConfigurations, SettingsKeys.Stored.remoteKeyConfigurations)
    }

    private func restoreRemoteKeyConfiguration(_ configuration: RemoteKeyConfiguration?) {
        profiles = configuration?.profiles ?? []
        selectedProfileID = configuration?.selectedProfileID
        selectedHarnessID = configuration?.selectedHarnessID
        globalButtons = configuration?.globalButtons ?? GlobalButtonSettings()
        harnesses = harnesses.map { harness in
            // Configuration IDs have already been migrated. Migrate the app
            // metadata before looking up bindings and initialization intent.
            var harness = harness.migratingRetiredBuiltIn()
            harness.profileID = configuration?.harnessProfileIDs[harness.id]
            harness.didInitializeDefaultProfile = configuration?.initializedHarnessIDs.contains(harness.id) ?? false
            harness.legacyMapping = .defaults
            harness.hasLegacyMapping = false
            return harness
        }
    }

    private func restoreKeySelection() {
        if let harness = harnesses.first(where: { $0.id == selectedHarnessID && $0.isEnabled }),
           let profile = profiles.first(where: { $0.id == harness.profileID }) {
            selectedProfileID = profile.id
            mapping = profile.mapping
        } else {
            selectedHarnessID = nil
            let profile = profiles.first(where: { $0.id == selectedProfileID }) ?? profiles[0]
            selectedProfileID = profile.id
            mapping = profile.mapping
        }
    }

    /// The already encoded snapshot is committed before installing these values.
    /// Runtime consumers receive one notification after every field is consistent.
    func installConfiguration(_ backup: SettingsBackup, recoveryDate: Date?,
                              resetDeletionState: Bool = true, notifyVoiceChange: Bool = true) {
        settingsWrites.discard()
        isCommittingConfiguration = true
        isRestoringRemoteConfiguration = true
        editorVisible = false
        remoteKeyConfigurations = backup.remoteKeyConfigurations ?? [:]
        profiles = backup.profiles
        macros = backup.macros
        phrases = backup.phrases
        phraseAssignments = backup.phraseAssignments ?? PhraseAssignments()
        harnesses = backup.harnesses ?? HarnessConfiguration.defaults
        globalButtons = backup.globalButtons ?? GlobalButtonSettings()
        let current = remoteKeyConfigurations[remoteProfile.id]
        selectedProfileID = current?.selectedProfileID ?? SavedKeyProfile.defaultID
        selectedHarnessID = current?.selectedHarnessID
        mapping = profiles.first { $0.id == selectedProfileID }?.mapping ?? backup.mapping
        configurationRecoveryDate = recoveryDate
        if resetDeletionState {
            pendingDeletion = nil
            deletionUndoStack.removeAll()
        }
        isRestoringRemoteConfiguration = false
        isCommittingConfiguration = false
        onMappingChange?(effectiveMapping)
        if notifyVoiceChange { onVoiceTriggerChange?() }
        onHarnessesChange?()
    }

    var configurationMacroPresetsVersion: Int {
        SettingsStorage.load(Int.self, SettingsKeys.Stored.macroPresetsVersion, defaults: defaults)
            ?? defaults.integer(forKey: SettingsKeys.macroPresetsVersion)
    }

    // MARK: Macros

    func initializeDefaultMacros(version: Int) {
        if version < DefaultMacros.version {
            macros = DefaultMacros.addingMissing(to: macros, since: version)
        }
        let currentVersion = max(version, DefaultMacros.version)
        if SettingsStorage.contains(SettingsKeys.Stored.configurationSnapshot, defaults: defaults) {
            settingsWrites.save(currentVersion, SettingsKeys.Stored.macroPresetsVersion)
        } else {
            defaults.set(currentVersion, forKey: SettingsKeys.macroPresetsVersion)
        }
    }

    @discardableResult
    func addMacro() -> UUID {
        let macro = SavedMacro(name: SavedMacro.uniqueName("新组合动作", existingNames: macros.map(\.name)))
        macros.append(macro)
        return macro.id
    }

    func macroNameError(_ name: String, excluding id: UUID) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "组合动作名称不能为空" }
        if macros.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "已存在同名组合动作，请使用其他名称"
        }
        return nil
    }

    @discardableResult
    func renameMacro(_ id: UUID, name: String) -> Bool {
        guard let index = macros.firstIndex(where: { $0.id == id }) else { return false }
        if let error = macroNameError(name, excluding: id) {
            postNotice(error, level: .error)
            return false
        }
        macros[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return true
    }

    func canNestMacro(_ childID: UUID, in parentID: UUID) -> Bool {
        !MacroExecutionPlan.wouldCreateCycle(referencing: childID, from: parentID, macros: macros)
    }

    @discardableResult
    func updateMacroSteps(_ steps: [MacroStep], for id: UUID) -> Bool {
        guard let index = macros.firstIndex(where: { $0.id == id }) else { return false }
        for step in steps where step.mapping.action == .macro {
            if let childID = step.mapping.referenceID.flatMap(UUID.init(uuidString:)), !canNestMacro(childID, in: id) {
                postNotice("组合动作不能引用自身或形成循环引用", level: .error)
                return false
            }
        }
        macros[index].steps = steps
        return true
    }

    func deleteMacro(_ id: UUID) {
        deleteConfigurationObject(.macro(id))
    }

    func mappingTitle(_ value: ButtonMapping) -> String {
        if value.action == .recordedShortcut { return value.shortcut?.label ?? "选择快捷键" }
        if value.action == .openApplication { return value.applicationPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "选择应用" }
        if value.action == .phrase { return phrases.first(where: { $0.id.uuidString == value.referenceID })?.title ?? "选择常用语" }
        if value.action == .macro { return macros.first(where: { $0.id.uuidString == value.referenceID })?.name ?? "选择组合动作" }
        return value.action == .disabled ? "未设置" : value.action.label
    }

    // MARK: Phrases

    private func initializeDefaultPhrases() {
        if !defaults.bool(forKey: SettingsKeys.aiPhrasePresetsInitialized) {
            phrases = DefaultPhrases.addingMissing(to: phrases)
            defaults.set(true, forKey: SettingsKeys.aiPhrasePresetsInitialized)
        }
        guard !defaults.bool(forKey: SettingsKeys.aiPhraseAssignmentsInitialized) else { return }
        if phraseAssignments.slots.isEmpty {
            phraseAssignments = DefaultPhrases.assignments(for: phrases)
        }
        defaults.set(true, forKey: SettingsKeys.aiPhraseAssignmentsInitialized)
    }

    /// Binding priority is a presentation order; keep the user's manual order intact.
    var boundPhrases: [SavedPhrase] {
        let byID = Dictionary(phrases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var included = Set<UUID>()
        return PhraseAssignments.inputs.compactMap { input in
            guard let id = phraseAssignments[input], included.insert(id).inserted else { return nil }
            return byID[id]
        }
    }

    var unboundPhrases: [SavedPhrase] {
        let boundIDs = Set(PhraseAssignments.inputs.compactMap { phraseAssignments[$0] })
        return phrases.filter { !boundIDs.contains($0.id) }
    }

    var orderedPhrases: [SavedPhrase] { boundPhrases + unboundPhrases }

    func moveUnboundPhrases(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let boundIDs = Set(PhraseAssignments.inputs.compactMap { phraseAssignments[$0] })
        let indices = phrases.indices.filter { !boundIDs.contains(phrases[$0].id) }
        guard !offsets.isEmpty, offsets.allSatisfy({ indices.indices.contains($0) }),
              (0...indices.count).contains(destination) else { return }
        var reordered = indices.map { phrases[$0] }
        reordered.move(fromOffsets: offsets, toOffset: destination)
        var updated = phrases
        for (index, phrase) in zip(indices, reordered) { updated[index] = phrase }
        if updated != phrases { phrases = updated }
    }

    // MARK: Device, permissions and app settings

    @discardableResult
    func postNotice(_ message: String, level: ActionNotice.Level,
                    recoveryAction: ActionNotice.RecoveryAction? = nil,
                    source: ActionNotice.Source? = nil) -> UUID {
        // Repeated reports update one fault, while unrelated failures stay available.
        let replaced = actionNotices.filter {
            if let source { return $0.source == source }
            return $0.source == nil && $0.message == message && $0.level == level && $0.recoveryAction == recoveryAction
        }
        for notice in replaced { dismissNotice(notice.id) }
        let notice = ActionNotice(level: level, message: message, recoveryAction: recoveryAction, source: source)
        actionNotices.insert(notice, at: 0)
        if let delay = level.dismissalDelay {
            noticeDismissals[notice.id] = noticeSchedule(delay) { [weak self] in
                self?.dismissNotice(notice.id)
            }
        }
        return notice.id
    }

    func dismissNotice(_ id: UUID) {
        noticeDismissals.removeValue(forKey: id)?.cancel()
        actionNotices.removeAll { $0.id == id }
    }

    func resolveNotices(from source: ActionNotice.Source) {
        for notice in actionNotices.filter({ $0.source == source }) { dismissNotice(notice.id) }
    }

    func showNextNotice() {
        guard actionNotices.count > 1 else { return }
        actionNotices.append(actionNotices.removeFirst())
    }

    func performNoticeRecovery(_ action: ActionNotice.RecoveryAction) {
        switch action {
        case .permissions: openPermissions()
        case .connection:
            page = .connection
            noticeNavigationRequest = ActionNotice.NavigationRequest(action: action)
        case .configuration:
            page = .about
            noticeNavigationRequest = ActionNotice.NavigationRequest(action: action)
        case .macros: page = .macros
        case .loginItems: SMAppService.openSystemSettingsLoginItems()
        }
    }

    func finishNoticeNavigation(_ id: UUID) {
        guard noticeNavigationRequest?.id == id else { return }
        noticeNavigationRequest = nil
    }

    func installMicrophone() { onInstallMicrophone?() }
    func uninstallMicrophone() { onUninstallMicrophone?() }
    func rescan() { postNotice("正在重新连接遥控器…", level: .information); onRescan?() }
    func toggleMode() { onToggleMode?() }
    func refreshDevices(forceReload: Bool = false) {
        let devices = (forceReload ? AudioDeviceCatalog.shared.reload() : AudioDeviceCatalog.shared.devices())
            .filter(\.isLoopback)
            .map { RemoteAudioDevice(id: $0.uid, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if outputDevices != devices { outputDevices = devices }
        microphoneInstalled = RemoteMicrophoneOutput.installed
        microphoneComponentPresent = RemoteMicrophoneInstallation.isInstalledOnDisk
        microphoneUpdateAvailable = RemoteMicrophoneInstallation.updateRequired
        if !microphoneUpdateAvailable { resolveNotices(from: .microphoneUpdate) }
    }
    func refreshPermissions() {
        inputGranted = CGPreflightListenEventAccess()
        accessibilityGranted = AXIsProcessTrusted()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        bluetoothGranted = CBManager.authorization == .allowedAlways
        loginEnabled = SMAppService.mainApp.status == .enabled
        if inputGranted && accessibilityGranted { resolveNotices(from: .voicePermissions) }
        refreshDevices()
    }
    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { postNotice("请在系统设置 → 通用 → 登录项中允许 RcHarness。", level: .warning, recoveryAction: .loginItems) }
        } catch {
            postNotice("无法更改登录项：" + error.localizedDescription, level: .error, recoveryAction: .loginItems)
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
    func showVoicePermissionNotice() {
        postNotice(VoiceSetupGuidance.permissions, level: .warning,
                   recoveryAction: .permissions, source: .voicePermissions)
    }

    func openPermissions() {
        page = .about
        // Repeated requests must also scroll when Settings is already open.
        permissionsNavigationRequest = UUID()
    }

    func finishPermissionsNavigation(_ request: UUID) {
        guard permissionsNavigationRequest == request else { return }
        permissionsNavigationRequest = nil
    }

    func playTestTone() {
        guard !audioBusy, testOutput == nil else { return }
        let output = RemoteMicrophoneOutput(outputUID: { [weak self] in self?.outputUID ?? RemoteMicrophoneOutput.deviceUID })
        testOutput = output
        output.onStateChange = { [weak self, weak output] state in
            guard let self, let output, self.testOutput === output else { return }
            self.audioOutputState = state
            switch state {
            case .failed:
                self.resolveNotices(from: .testTone)
                self.testOutput = nil
            case .idle:
                self.resolveNotices(from: .testTone)
                self.postNotice("测试音发送完成，请在目标语音应用中检查麦克风输入电平。", level: .success)
                self.testOutput = nil
            default: break
            }
        }
        postNotice("正在向接收设备发送 1 秒测试音，请在目标语音应用中观察麦克风输入电平。", level: .information, source: .testTone)
        output.begin()
        guard output.failure == nil else { return }
        // Less than the bounded live queue; four blocks deliver exactly one second.
        for block in 0..<4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(block) * 0.25) { [weak self] in
                guard let self, self.testOutput === output, !self.isStreaming else { return }
                let samples = (0..<4000).map { Int16(sin(Double($0 + block * 4000) * 2 * .pi * 440 / 16000) * 3200) }
                output.append(samples)
                if block == 3 { output.end() }
            }
        }
    }
    func stopTestTone() {
        guard let output = testOutput else { return }
        testOutput = nil
        output.onStateChange = nil
        output.stop()
        audioOutputState = .idle
        resolveNotices(from: .testTone)
    }
    func copyDiagnostics() {
        copy(diagnosticsText)
        postNotice("诊断信息已复制", level: .success)
    }
    var diagnosticsText: String {
        "RcHarness \(AppInfo.version) (\(AppInfo.build))\nRemoteModel=\(remoteProfile.model)\nValidation=\(remoteProfile.validation.rawValue)\nBluetooth=\(bluetoothGranted)\nInputMonitoring=\(inputGranted)\nAccessibility=\(accessibilityGranted)\nMicrophone=\(microphoneGranted)\nRemoteConnected=\(isConnected)\nVoiceReady=\(voiceReady)\nOutputUID=\(outputUID)\nAudioOutput=\(audioOutputState)\nMicrophoneComponent=\(microphoneInstalled)\(microphoneUpdateAvailable ? " (update available)" : "")\n\(voiceDiagnostics)"
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

/// State that changes on every button press, observed only by the views that
/// draw pressed keys.
@MainActor
final class RemoteLiveStatus: ObservableObject {
    @Published var pressedInputs: Set<ControllerInput> = []
}
