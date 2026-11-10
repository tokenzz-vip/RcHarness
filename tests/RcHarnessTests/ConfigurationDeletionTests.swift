import Foundation
import XCTest
@testable import RcHarness

private final class DeletionRecordingDefaults: UserDefaults, @unchecked Sendable {
    var writes: [String] = []
    override func set(_ value: Any?, forKey key: String) {
        writes.append(key)
        super.set(value, forKey: key)
    }
}

@MainActor
final class ConfigurationDeletionTests: XCTestCase {
    private var defaults: DeletionRecordingDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "RcHarness.ConfigurationDeletionTests." + UUID().uuidString
        defaults = DeletionRecordingDefaults(suiteName: suite)!
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func model() -> RemoteDashboardModel {
        RemoteDashboardModel(mapping: .defaults, defaults: defaults)
    }

    func testPhraseReviewCountsBothRemotesGlobalKeysNestedActionsAndAssignments() throws {
        let model = model()
        let phrase = SavedPhrase(title: "被引用", text: "完整内容", englishTitle: "English", englishText: "Full content")
        model.phrases = [phrase]
        model.phraseAssignments = PhraseAssignments()
        model.phraseAssignments[.dpadUp] = phrase.id
        model.phraseAssignments[.buttonA] = phrase.id
        let child = model.addMacro()
        let parent = model.addMacro()
        XCTAssertTrue(model.updateMacroSteps([MacroStep(mapping: ButtonMapping(action: .phrase, referenceID: phrase.id.uuidString))], for: child))
        XCTAssertTrue(model.updateMacroSteps([MacroStep(mapping: ButtonMapping(action: .macro, referenceID: child.uuidString))], for: parent))
        for remote in [RemoteProfiles.xiaomiRC003, RemoteProfiles.googleG9N9N] {
            model.selectRemoteProfile(remote.id)
            model.update(ButtonMapping(action: .phrase, referenceID: phrase.id.uuidString), for: .buttonA, trigger: .single)
            model.update(ButtonMapping(action: .macro, referenceID: parent.uuidString), for: .buttonB, trigger: .double)
            model.update(ButtonMapping(action: .phrase, referenceID: phrase.id.uuidString), for: .power, trigger: .long)
        }
        let before = model.configurationBackup()
        defaults.writes = []
        model.requestDeletion(.phrase(phrase.id))
        let pending = try XCTUnwrap(model.pendingDeletion)
        XCTAssertEqual(pending.impact.remoteCount, 2)
        XCTAssertEqual(pending.impact.directMappings, 4)
        XCTAssertEqual(pending.impact.indirectMappings, 2)
        XCTAssertEqual(pending.impact.macros.map(\.id), [child, parent])
        XCTAssertEqual(pending.impact.macros.map(\.directSteps), [1, 0])
        XCTAssertEqual(pending.impact.assignments, [.dpadUp, .buttonA])
        XCTAssertEqual(model.configurationBackup(), before)
        XCTAssertTrue(defaults.writes.isEmpty)
        model.cancelDeletion()
        model.confirmDeletion(pending.id)
        XCTAssertEqual(model.configurationBackup(), before)
        XCTAssertTrue(model.deletionUndoStack.isEmpty)
        XCTAssertTrue(defaults.writes.isEmpty)
    }

    func testConfirmedPhraseDeleteRetainsReferencesAndUndoRestoresOrderAndAssignments() throws {
        let model = model()
        let entries = (0..<4).map { SavedPhrase(title: "条目\($0)", text: "内容\($0)", englishText: "English \($0)") }
        model.phrases = entries
        model.phraseAssignments = PhraseAssignments()
        model.phraseAssignments[.dpadLeft] = entries[2].id
        model.phraseAssignments[.buttonA] = entries[2].id
        model.update(ButtonMapping(action: .phrase, referenceID: entries[2].id.uuidString), for: .buttonA, trigger: .single)
        let before = model.configurationBackup()
        let displayed = model.orderedPhrases
        model.requestDeletion(.phrase(entries[2].id))
        let pending = try XCTUnwrap(model.pendingDeletion)
        defaults.writes = []
        model.confirmDeletion(pending.id)
        XCTAssertNil(model.pendingDeletion)
        XCTAssertEqual(defaults.writes, ["RcHarness." + SettingsKeys.Stored.configurationSnapshot])
        XCTAssertEqual(model.phrases, [entries[0], entries[1], entries[3]])
        XCTAssertNil(model.phraseAssignments[.dpadLeft])
        XCTAssertNil(model.phraseAssignments[.buttonA])
        XCTAssertEqual(model.mapping[.buttonA].referenceID, entries[2].id.uuidString)
        XCTAssertEqual(model.danglingReferenceCount(), 1)
        XCTAssertEqual(model.deletionUndoStack.count, 1)
        defaults.writes = []
        model.undoDeletion()
        XCTAssertEqual(defaults.writes, ["RcHarness." + SettingsKeys.Stored.configurationSnapshot])
        XCTAssertEqual(model.configurationBackup(), before)
        XCTAssertEqual(model.orderedPhrases, displayed)
        XCTAssertEqual(model.danglingReferenceCount(), 0)
        XCTAssertTrue(model.deletionUndoStack.isEmpty)
        XCTAssertEqual(self.model().configurationBackup(), before)
    }

    func testMacroReviewIncludesTransitiveParentsAndInactiveRemote() throws {
        let model = model()
        let child = model.addMacro()
        let middle = model.addMacro()
        let parent = model.addMacro()
        model.updateMacroSteps([MacroStep(mapping: ButtonMapping(action: .macro, referenceID: child.uuidString))], for: middle)
        model.updateMacroSteps([MacroStep(mapping: ButtonMapping(action: .macro, referenceID: middle.uuidString))], for: parent)
        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        model.update(ButtonMapping(action: .macro, referenceID: child.uuidString), for: .buttonA, trigger: .single)
        model.update(ButtonMapping(action: .macro, referenceID: parent.uuidString), for: .buttonB, trigger: .long)
        model.selectRemoteProfile(RemoteProfiles.xiaomiRC003.id)
        model.update(ButtonMapping(action: .macro, referenceID: middle.uuidString), for: .power, trigger: .single)
        let before = model.configurationBackup()
        model.requestDeletion(.macro(child))
        let pending = try XCTUnwrap(model.pendingDeletion)
        XCTAssertEqual(pending.impact.remoteCount, 2)
        XCTAssertEqual(pending.impact.directMappings, 1)
        XCTAssertEqual(pending.impact.indirectMappings, 2)
        XCTAssertEqual(pending.impact.macros.map(\.id), [middle, parent])
        model.confirmDeletion(pending.id)
        XCTAssertFalse(model.macros.contains { $0.id == child })
        XCTAssertEqual(model.macros.first { $0.id == middle }?.steps.first?.mapping.referenceID, child.uuidString)
        model.undoDeletion()
        XCTAssertEqual(model.configurationBackup(), before)
    }

    func testUnreferencedDeletesAreImmediateAndSupportMultipleUndosWithoutLosingOtherEdits() {
        let model = model()
        let entries = (0..<4).map { SavedPhrase(title: "顺序\($0)", text: "正文\($0)") }
        model.phrases = entries
        model.phraseAssignments = PhraseAssignments()
        let macro = model.addMacro()
        let originalMacros = model.macros
        model.requestDeletion(.phrase(entries[1].id))
        XCTAssertNil(model.pendingDeletion)
        model.requestDeletion(.macro(macro))
        XCTAssertNil(model.pendingDeletion)
        model.requestDeletion(.phrase(entries[2].id))
        XCTAssertEqual(model.deletionUndoStack.count, 3)
        model.phrases[0].text = "后续修改"
        let added = SavedPhrase(title: "后续新增", text: "新增")
        model.phrases.append(added)
        model.undoDeletion()
        model.undoDeletion()
        model.undoDeletion()
        XCTAssertEqual(model.phrases.map(\.id), entries.map(\.id) + [added.id])
        XCTAssertEqual(model.phrases[0].text, "后续修改")
        XCTAssertEqual(model.phrases[1], entries[1])
        XCTAssertEqual(model.phrases[2], entries[2])
        XCTAssertEqual(model.macros, originalMacros)
        XCTAssertTrue(model.deletionUndoStack.isEmpty)
    }

    func testUndoRefusesToOverwriteNewAssignmentAndCanRetry() throws {
        let model = model()
        let original = SavedPhrase(title: "原分配", text: "原")
        let other = SavedPhrase(title: "新分配", text: "新")
        model.phrases = [original, other]
        model.phraseAssignments = PhraseAssignments()
        model.phraseAssignments[.dpadDown] = original.id
        model.requestDeletion(.phrase(original.id))
        model.confirmDeletion(try XCTUnwrap(model.pendingDeletion).id)
        model.phraseAssignments[.dpadDown] = other.id
        let before = model.configurationBackup()
        defaults.writes = []
        model.undoDeletion()
        XCTAssertEqual(model.configurationBackup(), before)
        XCTAssertTrue(defaults.writes.isEmpty)
        XCTAssertEqual(model.deletionUndoStack.count, 1)
        XCTAssertTrue(model.actionMessage.contains("已重新分配"))
        model.phraseAssignments[.dpadDown] = nil
        model.undoDeletion()
        XCTAssertEqual(model.phrases, [original, other])
        XCTAssertEqual(model.phraseAssignments[.dpadDown], original.id)
    }

    func testProfileUndoRestoresOriginalRemotePositionAndSelectionAfterSwitchingRemote() throws {
        let model = model()
        let remoteID = model.remoteProfile.id
        XCTAssertTrue(model.saveProfile(name: "可删除方案"))
        let id = try XCTUnwrap(model.selectedProfileID)
        model.update(ButtonMapping(action: .paste), for: .buttonA, trigger: .single)
        let original = model.profiles
        model.requestDeletion(.profile(id, remoteID: remoteID))
        XCTAssertNil(model.pendingDeletion)
        XCTAssertFalse(model.profiles.contains { $0.id == id })
        XCTAssertEqual(model.selectedProfileID, SavedKeyProfile.defaultID)
        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .single)
        let google = model.configurationBackup().remoteKeyConfigurations?[RemoteProfiles.googleG9N9N.id]
        model.undoDeletion()
        XCTAssertEqual(model.configurationBackup().remoteKeyConfigurations?[RemoteProfiles.googleG9N9N.id], google)
        XCTAssertEqual(model.remoteProfile.id, RemoteProfiles.googleG9N9N.id)
        model.selectRemoteProfile(remoteID)
        XCTAssertEqual(model.profiles, original)
        XCTAssertEqual(model.selectedProfileID, id)
        XCTAssertEqual(model.mapping[.buttonA].action, .paste)
        let restarted = self.model()
        XCTAssertEqual(restarted.profiles, original)
        XCTAssertEqual(restarted.selectedProfileID, id)
    }

    func testBoundOrBuiltInProfilesStayProtectedAndMissingIDsDoNothing() throws {
        let model = model()
        model.activateHarness("codex")
        let builtIn = try XCTUnwrap(model.selectedProfileID)
        XCTAssertTrue(model.saveProfile(name: "绑定方案"))
        let bound = try XCTUnwrap(model.selectedProfileID)
        model.bindProfile(bound, to: "claude")
        let before = model.configurationBackup()
        defaults.writes = []
        for id in [SavedKeyProfile.defaultID, builtIn, bound, UUID()] {
            model.requestDeletion(.profile(id, remoteID: model.remoteProfile.id))
        }
        model.requestDeletion(.macro(UUID()))
        model.requestDeletion(.phrase(UUID()))
        XCTAssertEqual(model.configurationBackup(), before)
        XCTAssertTrue(model.deletionUndoStack.isEmpty)
        XCTAssertNil(model.pendingDeletion)
        XCTAssertTrue(defaults.writes.isEmpty)
    }

    func testConfirmationRechecksChangedImpactAndRequiresNewReview() throws {
        let model = model()
        let phrase = SavedPhrase(title: "确认前变化", text: "正文")
        model.phrases = [phrase]
        model.phraseAssignments = PhraseAssignments()
        model.update(ButtonMapping(action: .phrase, referenceID: phrase.id.uuidString), for: .buttonA, trigger: .single)
        model.requestDeletion(.phrase(phrase.id))
        let first = try XCTUnwrap(model.pendingDeletion)
        model.update(ButtonMapping(action: .phrase, referenceID: phrase.id.uuidString), for: .buttonB, trigger: .double)
        defaults.writes = []
        model.confirmDeletion(first.id)
        let latest = try XCTUnwrap(model.pendingDeletion)
        XCTAssertNotEqual(latest.id, first.id)
        XCTAssertEqual(latest.impact.directMappings, 2)
        XCTAssertEqual(model.phrases, [phrase])
        XCTAssertTrue(defaults.writes.isEmpty)
        model.confirmDeletion(first.id)
        XCTAssertEqual(model.phrases, [phrase])
        model.confirmDeletion(latest.id)
        XCTAssertTrue(model.phrases.isEmpty)
    }

    func testDeletionAndUndoKeepImportRecoveryPointAndImportClearsDeletionHistory() throws {
        let model = model()
        let original = model.configurationBackup()
        try model.applyConfiguration(original)
        let recovery = try XCTUnwrap(SettingsStorage.configurationRecovery(defaults: defaults))
        let id = model.addMacro()
        model.requestDeletion(.macro(id))
        model.undoDeletion()
        model.requestDeletion(.macro(id))
        XCTAssertEqual(SettingsStorage.configurationRecovery(defaults: defaults)?.backup, recovery.backup)
        XCTAssertEqual(SettingsStorage.configurationRecovery(defaults: defaults)?.date, recovery.date)
        XCTAssertEqual(model.configurationRecoveryDate, recovery.date)
        XCTAssertEqual(model.deletionUndoStack.count, 1)
        try model.applyConfiguration(original)
        XCTAssertTrue(model.deletionUndoStack.isEmpty)
        XCTAssertNil(model.pendingDeletion)
        let before = model.configurationBackup()
        defaults.writes = []
        model.undoDeletion()
        XCTAssertEqual(model.configurationBackup(), before)
        XCTAssertTrue(defaults.writes.isEmpty)
    }

    func testEncodingFailureDoesNotDeleteOrDiscardUndoHistory() {
        let model = model()
        let first = model.addMacro()
        model.requestDeletion(.macro(first))
        let invalid = model.addMacro()
        model.updateMacroSteps([MacroStep(delay: .nan)], for: invalid)
        let phrase = SavedPhrase(title: "不能部分删除", text: "正文")
        model.phrases = [phrase]
        model.phraseAssignments = PhraseAssignments()
        defaults.writes = []
        model.requestDeletion(.phrase(phrase.id))
        XCTAssertEqual(model.phrases, [phrase])
        XCTAssertEqual(model.deletionUndoStack.count, 1)
        XCTAssertTrue(defaults.writes.isEmpty)
        model.undoDeletion()
        XCTAssertFalse(model.macros.contains { $0.id == first })
        XCTAssertEqual(model.deletionUndoStack.count, 1)
        XCTAssertTrue(defaults.writes.isEmpty)
    }

    func testUndoKeepsALaterProfileSelectionAndUnrelatedRuntimeState() throws {
        let model = model()
        model.saveProfile(name: "删除的方案")
        let deleted = try XCTUnwrap(model.selectedProfileID)
        model.saveProfile(name: "后来选择的方案")
        let later = try XCTUnwrap(model.selectedProfileID)
        model.activateProfile(deleted)
        model.requestDeletion(.profile(deleted, remoteID: model.remoteProfile.id))
        model.activateProfile(later)
        model.operationMode = .native
        model.gain = 11
        var voiceChanges = 0
        model.onVoiceTriggerChange = { voiceChanges += 1 }
        model.undoDeletion()
        XCTAssertEqual(model.selectedProfileID, later)
        XCTAssertEqual(model.operationMode, .native)
        XCTAssertEqual(model.gain, 11)
        XCTAssertEqual(voiceChanges, 0)
        XCTAssertTrue(model.profiles.contains { $0.id == deleted })
    }

    func testMacroNameConflictDoesNotDiscardUndoAndCanBeResolved() throws {
        let model = model()
        let original = model.addMacro()
        XCTAssertTrue(model.renameMacro(original, name: "保留名称"))
        model.requestDeletion(.macro(original))
        let replacement = model.addMacro()
        XCTAssertTrue(model.renameMacro(replacement, name: "保留名称"))
        let before = model.configurationBackup()
        defaults.writes = []
        model.undoDeletion()
        XCTAssertEqual(model.configurationBackup(), before)
        XCTAssertTrue(defaults.writes.isEmpty)
        XCTAssertEqual(model.deletionUndoStack.count, 1)
        XCTAssertTrue(model.renameMacro(replacement, name: "新内容"))
        model.undoDeletion()
        XCTAssertEqual(model.macros.first { $0.id == original }?.name, "保留名称")
        XCTAssertEqual(model.macros.first { $0.id == replacement }?.name, "新内容")
        XCTAssertTrue(model.deletionUndoStack.isEmpty)
    }

    func testDismissUndoDoesNotChangeConfigurationOrRecreateDeletedObjectAfterRestart() {
        let model = model()
        let id = model.addMacro()
        model.requestDeletion(.macro(id))
        let after = model.configurationBackup()
        defaults.writes = []
        model.dismissDeletionUndo()
        model.undoDeletion()
        XCTAssertEqual(model.configurationBackup(), after)
        XCTAssertTrue(defaults.writes.isEmpty)
        XCTAssertTrue(model.deletionUndoStack.isEmpty)
        let restarted = self.model()
        XCTAssertFalse(restarted.macros.contains { $0.id == id })
        XCTAssertTrue(restarted.deletionUndoStack.isEmpty)
    }

    func testPhraseAndMacroIDsUseSeparateNamespacesWhenComputingDependencies() {
        let model = model()
        let id = model.addMacro()
        model.phrases = [SavedPhrase(id: id, title: "跨类型同 ID", text: "正文")]
        model.phraseAssignments = PhraseAssignments()
        model.updateMacroSteps([MacroStep(mapping: ButtonMapping(action: .phrase, referenceID: id.uuidString))], for: id)
        let impact = model.deletionImpact(for: .phrase(id))
        XCTAssertEqual(impact.macros.map(\.id), [id])
        XCTAssertEqual(impact.macros.first?.directSteps, 1)
        XCTAssertTrue(impact.hasReferences)
    }
}
