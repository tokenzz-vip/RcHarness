import Foundation

/// Shared normalization for startup, device switching and import previews.
/// It owns values only and never writes settings or publishes runtime changes.
struct NormalizedKeyProfiles {
    var profiles: [SavedKeyProfile]
    var harnesses: [HarnessConfiguration]
    var selectedHarnessID: String?

    init(profiles initialProfiles: [SavedKeyProfile], harnesses initialHarnesses: [HarnessConfiguration],
         selectedHarnessID initialHarnessID: String?, macros: [SavedMacro],
         migrateLegacy: Bool, defaultMapping: RemoteMapping, remoteProfile: RemoteProfile) {
        profiles = initialProfiles
        harnesses = initialHarnesses
        selectedHarnessID = initialHarnessID
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
                                              mapping: harnesses[index].defaultMapping(macros: macros, remoteProfile: remoteProfile))
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
}
