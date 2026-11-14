import Foundation

// Local settings are independent of the device adapters and never contain speech.
enum SettingsPage: String, CaseIterable, Identifiable {
    case mapping, harness, macros, profiles, connection, about, statistics, phrases
    var id: String { rawValue }
    static let navigation: [Self] = [.mapping, .harness, .profiles, .macros, .connection, .about]
    var title: String {
        switch self {
        case .mapping: "按键映射"
        case .harness: "Harness"
        case .macros: "组合动作"
        case .profiles: "键位方案"
        case .connection: "连接与语音"
        case .about: "设置"
        case .statistics: "使用统计"
        case .phrases: "常用语"
        }
    }
    var shortTitle: String {
        switch self {
        case .mapping: "按键"
        case .connection: "连接"
        case .about: "设置"
        case .statistics: "统计"
        default: title
        }
    }
    var symbol: String {
        switch self {
        case .mapping: "keyboard"
        case .harness: "square.grid.2x2"
        case .macros: "square.3.layers.3d"
        case .profiles: "rectangle.3.group"
        case .connection: "link"
        case .about: "gearshape"
        case .statistics: "chart.bar.fill"
        case .phrases: "text.quote"
        }
    }
}

enum ButtonTrigger: String, CaseIterable, Codable, Identifiable {
    case single, double, long
    var id: String { rawValue }
    var title: String {
        switch self { case .single: "单击"; case .double: "双击"; case .long: "长按" }
    }
}

extension ControllerInput {
    var supportedTriggers: [ButtonTrigger] {
        ButtonTrigger.allCases
    }
}

extension RemoteMapping {
    subscript(_ input: ControllerInput, _ trigger: ButtonTrigger) -> ButtonMapping {
        get {
            guard input.supportedTriggers.contains(trigger) else { return ButtonMapping(action: .disabled) }
            return trigger == .single ? self[input] : buttons[input.rawValue + "." + trigger.rawValue] ?? ButtonMapping(action: .disabled)
        }
        set {
            guard input.supportedTriggers.contains(trigger) else { return }
            if trigger == .single { self[input] = newValue }
            else { buttons[input.rawValue + "." + trigger.rawValue] = newValue }
        }
    }
}

enum VoiceTriggerMode: String, Codable, CaseIterable {
    case hold, tap
}

/// One ordinary global-button binding. `input == nil` is used by additional
/// rows that have been added but not assigned yet.
struct GlobalButtonEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var input: ControllerInput?
    var single: ButtonMapping
    var double: ButtonMapping
    var long: ButtonMapping

    init(id: UUID = UUID(), input: ControllerInput? = nil,
         single: ButtonMapping = ButtonMapping(action: .disabled),
         double: ButtonMapping = ButtonMapping(action: .disabled),
         long: ButtonMapping = ButtonMapping(action: .disabled)) {
        self.id = id
        self.input = input
        self.single = single
        self.double = double
        self.long = long
    }

    private enum CodingKeys: String, CodingKey { case id, input, single, double, long }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        input = try values.decodeIfPresent(ControllerInput.self, forKey: .input)
        single = try values.decodeIfPresent(ButtonMapping.self, forKey: .single) ?? ButtonMapping(action: .disabled)
        double = try values.decodeIfPresent(ButtonMapping.self, forKey: .double) ?? ButtonMapping(action: .disabled)
        long = try values.decodeIfPresent(ButtonMapping.self, forKey: .long) ?? ButtonMapping(action: .disabled)
    }
}

/// Shared by one remote's key profiles; the physical voice key is reserved for voice triggering.
/// The first three entries are permanent. Only the first must have a key;
/// optional entries can keep their gestures while their key is unassigned.
struct GlobalButtonSettings: Codable, Equatable {
    static let requiredButtonCount = 3

    var buttons: [GlobalButtonEntry]
    var voice = ButtonMapping(action: .fn)
    var voiceFnTap = false
    var voiceTapShortcut: RecordedShortcut? = .voiceTapDefault
    var voiceMode: VoiceTriggerMode? = .hold

    var input: ControllerInput {
        get { buttons.first?.input ?? .power }
        set {
            if buttons.isEmpty { buttons = [GlobalButtonEntry(input: newValue)] }
            else { buttons[0].input = newValue }
        }
    }
    var single: ButtonMapping {
        get { buttons.first?.single ?? ButtonMapping(action: .disabled) }
        set {
            if buttons.isEmpty { buttons = [GlobalButtonEntry(input: .power, single: newValue)] }
            else { buttons[0].single = newValue }
        }
    }
    var double: ButtonMapping {
        get { buttons.first?.double ?? ButtonMapping(action: .disabled) }
        set {
            if buttons.isEmpty { buttons = [GlobalButtonEntry(input: .power, double: newValue)] }
            else { buttons[0].double = newValue }
        }
    }
    var long: ButtonMapping {
        get { buttons.first?.long ?? ButtonMapping(action: .disabled) }
        set {
            if buttons.isEmpty { buttons = [GlobalButtonEntry(input: .power, long: newValue)] }
            else { buttons[0].long = newValue }
        }
    }

    init(input: ControllerInput = .power,
         single: ButtonMapping = ButtonMapping(action: .openHarnessSwitcher),
         double: ButtonMapping = ButtonMapping(action: .screenshot),
         long: ButtonMapping = ButtonMapping(action: .switchToNativeMode),
         additionalButtons: [GlobalButtonEntry] = [],
         voice: ButtonMapping = ButtonMapping(action: .fn),
         voiceFnTap: Bool = false,
         voiceTapShortcut: RecordedShortcut? = .voiceTapDefault,
         voiceMode: VoiceTriggerMode? = .hold) {
        buttons = [GlobalButtonEntry(input: input, single: single, double: double, long: long)] + additionalButtons
        self.voice = voice
        self.voiceFnTap = voiceFnTap
        self.voiceTapShortcut = voiceTapShortcut
        self.voiceMode = voiceMode
    }

    init(buttons: [GlobalButtonEntry],
         voice: ButtonMapping = ButtonMapping(action: .fn),
         voiceFnTap: Bool = false,
         voiceTapShortcut: RecordedShortcut? = .voiceTapDefault,
         voiceMode: VoiceTriggerMode? = .hold) {
        self.buttons = buttons.isEmpty
            ? [GlobalButtonEntry(input: .power,
                                 single: ButtonMapping(action: .openHarnessSwitcher),
                                 double: ButtonMapping(action: .screenshot),
                                 long: ButtonMapping(action: .switchToNativeMode))]
            : buttons
        self.voice = voice
        self.voiceFnTap = voiceFnTap
        self.voiceTapShortcut = voiceTapShortcut
        self.voiceMode = voiceMode
    }

    private enum CodingKeys: String, CodingKey {
        case buttons, input, single, double, long, voice, voiceFnTap, voiceTapShortcut, voiceMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try values.decodeIfPresent([GlobalButtonEntry].self, forKey: .buttons), !decoded.isEmpty {
            buttons = decoded
        } else {
            buttons = [GlobalButtonEntry(
                input: try values.decodeIfPresent(ControllerInput.self, forKey: .input) ?? .power,
                single: try values.decodeIfPresent(ButtonMapping.self, forKey: .single)
                    ?? ButtonMapping(action: .openHarnessSwitcher),
                double: try values.decodeIfPresent(ButtonMapping.self, forKey: .double)
                    ?? ButtonMapping(action: .screenshot),
                long: try values.decodeIfPresent(ButtonMapping.self, forKey: .long)
                    ?? ButtonMapping(action: .switchToNativeMode)
            )]
        }
        voice = try values.decodeIfPresent(ButtonMapping.self, forKey: .voice) ?? ButtonMapping(action: .fn)
        voiceFnTap = try values.decodeIfPresent(Bool.self, forKey: .voiceFnTap) ?? false
        voiceTapShortcut = try values.decodeIfPresent(RecordedShortcut.self, forKey: .voiceTapShortcut) ?? .voiceTapDefault
        voiceMode = try values.decodeIfPresent(VoiceTriggerMode.self, forKey: .voiceMode) ?? .hold
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(buttons, forKey: .buttons)
        // Keep the legacy fields in exported JSON so older RcHarness versions
        // continue to use the required first binding when they read a backup.
        try values.encode(input, forKey: .input)
        try values.encode(single, forKey: .single)
        try values.encode(double, forKey: .double)
        try values.encode(long, forKey: .long)
        try values.encode(voice, forKey: .voice)
        try values.encode(voiceFnTap, forKey: .voiceFnTap)
        try values.encodeIfPresent(voiceTapShortcut, forKey: .voiceTapShortcut)
        try values.encodeIfPresent(voiceMode, forKey: .voiceMode)
    }

    var holdShortcut: RecordedShortcut { voice.shortcutForVoice ?? .voiceHoldDefault }

    private static var homeButton: GlobalButtonEntry {
        GlobalButtonEntry(input: .home,
                          single: ButtonMapping(action: .showDesktop),
                          double: ButtonMapping(action: .escape))
    }

    /// Seed each remote only when it has no saved global-button settings.
    static func defaults(for profile: RemoteProfile) -> Self {
        let input: ControllerInput = profile.adapter == .chromecast ? .inputSource : .buttonY
        let tapShortcut = profile.adapter == .chromecast
            ? VoiceShortcutChoice.pairs.first { $0.keys == [.function, .leftCommand] }!.shortcut
            : .voiceTapDefault
        return Self(double: ButtonMapping(action: .disabled), additionalButtons: [
            homeButton,
            GlobalButtonEntry(input: input,
                single: ButtonMapping(action: .switchApplications),
                double: ButtonMapping(action: .showAllWindows),
                long: ButtonMapping(action: .showDesktop))
        ], voiceTapShortcut: tapShortcut, voiceMode: profile.adapter == .chromecast ? .tap : .hold)
            .normalized(for: profile)
    }

    func normalized(for profile: RemoteProfile = RemoteProfiles.xiaomiRC003) -> Self {
        var result = self
        if result.buttons.isEmpty {
            result.buttons = [GlobalButtonEntry(input: .power,
                                                single: ButtonMapping(action: .openHarnessSwitcher),
                                                double: ButtonMapping(action: .screenshot),
                                                long: ButtonMapping(action: .switchToNativeMode))]
        }
        // Upgrade the previous two-key defaults without changing either key's
        // gestures. Custom one/two-key configurations receive empty optional rows.
        let thirdInput: ControllerInput = profile.adapter == .chromecast ? .inputSource : .buttonY
        if result.buttons.count == 2, result.buttons[0].input == .power, result.buttons[1].input == thirdInput,
           !result.buttons.contains(where: { $0.input == .home }) {
            result.buttons.insert(Self.homeButton, at: 1)
        }
        while result.buttons.count < Self.requiredButtonCount {
            result.buttons.append(GlobalButtonEntry())
        }
        // Older configurations could assign the ordinary global role to the voice key.
        if result.buttons[0].input == nil || result.input == .options || !profile.inputs.contains(result.input) {
            result.input = .power
        }
        var usedInputs: Set<ControllerInput> = [result.input]
        if result.buttons.count > 1 {
            for index in result.buttons.indices.dropFirst() {
                guard let input = result.buttons[index].input,
                      input != .options, profile.inputs.contains(input), usedInputs.insert(input).inserted else {
                    result.buttons[index].input = nil
                    continue
                }
            }
        }
        let hold = VoiceShortcutChoice.normalized(result.voice.shortcutForVoice, mode: .hold)
        if result.voice.shortcutForVoice != hold {
            result.voice = hold == .voiceHoldDefault ? ButtonMapping(action: .fn)
                : ButtonMapping(action: .recordedShortcut, shortcut: hold)
        }
        // The old Fn start/stop-tap switch is unrelated to latch-to-talk.
        result.voiceFnTap = false
        result.voiceTapShortcut = VoiceShortcutChoice.normalized(result.voiceTapShortcut, mode: .tap)
        if result.voiceMode == nil || !profile.supportsVoiceTap { result.voiceMode = .hold }
        return result
    }

    static func migrating(_ mapping: RemoteMapping, voiceFnTap: Bool) -> Self {
        // Previously retired power gestures must stay off until explicitly configured.
        Self(single: mapping[.power], double: ButtonMapping(action: .disabled),
             long: ButtonMapping(action: .disabled), voice: mapping[.options], voiceFnTap: voiceFnTap)
    }

    func applying(to mapping: RemoteMapping, profile: RemoteProfile = RemoteProfiles.xiaomiRC003) -> RemoteMapping {
        let settings = normalized(for: profile)
        var result = mapping
        for button in settings.buttons {
            guard let input = button.input else { continue }
            result[input, .single] = button.single
            result[input, .double] = button.double
            result[input, .long] = button.long
        }
        for trigger in ButtonTrigger.allCases { result[.options, trigger] = ButtonMapping(action: .disabled) }
        result[.options] = settings.voiceMode == .tap
            ? ButtonMapping(action: .recordedShortcut, shortcut: settings.voiceTapShortcut)
            : settings.voice
        return result
    }
}

struct SavedKeyProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var applicationPath = ""
    var mapping: RemoteMapping
    /// A name repair must retain the original built-in's reset/deletion rules.
    /// Absent in older backups; ordinary user-created suffixes do not inherit it.
    var protectedBuiltInID: String? = nil
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var builtInHarness: HarnessConfiguration? {
        HarnessConfiguration.builtIn(matchingProfileName: name)
            ?? HarnessConfiguration.defaults.first { $0.id == protectedBuiltInID }
    }

    static func migratingRetiredName(in profiles: [Self], boundProfileID: UUID?) -> [Self] {
        var result = profiles
        if let id = boundProfileID,
           let index = result.firstIndex(where: { $0.id == id && $0.name == "Antigravity 按键方案" }) {
            result[index].name = uniqueName("DeepSeek 按键方案",
                existingNames: profiles.filter { $0.id != id }.map(\.name), fallback: "DeepSeek 按键方案")
        }
        return result
    }

    /// Repair names without changing profile IDs, mappings or array order.
    /// Reserve existing suffixes and give the default profile first choice.
    static func normalizingNames(in profiles: [Self]) -> [Self] {
        var result = profiles
        let reservedNames = profiles.map(\.name)
        var usedNames: [String] = []
        let order = profiles.indices.filter { profiles[$0].id == defaultID }
            + profiles.indices.filter { profiles[$0].id != defaultID }
        for index in order {
            let trimmed = profiles[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || usedNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                result[index].name = uniqueName(trimmed, existingNames: reservedNames + usedNames,
                    fallback: profiles[index].id == defaultID ? "默认方案" : "新方案")
            } else {
                result[index].name = trimmed
            }
            if HarnessConfiguration.builtIn(matchingProfileName: result[index].name) == nil,
               let builtIn = profiles[index].builtInHarness {
                result[index].protectedBuiltInID = builtIn.id
            }
            usedNames.append(result[index].name)
        }
        return result
    }
}

/// Key schemes and bindings belong to a remote model. App metadata, macros and
/// phrases stay shared; only these device-specific settings change on selection.
struct RemoteKeyConfiguration: Codable, Equatable {
    var profiles: [SavedKeyProfile]
    var harnessProfileIDs: [String: UUID]
    var initializedHarnessIDs: [String]
    var globalButtons: GlobalButtonSettings
    var selectedProfileID: UUID?
    var selectedHarnessID: String?

    func normalized() -> Self {
        var result = self
        for (id, profileID) in harnessProfileIDs {
            let currentID = HarnessConfiguration.migratingRetiredID(id)
            guard currentID != id else { continue }
            result.harnessProfileIDs.removeValue(forKey: id)
            // An explicit binding or intentional unbinding of the replacement
            // wins over the retired app's state when both are present.
            if result.harnessProfileIDs[currentID] == nil, !initializedHarnessIDs.contains(currentID) {
                result.harnessProfileIDs[currentID] = profileID
            }
        }
        var initialized = Set<String>()
        result.initializedHarnessIDs = initializedHarnessIDs.map(HarnessConfiguration.migratingRetiredID)
            .filter { initialized.insert($0).inserted }
        result.selectedHarnessID = selectedHarnessID.map(HarnessConfiguration.migratingRetiredID)
        result.profiles = SavedKeyProfile.normalizingNames(in: SavedKeyProfile.migratingRetiredName(
            in: profiles, boundProfileID: result.harnessProfileIDs["deepseek"]))
        return result
    }
}
struct SavedPhrase: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var englishTitle: String = ""
    var englishText: String = ""

    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return englishTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名常用语" : englishTitle
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, text, englishTitle, englishText
    }

    init(id: UUID = UUID(), title: String, text: String,
         englishTitle: String = "", englishText: String = "") {
        self.id = id
        self.title = title
        self.text = text
        self.englishTitle = englishTitle
        self.englishText = englishText
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        text = try values.decode(String.self, forKey: .text)
        // These fields were added after the original Chinese-only format.
        englishTitle = try values.decodeIfPresent(String.self, forKey: .englishTitle) ?? ""
        englishText = try values.decodeIfPresent(String.self, forKey: .englishText) ?? ""
    }
}
/// Shared slots for the modal phrase pad, independent of every key profile.
struct PhraseAssignments: Codable, Equatable {
    static let inputs: [ControllerInput] = [.dpadUp, .dpadDown, .dpadLeft, .dpadRight, .buttonA]
    var slots: [String: UUID] = [:]

    subscript(_ input: ControllerInput) -> UUID? {
        get { slots[input.rawValue] }
        set {
            guard Self.inputs.contains(input) else { return }
            slots[input.rawValue] = newValue
        }
    }
}

struct MacroStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var mapping = ButtonMapping(action: .enter)
    var delay: Double = 0.15
}
struct SavedMacro: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var steps: [MacroStep] = [MacroStep()]
    var tagIDs: Set<String> = [MacroTag.general.id]

    func matches(tagID: String?) -> Bool {
        tagID.map { tagIDs.contains($0) } ?? true
    }

    private enum CodingKeys: String, CodingKey { case id, name, steps, tagIDs }

    init(id: UUID = UUID(), name: String, steps: [MacroStep] = [MacroStep()],
         tagIDs: Set<String> = [MacroTag.general.id]) {
        self.id = id
        self.name = name
        self.steps = steps
        self.tagIDs = tagIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        steps = try values.decode([MacroStep].self, forKey: .steps)
        // Only older records without this field receive labels. Explicit edits,
        // including clearing all labels, survive subsequent loads and imports.
        tagIDs = try values.decodeIfPresent(Set<String>.self, forKey: .tagIDs)
            ?? DefaultMacros.legacyTagIDs(for: id)
    }

    static func uniqueName(_ proposedName: String, existingNames: [String]) -> String {
        RcHarness.uniqueName(proposedName, existingNames: existingNames, fallback: "新组合动作")
    }

    /// Repair old names without changing the IDs used by button mappings.
    static func normalizingNames(in macros: [Self]) -> [Self] {
        let reservedNames = macros.map(\.name)
        var usedNames: [String] = []
        return macros.map { macro in
            var macro = macro
            let trimmed = macro.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || usedNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                macro.name = uniqueName(trimmed, existingNames: reservedNames + usedNames)
            } else {
                macro.name = trimmed
            }
            usedNames.append(macro.name)
            return macro
        }
    }
}
struct UsageDay: Codable, Identifiable {
    var date: Date
    var presses: [String: Int] = [:]
    var voiceSeconds: Double = 0
    var id: Date { date }
    var count: Int { presses.values.reduce(0, +) }
}
struct VoiceUsageSession: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var seconds: Double
}
struct LocalUsage: Codable {
    var days: [UsageDay] = []
    var sessions: [VoiceUsageSession] = []
    mutating func record(_ input: ControllerInput, at date: Date = Date()) {
        let index = dayIndex(date)
        days[index].presses[input.rawValue, default: 0] += 1
    }
    mutating func recordVoice(seconds: Double, at date: Date = Date()) {
        guard seconds.isFinite, seconds > 0 else { return }
        let index = dayIndex(date)
        days[index].voiceSeconds += seconds
        // Keep `sessions` sorted longest first. Retain enough daily entries
        // for every supported remote's ranking; a global limit would permanently
        // discard shorter sessions from recent days. Only the new session's
        // day can exceed its limit, so only that day is trimmed.
        let session = VoiceUsageSession(date: date, seconds: seconds)
        let position = sessions.firstIndex { $0.seconds < seconds } ?? sessions.endIndex
        sessions.insert(session, at: position)
        let calendar = Calendar.current
        let sameDay = sessions.indices.filter { calendar.isDate(sessions[$0].date, inSameDayAs: date) }
        if sameDay.count > Self.sessionsPerDay, let shortest = sameDay.last { sessions.remove(at: shortest) }
    }
    private static var sessionsPerDay: Int { RemoteProfiles.all.map { $0.inputs.count }.max() ?? 0 }
    private mutating func dayIndex(_ date: Date) -> Int {
        let start = Calendar.current.startOfDay(for: date)
        if let index = days.firstIndex(where: { $0.date == start }) { return index }
        days.append(UsageDay(date: start))
        return days.count - 1
    }
}

struct SettingsBackup: Codable, Equatable {
    var version = 3
    var mapping: RemoteMapping
    var profiles: [SavedKeyProfile]
    var macros: [SavedMacro]
    var phrases: [SavedPhrase]
    var phraseAssignments: PhraseAssignments? = nil
    var harnesses: [HarnessConfiguration]? = nil
    var globalButtons: GlobalButtonSettings? = nil
    var macroPresetsVersion: Int? = nil
    var remoteKeyConfigurations: [String: RemoteKeyConfiguration]? = nil
}

/// Returns `proposedName` (trimmed, or `fallback` when blank), adding " 2",
/// " 3"… until it differs from every existing name, ignoring surrounding
/// whitespace and letter case.
func uniqueName(_ proposedName: String, existingNames: [String], fallback: String) -> String {
    let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty ? fallback : trimmed
    var candidate = base
    var suffix = 2
    while existingNames.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(candidate) == .orderedSame }) {
        candidate = "\(base) \(suffix)"
        suffix += 1
    }
    return candidate
}

/// Usage statistics, observed only by the statistics page. Saving encodes the
/// whole history, so writes are coalesced instead of happening on every press.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var usage: LocalUsage
    private let defaults: UserDefaults
    private let saveDelay: TimeInterval
    private var pendingSave: DispatchWorkItem?

    init(defaults: UserDefaults, saveDelay: TimeInterval = 5) {
        self.defaults = defaults
        self.saveDelay = saveDelay
        usage = SettingsStorage.load(LocalUsage.self, SettingsKeys.Stored.usage, defaults: defaults) ?? LocalUsage()
    }

    func record(_ input: ControllerInput, at date: Date = Date()) {
        usage.record(input, at: date)
        scheduleSave()
    }

    func recordVoice(seconds: Double, at date: Date = Date()) {
        usage.recordVoice(seconds: seconds, at: date)
        scheduleSave()
    }

    func clear() {
        pendingSave?.cancel()
        pendingSave = nil
        usage = LocalUsage()
        SettingsStorage.save(usage, SettingsKeys.Stored.usage, defaults: defaults)
    }

    func flush() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        self.pendingSave = nil
        SettingsStorage.save(usage, SettingsKeys.Stored.usage, defaults: defaults)
    }

    private func scheduleSave() {
        guard pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }
}
