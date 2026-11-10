import Foundation

struct ConfigurationRecovery: Codable {
    let date: Date
    let backup: SettingsBackup
}

struct ConfigurationCounts {
    let remotes: Int
    let profiles: Int
    let harnesses: Int
    let bindings: Int
    let macros: Int
    let phrases: Int
    let assignments: Int

    init(_ backup: SettingsBackup) {
        let configurations = backup.remoteKeyConfigurations ?? [:]
        remotes = configurations.count
        profiles = configurations.values.reduce(0) { $0 + $1.profiles.count }
        harnesses = backup.harnesses?.count ?? 0
        bindings = configurations.values.reduce(0) { $0 + $1.harnessProfileIDs.count }
        macros = backup.macros.count
        phrases = backup.phrases.count
        assignments = backup.phraseAssignments?.slots.count ?? 0
    }
}

struct ConfigurationImportPreview: Identifiable {
    let id = UUID()
    let source: String
    let isRecovery: Bool
    let current: ConfigurationCounts
    let prepared: PreparedConfiguration
}

/// A decoded, validated and normalized value. Preparing it has no model or disk side effects.
struct PreparedConfiguration {
    let remoteProfileID: String
    let backup: SettingsBackup
    let counts: ConfigurationCounts
    let danglingReferences: Int
    let repairedNames: Int
    let isLegacy: Bool

    init(_ original: SettingsBackup, remoteProfile: RemoteProfile, preservingSelection: Bool = false) throws {
        remoteProfileID = remoteProfile.id
        guard (1...4).contains(original.version) else { throw SettingsBackupError.unsupportedVersion(original.version) }
        guard Set(original.macros.map(\.id)).count == original.macros.count,
              Set(original.phrases.map(\.id)).count == original.phrases.count,
              original.macros.allSatisfy({ macro in
                  Set(macro.steps.map(\.id)).count == macro.steps.count && macro.steps.allSatisfy { $0.delay.isFinite }
              }) else { throw SettingsBackupError.invalidFormat }
        guard original.phraseAssignments?.slots.keys.allSatisfy({ key in
            PhraseAssignments.inputs.contains { $0.rawValue == key }
        }) ?? true else { throw SettingsBackupError.invalidFormat }

        let version = original.macroPresetsVersion ?? 0
        let macros = DefaultMacros.addingMissing(to: SavedMacro.normalizingNames(in: original.macros), since: version)
        var configurations = (original.remoteKeyConfigurations ?? [:]).mapValues { $0.normalized() }
        isLegacy = configurations.isEmpty
        let current = configurations[remoteProfile.id]
        var harnesses = original.harnesses ?? HarnessConfiguration.defaults
        if !isLegacy {
            harnesses = harnesses.map { harness in
                var harness = harness.migratingRetiredBuiltIn()
                harness.profileID = current?.harnessProfileIDs[harness.id]
                harness.didInitializeDefaultProfile = current?.initializedHarnessIDs.contains(harness.id) ?? false
                harness.legacyMapping = .defaults
                harness.hasLegacyMapping = false
                return harness
            }
        }
        let normalized = NormalizedKeyProfiles(profiles: isLegacy ? original.profiles : current?.profiles ?? [],
            harnesses: harnesses, selectedHarnessID: preservingSelection ? current?.selectedHarnessID : nil,
            macros: macros, migrateLegacy: isLegacy && original.version == 1,
            defaultMapping: isLegacy ? original.mapping : .defaults)
        let defaultMapping = normalized.profiles.first { $0.id == SavedKeyProfile.defaultID }!.mapping
        let globals = (current?.globalButtons ?? (isLegacy ? original.globalButtons : nil)
            ?? .migrating(defaultMapping, voiceFnTap: false)).normalized(for: remoteProfile)
        var selectedProfileID = SavedKeyProfile.defaultID
        var selectedHarnessID: String?
        if preservingSelection {
            if let harness = normalized.harnesses.first(where: { $0.id == normalized.selectedHarnessID && $0.isEnabled }),
               let id = harness.profileID, normalized.profiles.contains(where: { $0.id == id }) {
                selectedProfileID = id
                selectedHarnessID = harness.id
            } else if let id = current?.selectedProfileID, normalized.profiles.contains(where: { $0.id == id }) {
                selectedProfileID = id
            }
        }
        configurations[remoteProfile.id] = RemoteKeyConfiguration(profiles: normalized.profiles,
            harnessProfileIDs: Dictionary(uniqueKeysWithValues: normalized.harnesses.compactMap { harness in
                harness.profileID.map { (harness.id, $0) }
            }), initializedHarnessIDs: normalized.harnesses.filter(\.didInitializeDefaultProfile).map(\.id),
            globalButtons: globals, selectedProfileID: selectedProfileID, selectedHarnessID: selectedHarnessID)
        var result = SettingsBackup(version: 4, mapping: defaultMapping, profiles: normalized.profiles,
            macros: macros, phrases: original.phrases, harnesses: normalized.harnesses, globalButtons: globals,
            macroPresetsVersion: max(version, DefaultMacros.version), remoteKeyConfigurations: configurations)
        result.phraseAssignments = original.phraseAssignments ?? PhraseAssignments()
        // This also rejects values that cannot be represented in the persisted snapshot.
        _ = try JSONEncoder().encode(result)
        backup = result
        counts = ConfigurationCounts(result)
        danglingReferences = Self.danglingReferenceCount(in: result)
        func renamed(_ originals: [SavedKeyProfile], _ repaired: [SavedKeyProfile]) -> Int {
            let names = Dictionary(repaired.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            return originals.filter { profile in names[profile.id].map { $0 != profile.name } ?? false }.count
        }
        if isLegacy {
            repairedNames = renamed(original.profiles, result.profiles)
        } else {
            repairedNames = (original.remoteKeyConfigurations ?? [:]).reduce(0) { count, entry in
                count + renamed(entry.value.profiles, configurations[entry.key]?.profiles ?? [])
            }
        }
    }

    static func danglingReferenceCount(in backup: SettingsBackup) -> Int {
        let phraseIDs = Set(backup.phrases.map(\.id.uuidString))
        let macroIDs = Set(backup.macros.map(\.id.uuidString))
        func isDangling(_ mapping: ButtonMapping) -> Bool {
            switch mapping.action {
            case .phrase: return mapping.referenceID.map(phraseIDs.contains) != true
            case .macro: return mapping.referenceID.map(macroIDs.contains) != true
            default: return false
            }
        }
        let configurations = Array((backup.remoteKeyConfigurations ?? [:]).values)
        let buttons = configurations.flatMap(\.profiles).flatMap(\.mapping.buttons.values).filter(isDangling).count
        let globals = configurations.flatMap {
            [$0.globalButtons.single, $0.globalButtons.double, $0.globalButtons.long, $0.globalButtons.voice]
        }.filter(isDangling).count
        let steps = backup.macros.flatMap(\.steps).map(\.mapping).filter(isDangling).count
        let slots = (backup.phraseAssignments ?? PhraseAssignments()).slots.values.filter { !phraseIDs.contains($0.uuidString) }.count
        return buttons + globals + steps + slots
    }

    var notices: [String] {
        var messages: [String] = []
        if danglingReferences > 0 { messages.append("\(danglingReferences) 处常用语或组合动作引用已失效，请重新选择。") }
        if repairedNames > 0 { messages.append("已修复 \(repairedNames) 个方案名称，映射与绑定已保留。") }
        return messages
    }
}

// Import-specific encoding stays out of the standalone preferences module.
extension SettingsStorage {
    static func configurationRecovery(defaults: UserDefaults = .standard) -> ConfigurationRecovery? {
        guard let data = configurationRecoveryData(defaults: defaults) else { return nil }
        return try? JSONDecoder().decode(ConfigurationRecovery.self, from: data)
    }

    /// Encode everything, including the recovery point, before one preferences write.
    /// Subsequent edits use this snapshot; old split keys remain migration fallbacks.
    static func commitConfiguration(_ backup: SettingsBackup, recovery: ConfigurationRecovery?,
                                    defaults: UserDefaults = .standard) throws {
        let encoder = JSONEncoder()
        let values = [
            SettingsKeys.Stored.profiles: try encoder.encode(backup.profiles),
            SettingsKeys.Stored.harnesses: try encoder.encode(backup.harnesses ?? HarnessConfiguration.defaults),
            SettingsKeys.Stored.macros: try encoder.encode(backup.macros),
            SettingsKeys.Stored.phrases: try encoder.encode(backup.phrases),
            SettingsKeys.Stored.phraseAssignments: try encoder.encode(backup.phraseAssignments ?? PhraseAssignments()),
            SettingsKeys.Stored.globalButtons: try encoder.encode(backup.globalButtons ?? GlobalButtonSettings()),
            SettingsKeys.Stored.remoteKeyConfigurations: try encoder.encode(backup.remoteKeyConfigurations ?? [:]),
            SettingsKeys.Stored.macroPresetsVersion: try encoder.encode(backup.macroPresetsVersion ?? DefaultMacros.version),
        ]
        let recoveryData = try recovery.map { try encoder.encode($0) }
        try commitConfigurationValues(values, recovery: recoveryData, defaults: defaults)
    }
}
