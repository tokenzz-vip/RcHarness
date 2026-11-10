import Foundation
import XCTest
@testable import RcHarness

private final class ConfigurationRecordingDefaults: UserDefaults, @unchecked Sendable {
    var writes: [String] = []
    override func set(_ value: Any?, forKey defaultName: String) {
        writes.append(defaultName)
        super.set(value, forKey: defaultName)
    }
}

@MainActor
final class ConfigurationImportTests: XCTestCase {
    private var defaults: ConfigurationRecordingDefaults!
    private var suite: String!
    private var directory: URL!

    override func setUp() async throws {
        suite = "RcHarness.ConfigurationImportTests." + UUID().uuidString
        defaults = ConfigurationRecordingDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    private func file(_ backup: SettingsBackup, named name: String = "configuration.json") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try JSONEncoder().encode(backup).write(to: url)
        return url
    }

    private func incoming(_ title: String = "导入内容") -> SettingsBackup {
        SettingsBackup(version: 4, mapping: .defaults,
            profiles: [SavedKeyProfile(name: "导入方案", mapping: .defaults)],
            macros: [SavedMacro(name: "导入动作")], phrases: [SavedPhrase(title: title, text: title)],
            harnesses: HarnessConfiguration.defaults, macroPresetsVersion: DefaultMacros.version)
    }

    func testPreviewAndCancelDoNotChangeConfigurationStorageOrRuntime() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let before = model.configurationBackup()
        let stored = defaults.persistentDomain(forName: suite)!
        var notifications = 0
        model.onMappingChange = { _ in notifications += 1 }
        model.onHarnessesChange = { notifications += 1 }
        model.onVoiceTriggerChange = { notifications += 1 }
        defaults.writes = []
        model.importConfiguration(from: try file(incoming()))
        let preview = try XCTUnwrap(model.pendingConfigurationImport)
        XCTAssertEqual(preview.prepared.counts.phrases, 1)
        XCTAssertEqual(preview.prepared.counts.macros, 1)
        XCTAssertEqual(model.configurationBackup(), before)
        XCTAssertTrue(defaults.writes.isEmpty)
        XCTAssertTrue(NSDictionary(dictionary: defaults.persistentDomain(forName: suite)!).isEqual(to: stored))
        model.cancelConfigurationImport()
        XCTAssertNil(model.pendingConfigurationImport)
        XCTAssertEqual(model.configurationBackup(), before)
        XCTAssertNil(model.configurationRecoveryDate)
        XCTAssertThrowsError(try model.confirmConfigurationImport(preview.id))
        XCTAssertTrue(defaults.writes.isEmpty)
        XCTAssertEqual(notifications, 0)
    }

    func testConfirmationCommitsOneSnapshotAndPublishesOnlyConsistentState() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let before = model.configurationBackup()
        let url = try file(incoming())
        model.importConfiguration(from: url)
        let preview = try XCTUnwrap(model.pendingConfigurationImport)
        let expected = preview.prepared.backup
        // Replacing the file after preview must not replace the reviewed data.
        try JSONEncoder().encode(incoming("未审阅的内容")).write(to: url)
        var mappingChanges = 0
        var voiceChanges = 0
        var harnessChanges = 0
        model.onMappingChange = { _ in
            mappingChanges += 1
            XCTAssertEqual(model.configurationBackup(), expected)
            XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: self.defaults), expected.phrases)
        }
        model.onVoiceTriggerChange = { voiceChanges += 1 }
        model.onHarnessesChange = { harnessChanges += 1 }
        defaults.writes = []
        try model.confirmConfigurationImport(preview.id)
        XCTAssertEqual(defaults.writes, ["RcHarness." + SettingsKeys.Stored.configurationSnapshot])
        XCTAssertEqual(model.configurationBackup(), expected)
        XCTAssertEqual(model.phrases.first?.title, "导入内容")
        XCTAssertEqual(SettingsStorage.configurationRecovery(defaults: defaults)?.backup, before)
        XCTAssertNotNil(model.configurationRecoveryDate)
        XCTAssertNil(model.pendingConfigurationImport)
        XCTAssertEqual(mappingChanges, 1)
        XCTAssertEqual(voiceChanges, 1)
        XCTAssertEqual(harnessChanges, 1)
    }

    func testRestartCanRestoreEveryRemoteAndItsSelectedProfile() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for remote in RemoteProfiles.all {
            model.selectRemoteProfile(remote.id)
            model.activateHarness("codex")
            model.update(ButtonMapping(action: .paste), for: .buttonA, trigger: .single)
            model.setGlobalInput(.home)
        }
        model.phrases = [SavedPhrase(title: "原内容", text: "原正文")]
        model.phraseAssignments[.dpadUp] = model.phrases[0].id
        model.gain = 7
        model.showKeyProfilePrefix = true
        let before = model.configurationBackup()
        let selected = model.selectedProfileID
        let harness = model.selectedHarnessID
        model.importConfiguration(from: try file(incoming()))
        try model.confirmConfigurationImport(XCTUnwrap(model.pendingConfigurationImport).id)
        let replaced = model.configurationBackup()
        let restarted = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restarted.configurationBackup(), replaced)
        XCTAssertNotNil(restarted.configurationRecoveryDate)
        restarted.previewConfigurationRecovery()
        let preview = try XCTUnwrap(restarted.pendingConfigurationImport)
        XCTAssertTrue(preview.isRecovery)
        defaults.writes = []
        try restarted.confirmConfigurationImport(preview.id)
        XCTAssertEqual(defaults.writes, ["RcHarness." + SettingsKeys.Stored.configurationSnapshot])
        XCTAssertEqual(restarted.configurationBackup(), before)
        XCTAssertEqual(restarted.selectedProfileID, selected)
        XCTAssertEqual(restarted.selectedHarnessID, harness)
        XCTAssertEqual(restarted.gain, 7)
        XCTAssertTrue(restarted.showKeyProfilePrefix)
        let restoredAgain = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restoredAgain.configurationBackup(), before)
        XCTAssertEqual(SettingsStorage.configurationRecovery(defaults: defaults)?.backup, replaced)
    }

    func testMalformedUnsupportedUnreadableAndAmbiguousFilesNeverPartiallyWrite() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let before = model.configurationBackup()
        let malformed = directory.appendingPathComponent("invalid.json")
        try Data("{}".utf8).write(to: malformed)
        var unsupported = incoming()
        unsupported.version = 99
        var duplicateMacros = incoming()
        duplicateMacros.macros.append(duplicateMacros.macros[0])
        var duplicatePhrases = incoming()
        duplicatePhrases.phrases.append(duplicatePhrases.phrases[0])
        var duplicateSteps = incoming()
        duplicateSteps.macros[0].steps.append(duplicateSteps.macros[0].steps[0])
        for url in [malformed, directory.appendingPathComponent("missing.json"),
                    try file(unsupported, named: "unsupported.json"),
                    try file(duplicateMacros, named: "duplicate-macros.json"),
                    try file(duplicatePhrases, named: "duplicate-phrases.json"),
                    try file(duplicateSteps, named: "duplicate-steps.json")] {
            // An invalid new selection also clears any previously prepared import.
            model.importConfiguration(from: try file(incoming()))
            XCTAssertNotNil(model.pendingConfigurationImport)
            defaults.writes = []
            model.importConfiguration(from: url)
            XCTAssertNil(model.pendingConfigurationImport)
            XCTAssertTrue(model.actionMessage.hasPrefix("导入失败"))
            XCTAssertEqual(model.configurationBackup(), before)
            XCTAssertNil(SettingsStorage.configurationRecovery(defaults: defaults))
            XCTAssertTrue(defaults.writes.isEmpty)
        }
    }

    func testFailureToEncodeRecoveryLeavesAllCurrentStateAndStorageUntouched() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let macro = model.addMacro()
        XCTAssertTrue(model.updateMacroSteps([MacroStep(delay: .nan)], for: macro))
        let phrases = model.phrases
        let mapping = model.mapping
        let stored = defaults.persistentDomain(forName: suite)!
        model.importConfiguration(from: try file(incoming()))
        let preview = try XCTUnwrap(model.pendingConfigurationImport)
        defaults.writes = []
        XCTAssertThrowsError(try model.confirmConfigurationImport(preview.id))
        XCTAssertEqual(model.phrases, phrases)
        XCTAssertEqual(model.mapping, mapping)
        XCTAssertTrue(model.macros.first { $0.id == macro }!.steps[0].delay.isNaN)
        XCTAssertTrue(defaults.writes.isEmpty)
        XCTAssertTrue(NSDictionary(dictionary: defaults.persistentDomain(forName: suite)!).isEqual(to: stored))
        XCTAssertEqual(model.pendingConfigurationImport?.id, preview.id)
        XCTAssertNil(model.configurationRecoveryDate)
    }

    func testOrdinaryEditsAndSecondImportKeepTheLatestRecoverableSnapshot() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.importConfiguration(from: try file(incoming("第一次导入")))
        try model.confirmConfigurationImport(XCTUnwrap(model.pendingConfigurationImport).id)
        let originalRecovery = SettingsStorage.configurationRecovery(defaults: defaults)?.backup
        model.phrases[0].text = "导入后修改"
        let macro = model.addMacro()
        XCTAssertTrue(model.renameMacro(macro, name: "新增动作"))
        model.activateHarness("claude")
        model.update(ButtonMapping(action: .copy), for: .buttonB, trigger: .double)
        let edited = model.configurationBackup()
        model.flushPendingWrites() // Simulate the application exit boundary.
        let restarted = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restarted.configurationBackup(), edited)
        XCTAssertEqual(SettingsStorage.configurationRecovery(defaults: defaults)?.backup, originalRecovery)
        restarted.importConfiguration(from: try file(incoming("第二次导入")))
        try restarted.confirmConfigurationImport(XCTUnwrap(restarted.pendingConfigurationImport).id)
        XCTAssertEqual(SettingsStorage.configurationRecovery(defaults: defaults)?.backup, edited)
        restarted.previewConfigurationRecovery()
        restarted.cancelConfigurationImport()
        XCTAssertEqual(restarted.phrases.first?.title, "第二次导入")
        XCTAssertEqual(SettingsStorage.configurationRecovery(defaults: defaults)?.backup, edited)
        restarted.previewConfigurationRecovery()
        try restarted.confirmConfigurationImport(XCTUnwrap(restarted.pendingConfigurationImport).id)
        XCTAssertEqual(restarted.configurationBackup(), edited)
    }

    func testChangingRemoteInvalidatesThePreparedImport() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.importConfiguration(from: try file(incoming()))
        let preview = try XCTUnwrap(model.pendingConfigurationImport)
        let remote = try XCTUnwrap(RemoteProfiles.all.first { $0.id != model.remoteProfile.id })
        model.selectRemoteProfile(remote.id)
        let before = model.configurationBackup()
        defaults.writes = []
        XCTAssertThrowsError(try model.confirmConfigurationImport(preview.id)) {
            XCTAssertEqual($0 as? SettingsBackupError, .stalePreview)
        }
        XCTAssertEqual(model.configurationBackup(), before)
        XCTAssertTrue(defaults.writes.isEmpty)
        XCTAssertNil(model.configurationRecoveryDate)
    }

    func testInvalidSelectionAfterASuccessfulImportPreservesItsRecoveryPoint() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.importConfiguration(from: try file(incoming()))
        try model.confirmConfigurationImport(XCTUnwrap(model.pendingConfigurationImport).id)
        let before = model.configurationBackup()
        let recovery = try XCTUnwrap(SettingsStorage.configurationRecovery(defaults: defaults))
        model.importConfiguration(from: try file(incoming("待取消")))
        let stale = try XCTUnwrap(model.pendingConfigurationImport)
        defaults.writes = []
        model.importConfiguration(from: directory.appendingPathComponent("missing.json"))
        XCTAssertThrowsError(try model.confirmConfigurationImport(stale.id))
        XCTAssertEqual(model.configurationBackup(), before)
        XCTAssertEqual(SettingsStorage.configurationRecovery(defaults: defaults)?.backup, recovery.backup)
        XCTAssertEqual(model.configurationRecoveryDate, recovery.date)
        XCTAssertTrue(defaults.writes.isEmpty)
    }

    func testRemoteRoundTripInvalidatesImportAndRecoveryPreviewsPermanently() throws {
        for isRecovery in [false, true] {
            let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            // Establish a recovery point for both paths, so a rejected stale
            // confirmation must also preserve the existing recovery backup.
            try model.applyConfiguration(incoming())
            if isRecovery {
                model.previewConfigurationRecovery()
            } else {
                model.importConfiguration(from: try file(incoming("旧预览")))
            }
            let preview = try XCTUnwrap(model.pendingConfigurationImport)
            let original = model.remoteProfile.id
            let other = try XCTUnwrap(RemoteProfiles.all.first { $0.id != original })
            model.selectRemoteProfile(other.id)
            XCTAssertNil(model.pendingConfigurationImport)
            model.phrases[0].text = "切换型号期间的新编辑"
            model.selectRemoteProfile(original)
            let before = model.configurationBackup()
            let recovery = SettingsStorage.configurationRecoveryData(defaults: defaults)
            defaults.writes = []
            XCTAssertThrowsError(try model.confirmConfigurationImport(preview.id)) {
                XCTAssertEqual($0 as? SettingsBackupError, .stalePreview)
            }
            XCTAssertEqual(model.configurationBackup(), before)
            XCTAssertEqual(SettingsStorage.configurationRecoveryData(defaults: defaults), recovery)
            XCTAssertTrue(defaults.writes.isEmpty)
            XCTAssertNil(model.pendingConfigurationImport)
        }
    }

    func testSelectingCurrentOrUnknownRemoteKeepsAValidPreview() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.importConfiguration(from: try file(incoming()))
        let preview = try XCTUnwrap(model.pendingConfigurationImport)
        defaults.writes = []
        model.selectRemoteProfile(model.remoteProfile.id)
        model.selectRemoteProfile("unknown-remote")
        XCTAssertEqual(model.pendingConfigurationImport?.id, preview.id)
        XCTAssertTrue(defaults.writes.isEmpty)
        try model.confirmConfigurationImport(preview.id)
        XCTAssertEqual(model.phrases.first?.title, "导入内容")
    }
}
