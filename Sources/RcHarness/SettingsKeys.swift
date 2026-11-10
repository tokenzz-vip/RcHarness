import Foundation

/// Every UserDefaults key in one place. Plain values use the full key;
/// JSON values stored through SettingsStorage use the short name, which
/// SettingsStorage prefixes with "RcHarness.".
enum SettingsKeys {
    static let outputUID = "RcHarness.outputUID"
    static let gain = "RcHarness.gain"
    static let voiceFnTap = "RcHarness.voiceFnTap"
    static let showDockIcon = "RcHarness.showDockIcon"
    static let showKeyProfilePrefix = "RcHarness.showKeyProfilePrefix"
    static let themeMode = "RcHarness.themeMode"
    static let openAtLaunch = "RcHarness.openAtLaunch"
    static let selectedProfileID = "RcHarness.selectedProfileID"
    static let selectedHarnessID = "RcHarness.selectedHarnessID"
    static let profileBindingsVersion = "RcHarness.profileBindingsVersion"
    static let macroPresetsVersion = "RcHarness.macroPresetsVersion"
    static let aiPhrasePresetsInitialized = "RcHarness.aiPhrasePresetsInitialized"
    static let aiPhraseAssignmentsInitialized = "RcHarness.aiPhraseAssignmentsInitialized"
    static let voicePeripheralUUID = "RcHarness.voicePeripheralUUID"
    static func voicePeripheralUUID(profileID: String) -> String {
        "RcHarness.voicePeripheralUUID." + profileID
    }
    static let selectedRemoteProfileID = "RcHarness.selectedRemoteProfileID"

    enum Stored {
        static let configurationSnapshot = "configurationSnapshot"
        static let macroPresetsVersion = "macroPresetsVersion"
        static let globalButtons = "globalButtons"
        static let profiles = "profiles"
        static let remoteKeyConfigurations = "remoteKeyConfigurations"
        static let macros = "macros"
        static let phrases = "phrases"
        static let phraseAssignments = "phraseAssignments"
        static let harnesses = "harnesses"
        static let usage = "usage"
        /// Read only to migrate configurations from before profiles owned the default mapping.
        static let legacyBaseMapping = "baseMapping"
        /// Read only to migrate configurations from before key profiles existed.
        static func legacyMapping(profileID: String) -> String { "mappings.v2." + profileID }
    }
}
