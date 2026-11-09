import AppKit
import Foundation

struct HarnessConfiguration: Equatable, Identifiable {
    let id: String
    var name: String
    var bundleIdentifier: String?
    var applicationPath: String?
    var isEnabled = true
    /// The profile owns the mapping and can be shared by multiple Harnesses.
    var profileID: UUID? = nil
    /// Persisted with exports so a user's later unbinding or deletion stays intentional.
    var didInitializeDefaultProfile = false
    /// Used only when migrating older exports; never written to new files.
    var legacyMapping: RemoteMapping = .defaults
    var hasLegacyMapping = false

    var isBuiltIn: Bool { Self.builtInIDs.contains(id) }
    var initialProfileName: String? {
        Self.defaults.first { $0.id == id }.map { $0.name + " 按键方案" }
    }

    func defaultMapping(macros: [SavedMacro]) -> RemoteMapping {
        id == "codex" ? .codexDefaults(macros: macros) : .defaults
    }

    static func builtIn(matchingProfileName profileName: String) -> Self? {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return defaults.first { harness in
            name.caseInsensitiveCompare(harness.name) == .orderedSame
                || name.caseInsensitiveCompare(harness.name + " 按键方案") == .orderedSame
        }
    }

    private static let workBuddy = Self(id: "workbuddy", name: "WorkBuddy", bundleIdentifier: "com.tencent.workbuddy.mac")
    private static let builtInIDs = Set(defaults.map(\.id))
    static let defaults: [Self] = [
        Self(id: "codex", name: "Codex", bundleIdentifier: "com.openai.codex"),
        Self(id: "claude", name: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop"),
        Self(id: "cursor", name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92"),
        Self(id: "deepseek", name: "DeepSeek", bundleIdentifier: "com.deepseek.dsh"),
        workBuddy,
    ]

    /// Add newly introduced apps to saved configurations without replacing existing entries.
    static func addingNewBuiltIns(to harnesses: [Self]) -> [Self] {
        var result = harnesses
        for builtIn in defaults where !result.contains(where: {
            $0.id == builtIn.id || builtIn.matches(applicationPath: $0.applicationPath, bundleIdentifier: $0.bundleIdentifier)
        }) {
            result.append(builtIn)
        }
        return result
    }

    private var bundleIdentifiers: [String] {
        [bundleIdentifier].compactMap { $0 } + (id == Self.workBuddy.id ? ["com.workbuddy.workbuddy"] : [])
    }

    /// Replace the retired built-in while retaining its scheme and enabled state.
    func migratingRetiredBuiltIn() -> Self {
        let migratedID = Self.migratingRetiredID(id)
        guard migratedID != id else { return self }
        var replacement = Self.defaults.first { $0.id == migratedID }!
        replacement.isEnabled = isEnabled
        replacement.profileID = profileID
        replacement.didInitializeDefaultProfile = didInitializeDefaultProfile
        replacement.legacyMapping = legacyMapping
        replacement.hasLegacyMapping = hasLegacyMapping
        return replacement
    }

    static func migratingRetiredID(_ id: String) -> String {
        id == "antigravity" ? "deepseek" : id
    }

    func matches(applicationPath path: String?, bundleIdentifier identifier: String?) -> Bool {
        if bundleIdentifier != nil, let identifier {
            return bundleIdentifiers.contains { $0.caseInsensitiveCompare(identifier) == .orderedSame }
        }
        guard let applicationPath, let path else { return false }
        return URL(fileURLWithPath: applicationPath).standardizedFileURL == URL(fileURLWithPath: path).standardizedFileURL
    }

    var installedApplicationURL: URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
        }
        guard let applicationPath, FileManager.default.fileExists(atPath: applicationPath) else { return nil }
        return URL(fileURLWithPath: applicationPath)
    }
}

extension HarnessConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, bundleIdentifier, applicationPath, isEnabled, profileID, didInitializeDefaultProfile, mapping
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        applicationPath = try values.decodeIfPresent(String.self, forKey: .applicationPath)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        profileID = try values.decodeIfPresent(UUID.self, forKey: .profileID)
        didInitializeDefaultProfile = try values.decodeIfPresent(Bool.self, forKey: .didInitializeDefaultProfile) ?? false
        legacyMapping = try values.decodeIfPresent(RemoteMapping.self, forKey: .mapping) ?? .defaults
        hasLegacyMapping = values.contains(.mapping)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try values.encodeIfPresent(applicationPath, forKey: .applicationPath)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encodeIfPresent(profileID, forKey: .profileID)
        try values.encode(didInitializeDefaultProfile, forKey: .didInitializeDefaultProfile)
    }
}
