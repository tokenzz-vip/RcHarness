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
    @Published var page: SettingsPage = .mapping
    @Published var isConnected = false
    @Published var operationMode: ControllerOperationMode = .mapping
    @Published var voiceStatus = "遥控器麦克风未连接"
    @Published var voiceReady = false
    var voiceDiagnostics = ""
    @Published var isStreaming = false
    @Published var audioOutputState: RemoteAudioOutputState = .idle
    @Published var batteryLevel: Float?
    @Published var microphoneInstalled = RemoteMicrophoneOutput.installed
    /// The HAL plug-in exists on disk (it may not be loaded until coreaudiod restarts).
    @Published var microphoneComponentPresent = RemoteMicrophoneInstallation.isInstalledOnDisk
    @Published var microphoneUpdateAvailable = RemoteMicrophoneInstallation.updateRequired
    @Published private(set) var globalButtons: GlobalButtonSettings {
        didSet {
            SettingsStorage.save(globalButtons, SettingsKeys.Stored.globalButtons, defaults: defaults)
            persistRemoteKeyConfiguration()
            if !isRestoringRemoteConfiguration { onMappingChange?(effectiveMapping) }
        }
    }
    @Published var mapping: RemoteMapping
    @Published var actionMessage = ""
    @Published var selectedInput: ControllerInput = .buttonA
    @Published var selectedTrigger: ButtonTrigger = .single
    @Published var editorVisible = false
    /// Only the selected remote's schemes are exposed to editors and pickers.
    @Published private(set) var profiles: [SavedKeyProfile] {
        didSet {
            SettingsStorage.save(profiles, SettingsKeys.Stored.profiles, defaults: defaults)
            persistRemoteKeyConfiguration()
        }
    }
    @Published private(set) var macros: [SavedMacro] { didSet { SettingsStorage.save(macros, SettingsKeys.Stored.macros, defaults: defaults) } }
    @Published var phrases: [SavedPhrase] { didSet { SettingsStorage.save(phrases, SettingsKeys.Stored.phrases, defaults: defaults) } }
    @Published private(set) var harnesses: [HarnessConfiguration] {
        didSet {
            SettingsStorage.save(harnesses, SettingsKeys.Stored.harnesses, defaults: defaults)
            persistRemoteKeyConfiguration()
            if !isRestoringRemoteConfiguration { onHarnessesChange?() }
        }
    }
    @Published private(set) var selectedHarnessID: String? {
        didSet {
            guard selectedHarnessID != oldValue else { return }
            defaults.set(selectedHarnessID, forKey: SettingsKeys.selectedHarnessID)
            persistRemoteKeyConfiguration()
        }
    }
    @Published private(set) var selectedProfileID: UUID? {
        didSet {
            guard selectedProfileID != oldValue else { return }
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

    /// - Parameter mapping: used only on first launch, as the default profile's mapping.
    init(mapping: RemoteMapping, defaults: UserDefaults = .standard, remoteProfile: RemoteProfile = RemoteProfiles.xiaomiRC003,
         availableRemoteProfiles: [RemoteProfile] = RemoteProfiles.all,
         monotonicTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.monotonicTime = monotonicTime
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
        usageStore = UsageStore(defaults: defaults)
        harnesses = SettingsStorage.load([HarnessConfiguration].self, SettingsKeys.Stored.harnesses, defaults: defaults) ?? HarnessConfiguration.defaults
        selectedHarnessID = defaults.string(forKey: SettingsKeys.selectedHarnessID)
        let savedGain = defaults.double(forKey: SettingsKeys.gain)
        gain = savedGain.isFinite ? min(24, max(0, savedGain)) : 0
        outputUID = defaults.string(forKey: SettingsKeys.outputUID) ?? RemoteMicrophoneOutput.deviceUID
        showDockIcon = defaults.object(forKey: SettingsKeys.showDockIcon) as? Bool ?? true
        showKeyProfilePrefix = defaults.bool(forKey: SettingsKeys.showKeyProfilePrefix)
        openAtLaunch = defaults.object(forKey: SettingsKeys.openAtLaunch) as? Bool ?? true
        selectedProfileID = defaults.string(forKey: SettingsKeys.selectedProfileID).flatMap(UUID.init(uuidString:))
        let legacyBindings = defaults.integer(forKey: SettingsKeys.profileBindingsVersion) < 2
        let hasSavedConfiguration = SettingsStorage.contains(SettingsKeys.Stored.harnesses, defaults: defaults)
            || SettingsStorage.contains(SettingsKeys.Stored.profiles, defaults: defaults)
        // Detect legacy settings before normalization writes the initial profiles.
        let hasLegacyGlobalSettings = hasSavedConfiguration || legacyDefaultMapping != .defaults
            || SettingsStorage.contains(SettingsKeys.Stored.legacyBaseMapping, defaults: defaults)
            || RemoteProfiles.all.contains { SettingsStorage.contains(SettingsKeys.Stored.legacyMapping(profileID: $0.id), defaults: defaults) }
            || defaults.object(forKey: SettingsKeys.voiceFnTap) != nil
        initializeDefaultMacros(version: defaults.integer(forKey: SettingsKeys.macroPresetsVersion))
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
        SettingsStorage.save(globalButtons, SettingsKeys.Stored.globalButtons, defaults: defaults)
        persistProfileConfiguration()
        SettingsStorage.save(macros, SettingsKeys.Stored.macros, defaults: defaults)
        refreshDevices()
        deviceObserver = NotificationCenter.default.addObserver(
            forName: .rcHarnessAudioDevicesChanged, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshDevices() } }
    }

    deinit {
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
    }

    /// Writes state that is saved lazily (usage statistics).
    func flushPendingWrites() { usageStore.flush() }

    func setConnected(_ connected: Bool) {
        isConnected = connected
        if !connected {
            batteryLevel = nil
            live.pressedInputs.removeAll()
            setStreaming(false)
        }
    }

    func selectRemoteProfile(_ id: String) {
        guard let profile = availableRemoteProfiles.first(where: { $0.id == id }),
              profile.id != remoteProfile.id else { return }
        stopTestTone()
        editorVisible = false
        setConnected(false)
        setVoice(status: "遥控器麦克风未连接", ready: false, battery: nil)
        voiceDiagnostics = ""
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
        actionMessage = "已恢复当前按键方案的默认映射"
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
            if !name.isEmpty { actionMessage = error }
            return false
        }
        let profile = SavedKeyProfile(name: name, mapping: mapping)
        profiles.append(profile)
        activateProfile(profile.id)
        actionMessage = "已创建按键方案「\(profileDisplayName(profile))」"
        return true
    }
    @discardableResult
    func duplicateProfile(_ id: UUID) -> UUID? {
        guard let source = profiles.first(where: { $0.id == id }) else { return nil }
        let name = uniqueName(source.name + "的复制", existingNames: profiles.map(\.name), fallback: "新方案")
        let copy = SavedKeyProfile(name: name, mapping: source.mapping)
        profiles.append(copy)
        activateProfile(copy.id)
        actionMessage = "已复制按键方案「\(profileDisplayName(copy))」"
        return copy.id
    }
    @discardableResult
    func renameProfile(_ id: UUID, name: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }), id != SavedKeyProfile.defaultID else { return false }
        if let error = profileNameError(name, excluding: id) {
            actionMessage = error
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
        actionMessage = profileID == nil ? "已解除 \(harnesses[index].name) 的方案绑定" : "已更新 \(harnesses[index].name) 的按键方案"
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
            actionMessage = "「\(harnesses[index].name)」已在 Harness 列表中"
            return harnesses[index].id
        }
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let harness = HarnessConfiguration(id: UUID().uuidString, name: name, bundleIdentifier: identifier, applicationPath: url.path)
        harnesses.append(harness)
        actionMessage = "已添加 \(name)，请选择要绑定的按键方案"
        return harness.id
    }
    func removeHarness(_ id: String) {
        guard let harness = harnesses.first(where: { $0.id == id }), !harness.isBuiltIn else { return }
        if selectedHarnessID == id { activateProfile(nil) }
        harnesses.removeAll { $0.id == id }
        actionMessage = "已移除 \(harness.name) Harness"
    }
    func canDeleteProfile(_ id: UUID) -> Bool {
        guard id != SavedKeyProfile.defaultID,
              let profile = profiles.first(where: { $0.id == id }),
              !harnesses.contains(where: { $0.profileID == id }) else { return false }
        return profile.builtInHarness == nil
    }
    func deleteProfile(_ id: UUID) {
        guard canDeleteProfile(id) else { return }
        if selectedProfileID == id { activateProfile(nil) }
        profiles.removeAll { $0.id == id }
    }

    /// Mapping of the default profile, used when no Harness matches.
    var defaultMapping: RemoteMapping {
        profiles.first(where: { $0.id == SavedKeyProfile.defaultID })?.mapping ?? .defaults
    }

    /// Deduplicate, ensure the default profile exists first, and drop dangling
    /// bindings. With `migrateLegacy`, move mappings stored on old Harnesses
    /// and app paths stored on old profiles into profile bindings.
    func normalizeProfiles(migrateLegacy: Bool, defaultMapping: RemoteMapping) {
        var profileIDs = Set<UUID>()
        profiles = profiles.filter { profileIDs.insert($0.id).inserted }
        if let index = profiles.firstIndex(where: { $0.id == SavedKeyProfile.defaultID }) {
            let fallback = profiles.remove(at: index)
            profiles.insert(fallback, at: 0)
        } else {
            profiles.insert(SavedKeyProfile(id: SavedKeyProfile.defaultID, name: "默认方案", mapping: defaultMapping), at: 0)
        }
        if let selected = harnesses.first(where: { $0.id == selectedHarnessID }) {
            selectedHarnessID = selected.migratingRetiredBuiltIn().id
        }
        harnesses = harnesses.map { $0.migratingRetiredBuiltIn() }
        var harnessIDs = Set<String>()
        harnesses = harnesses.filter { harnessIDs.insert($0.id).inserted }
        for index in harnesses.indices {
            if let id = harnesses[index].profileID,
               profiles.contains(where: { $0.id == id }) {
                continue
            }
            harnesses[index].profileID = nil
            if migrateLegacy && (harnesses[index].hasLegacyMapping || harnesses[index].legacyMapping != .defaults) {
                let profile = SavedKeyProfile(name: harnesses[index].name + " 按键方案", mapping: harnesses[index].legacyMapping)
                profiles.append(profile)
                harnesses[index].profileID = profile.id
            }
        }
        // Old profiles could match an app directly. Move that relationship to
        // a Harness, retaining every profile even when the app already has one.
        for profileIndex in profiles.indices where !profiles[profileIndex].applicationPath.isEmpty {
            let path = profiles[profileIndex].applicationPath
            if migrateLegacy {
                let url = URL(fileURLWithPath: path)
                let identifier = Bundle(url: url)?.bundleIdentifier
                let harnessIndex: Int
                if let index = harnesses.firstIndex(where: { $0.matches(applicationPath: path, bundleIdentifier: identifier) }) {
                    harnessIndex = index
                } else {
                    harnesses.append(HarnessConfiguration(id: UUID().uuidString, name: url.deletingPathExtension().lastPathComponent,
                                                         bundleIdentifier: identifier, applicationPath: path))
                    harnessIndex = harnesses.count - 1
                }
                if harnesses[harnessIndex].profileID == nil {
                    harnesses[harnessIndex].profileID = profiles[profileIndex].id
                }
            }
            profiles[profileIndex].applicationPath = ""
        }
        harnesses = HarnessConfiguration.addingNewBuiltIns(to: harnesses)
        for index in harnesses.indices where !harnesses[index].didInitializeDefaultProfile {
            guard let name = harnesses[index].initialProfileName else { continue }
            if harnesses[index].profileID == nil {
                let profile = SavedKeyProfile(name: uniqueName(name, existingNames: profiles.map(\.name), fallback: name),
                                              mapping: harnesses[index].defaultMapping(macros: macros))
                profiles.append(profile)
                harnesses[index].profileID = profile.id
            }
            harnesses[index].didInitializeDefaultProfile = true
        }
        // Also repair configurations whose Harness was already migrated to DeepSeek.
        profiles = SavedKeyProfile.migratingRetiredName(in: profiles,
            boundProfileID: harnesses.first(where: { $0.id == "deepseek" })?.profileID)
        profiles = SavedKeyProfile.normalizingNames(in: profiles)
    }

    func persistProfileConfiguration() {
        SettingsStorage.save(profiles, SettingsKeys.Stored.profiles, defaults: defaults)
        SettingsStorage.save(harnesses, SettingsKeys.Stored.harnesses, defaults: defaults)
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
        SettingsStorage.save(remoteKeyConfigurations, SettingsKeys.Stored.remoteKeyConfigurations, defaults: defaults)
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

    func beginKeyConfigurationImport(_ configurations: [String: RemoteKeyConfiguration]) {
        isRestoringRemoteConfiguration = true
        remoteKeyConfigurations = configurations.mapValues { $0.normalized() }
    }

    func finishKeyConfigurationImport(legacyMapping: RemoteMapping, legacyGlobals: GlobalButtonSettings?, migrateLegacy: Bool) {
        let configuration = remoteKeyConfigurations[remoteProfile.id]
        if !remoteKeyConfigurations.isEmpty { restoreRemoteKeyConfiguration(configuration) }
        normalizeProfiles(migrateLegacy: remoteKeyConfigurations.isEmpty && migrateLegacy,
                          defaultMapping: remoteKeyConfigurations.isEmpty ? legacyMapping : .defaults)
        globalButtons = (configuration?.globalButtons
            ?? (!remoteKeyConfigurations.isEmpty ? GlobalButtonSettings() : legacyGlobals)
            ?? .migrating(defaultMapping, voiceFnTap: voiceFnTap)).normalized(for: remoteProfile)
        // Import starts at the default scheme; saved device selections are restored on switching.
        selectedHarnessID = nil
        selectedProfileID = SavedKeyProfile.defaultID
        mapping = defaultMapping
        isRestoringRemoteConfiguration = false
        persistProfileConfiguration()
        onMappingChange?(effectiveMapping)
        onVoiceTriggerChange?()
        onHarnessesChange?()
    }

    /// Replace configuration wholesale (used by import).
    func replaceConfiguration(profiles: [SavedKeyProfile], macros: [SavedMacro], phrases: [SavedPhrase], harnesses: [HarnessConfiguration]) {
        self.profiles = profiles
        self.macros = SavedMacro.normalizingNames(in: macros)
        self.phrases = phrases
        self.harnesses = harnesses
    }

    // MARK: Macros

    func initializeDefaultMacros(version: Int) {
        if version < DefaultMacros.version {
            macros = DefaultMacros.addingMissing(to: macros, since: version)
        }
        defaults.set(max(version, DefaultMacros.version), forKey: SettingsKeys.macroPresetsVersion)
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
            actionMessage = error
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
                actionMessage = "组合动作不能引用自身或形成循环引用"
                return false
            }
        }
        macros[index].steps = steps
        return true
    }

    func deleteMacro(_ id: UUID) {
        macros.removeAll { $0.id == id }
    }

    func mappingTitle(_ value: ButtonMapping) -> String {
        if value.action == .recordedShortcut { return value.shortcut?.label ?? "选择快捷键" }
        if value.action == .openApplication { return value.applicationPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "选择应用" }
        if value.action == .phrase { return phrases.first(where: { $0.id.uuidString == value.referenceID })?.title ?? "选择常用语" }
        if value.action == .macro { return macros.first(where: { $0.id.uuidString == value.referenceID })?.name ?? "选择组合动作" }
        return value.action == .disabled ? "未设置" : value.action.label
    }

    // MARK: Device, permissions and app settings

    func installMicrophone() { onInstallMicrophone?() }
    func uninstallMicrophone() { onUninstallMicrophone?() }
    func rescan() { actionMessage = "正在重新连接遥控器…"; onRescan?() }
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
    }
    func refreshPermissions() {
        inputGranted = CGPreflightListenEventAccess()
        accessibilityGranted = AXIsProcessTrusted()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        bluetoothGranted = CBManager.authorization == .allowedAlways
        loginEnabled = SMAppService.mainApp.status == .enabled
        refreshDevices()
    }
    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { actionMessage = "请在系统设置 → 通用 → 登录项中允许 RcHarness。" }
        } catch {
            actionMessage = "无法更改登录项：" + error.localizedDescription
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
    func playTestTone() {
        guard !audioBusy, testOutput == nil else { return }
        let output = RemoteMicrophoneOutput(outputUID: { [weak self] in self?.outputUID ?? RemoteMicrophoneOutput.deviceUID })
        testOutput = output
        output.onStateChange = { [weak self, weak output] state in
            guard let self, let output, self.testOutput === output else { return }
            self.audioOutputState = state
            switch state {
            case .failed(let message):
                self.actionMessage = message
                self.testOutput = nil
            case .idle:
                self.actionMessage = "测试音播放完成"
                self.testOutput = nil
            default: break
            }
        }
        actionMessage = "正在向所选设备发送 1 秒测试音"
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
    }
    func copyDiagnostics() {
        copy(diagnosticsText)
        actionMessage = "诊断信息已复制"
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
