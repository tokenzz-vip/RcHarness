import XCTest
@testable import RcHarness

@MainActor
final class MacroTagTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "RcHarness.MacroTagTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testCatalogAndPresetsCoverEverySupportedHarness() {
        XCTAssertEqual(MacroTag.all.map(\.id), [MacroTag.general.id] + HarnessConfiguration.defaults.map(\.id))
        XCTAssertEqual(MacroTag.all.map(\.name), ["通用"] + HarnessConfiguration.defaults.map(\.name))
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for harness in HarnessConfiguration.defaults {
            let presets = model.macros.filter { $0.matches(tagID: harness.id) }
            XCTAssertFalse(presets.isEmpty, harness.name)
            XCTAssertTrue(presets.allSatisfy { $0.tagIDs == [harness.id] }, harness.name)
        }
        XCTAssertTrue(model.macros.filter { $0.matches(tagID: MacroTag.general.id) }.isEmpty)
    }

    func testLegacyLabelsUsePresetIDsAndPreserveRenamedSteps() throws {
        let presets = DefaultMacros.addingMissing(to: [], since: 0)
        var renamed = try XCTUnwrap(presets.first)
        renamed.name = "我的工作流"
        renamed.steps = [MacroStep(mapping: ButtonMapping(action: .copy), delay: 0.7)]
        let custom = SavedMacro(name: "Codex-新建会话")
        let originals = presets + [custom]
        let data = try legacyData(originals.map { $0.id == renamed.id ? renamed : $0 })
        try SettingsStorage.saveValues([SettingsKeys.Stored.macros: { data }], defaults: defaults)
        defaults.set(DefaultMacros.version, forKey: SettingsKeys.macroPresetsVersion)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.macros.count, originals.count)
        XCTAssertEqual(model.macros.first { $0.id == renamed.id }?.name, renamed.name)
        XCTAssertEqual(model.macros.first { $0.id == renamed.id }?.steps, renamed.steps)
        for original in presets {
            XCTAssertEqual(model.macros.first { $0.id == original.id }?.tagIDs, original.tagIDs)
        }
        XCTAssertEqual(model.macros.first { $0.id == custom.id }?.tagIDs, [MacroTag.general.id])
        model.flushPendingWrites()
        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).macros, model.macros)
    }

    func testMultiTagsFilterIndependentlyAndDoNotChangeExecutionOrBindings() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let id = model.addMacro()
        let initial = try XCTUnwrap(model.macros.first { $0.id == id })
        XCTAssertEqual(initial.tagIDs, [MacroTag.general.id])
        model.update(ButtonMapping(action: .macro, referenceID: id.uuidString), for: .buttonA, trigger: .single)
        let mapping = model.mapping
        let profiles = model.profiles
        let harnesses = model.harnesses
        let plan = try MacroExecutionPlan(initial, macros: model.macros)

        model.updateMacroTags(["codex", "cursor", MacroTag.general.id], for: id)
        let tagged = try XCTUnwrap(model.macros.first { $0.id == id })
        XCTAssertTrue(tagged.matches(tagID: nil))
        XCTAssertTrue(tagged.matches(tagID: "codex"))
        XCTAssertTrue(tagged.matches(tagID: "cursor"))
        XCTAssertTrue(tagged.matches(tagID: MacroTag.general.id))
        XCTAssertFalse(tagged.matches(tagID: "claude"))
        XCTAssertEqual(model.mapping, mapping)
        XCTAssertEqual(model.profiles, profiles)
        XCTAssertEqual(model.harnesses, harnesses)
        let updatedPlan = try MacroExecutionPlan(tagged, macros: model.macros)
        XCTAssertEqual(updatedPlan.events.map(\.mapping), plan.events.map(\.mapping))
        XCTAssertEqual(updatedPlan.events.map(\.offset), plan.events.map(\.offset))

        model.setHarnessEnabled("codex", enabled: false)
        XCTAssertEqual(model.macros.first { $0.id == id }?.tagIDs, tagged.tagIDs)
        XCTAssertTrue(MacroTag.all.contains { $0.id == "codex" })
        model.flushPendingWrites()
        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).macros, model.macros)
    }

    func testEditedAndEmptyTagsSurviveBackupImportRecoveryAndUndo() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let preset = try XCTUnwrap(model.macros.first)
        model.updateMacroTags([], for: preset.id)
        let id = model.addMacro(tagIDs: ["claude", "opencode"])
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        model.updateMacroTags([MacroTag.general.id], for: id)
        try model.applyConfiguration(backup)
        XCTAssertEqual(model.macros.first { $0.id == preset.id }?.tagIDs, [])
        XCTAssertEqual(model.macros.first { $0.id == id }?.tagIDs, ["claude", "opencode"])
        model.previewConfigurationRecovery()
        try model.confirmConfigurationImport(XCTUnwrap(model.pendingConfigurationImport).id)
        XCTAssertEqual(model.macros.first { $0.id == id }?.tagIDs, [MacroTag.general.id])
        try model.applyConfiguration(backup)
        model.deleteMacro(id)
        model.undoDeletion()
        XCTAssertEqual(model.macros.first { $0.id == id }?.tagIDs, ["claude", "opencode"])
        model.flushPendingWrites()
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.macros, model.macros)
        let untagged = try XCTUnwrap(restored.macros.first { $0.id == preset.id })
        XCTAssertTrue(untagged.matches(tagID: nil))
        XCTAssertFalse(untagged.matches(tagID: "codex"))
        XCTAssertFalse(untagged.matches(tagID: MacroTag.general.id))
    }

    func testLegacyBackupImportsTagsWithoutRecreatingDeletedPresets() throws {
        let original = try XCTUnwrap(DefaultMacros.openCode.first)
        var backup = SettingsBackup(mapping: .defaults, profiles: [], macros: [original], phrases: [])
        backup.macroPresetsVersion = DefaultMacros.version
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as? [String: Any])
        object["macros"] = try JSONSerialization.jsonObject(with: legacyData([original]))
        let decoded = try JSONDecoder().decode(SettingsBackup.self, from: JSONSerialization.data(withJSONObject: object))
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        try model.applyConfiguration(decoded)
        XCTAssertEqual(model.macros, [original])
    }

    private func legacyData(_ macros: [SavedMacro]) throws -> Data {
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(macros)) as? [[String: Any]])
        return try JSONSerialization.data(withJSONObject: objects.map { object in
            object.filter { $0.key != "tagIDs" }
        })
    }
}
