import Foundation

enum SettingsStorage {
    private struct ConfigurationSnapshot: Codable {
        var values: [String: Data]
        var recovery: Data?
    }

    private static let configurationKeys: Set<String> = [
        SettingsKeys.Stored.profiles, SettingsKeys.Stored.harnesses, SettingsKeys.Stored.macros,
        SettingsKeys.Stored.phrases, SettingsKeys.Stored.phraseAssignments,
        SettingsKeys.Stored.globalButtons, SettingsKeys.Stored.remoteKeyConfigurations,
        SettingsKeys.Stored.macroPresetsVersion,
    ]

    private static func snapshot(defaults: UserDefaults) -> ConfigurationSnapshot? {
        load(ConfigurationSnapshot.self, SettingsKeys.Stored.configurationSnapshot, defaults: defaults)
    }

    private static func data(for key: String, defaults: UserDefaults) -> Data? {
        if configurationKeys.contains(key), let snapshot = snapshot(defaults: defaults) {
            return snapshot.values[key]
        }
        return defaults.data(forKey: "RcHarness." + key)
    }

    static func contains(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        data(for: key, defaults: defaults) != nil
    }

    static func load<T: Decodable>(_ type: T.Type, _ key: String, defaults: UserDefaults = .standard) -> T? {
        guard let data = data(for: key, defaults: defaults) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Initialization may immediately save defaults over this key.
            // Retain the unreadable data separately for manual recovery.
            defaults.set(data, forKey: "RcHarness.recovery." + key)
            Log.settings.error("Settings could not be decoded; recovery copy saved for \(key, privacy: .public)")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, _ key: String, defaults: UserDefaults = .standard) {
        do {
            try saveValues([key: { try JSONEncoder().encode(value) }], defaults: defaults)
        } catch {
            Log.settings.error("Settings could not be encoded for \(key, privacy: .public); previous value retained")
        }
    }

    /// Encode changed collections once and merge an imported snapshot once.
    /// Keep the existing split keys on installations that have not imported a snapshot.
    static func saveValues(_ values: [String: () throws -> Data], defaults: UserDefaults) throws {
        let encoded = try values.mapValues { try $0() }
        if !configurationKeys.isDisjoint(with: encoded.keys), var snapshot = snapshot(defaults: defaults) {
            for (key, data) in encoded where configurationKeys.contains(key) { snapshot.values[key] = data }
            // Complete encoding before changing any preferences.
            let data = try JSONEncoder().encode(snapshot)
            defaults.set(data, forKey: "RcHarness." + SettingsKeys.Stored.configurationSnapshot)
            for (key, data) in encoded where !configurationKeys.contains(key) {
                defaults.set(data, forKey: "RcHarness." + key)
            }
        } else {
            for (key, data) in encoded { defaults.set(data, forKey: "RcHarness." + key) }
        }
    }

    static func configurationRecoveryData(defaults: UserDefaults = .standard) -> Data? {
        snapshot(defaults: defaults)?.recovery
    }

    /// Values and recovery data are fully encoded before one preferences write.
    static func commitConfigurationValues(_ values: [String: Data], recovery: Data?,
                                          defaults: UserDefaults = .standard) throws {
        let encoded = try JSONEncoder().encode(ConfigurationSnapshot(values: values, recovery: recovery))
        defaults.set(encoded, forKey: "RcHarness." + SettingsKeys.Stored.configurationSnapshot)
    }
}
