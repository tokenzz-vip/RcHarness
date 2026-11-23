import Foundation

/// A sheet owns its edits until Save; dismissing it simply discards this value.
@MainActor
struct MappingEditorDraft {
    let input: ControllerInput
    let remoteID: String
    let profileID: UUID?
    let isGlobal: Bool
    let mappingName: String
    let originalMapping: RemoteMapping
    let originalVoiceMode: VoiceTriggerMode
    let originalVoiceHoldShortcut: RecordedShortcut
    let originalVoiceTapShortcut: RecordedShortcut
    var trigger: ButtonTrigger
    var mapping: RemoteMapping
    var voiceMode: VoiceTriggerMode
    var voiceHoldShortcut: RecordedShortcut
    var voiceTapShortcut: RecordedShortcut

    var hasIncompleteShortcut: Bool {
        input != .options && input.supportedTriggers.contains { trigger in
            let value = mapping[input, trigger]
            return value != originalMapping[input, trigger]
                && value.action == .recordedShortcut && value.shortcut == nil
        }
    }

    init(model: RemoteDashboardModel) {
        input = model.selectedInput
        remoteID = model.remoteProfile.id
        profileID = model.selectedProfileID
        isGlobal = model.isGlobalInput(input)
        mappingName = model.activeMappingName
        trigger = model.selectedTrigger
        originalMapping = model.effectiveMapping
        mapping = originalMapping
        originalVoiceMode = model.voiceMode
        voiceMode = originalVoiceMode
        originalVoiceHoldShortcut = model.voiceHoldShortcut
        voiceHoldShortcut = originalVoiceHoldShortcut
        originalVoiceTapShortcut = model.voiceTapShortcut
        voiceTapShortcut = originalVoiceTapShortcut
    }
}
