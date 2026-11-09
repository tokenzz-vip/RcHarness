import XCTest
@testable import RcHarness

@MainActor
final class MacroTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "RcHarness.MacroTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testCreationSkipsExistingSuffixesAndPersistsUniqueNames() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let defaultNames = model.macros.map(\.name)
        let first = model.addMacro()
        let second = model.addMacro()
        XCTAssertEqual(model.macros.map(\.name), defaultNames + ["新组合动作", "新组合动作 2"])
        XCTAssertTrue(model.renameMacro(second, name: "新组合动作 3"))
        let third = model.addMacro()
        XCTAssertEqual(model.macros.map(\.name), defaultNames + ["新组合动作", "新组合动作 3", "新组合动作 2"])
        XCTAssertNotEqual(first, third)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.macros, model.macros)
    }

    func testRenameRejectsDuplicatesAndBlankNamesWithoutChangingStoredActions() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let first = model.addMacro()
        let second = model.addMacro()
        XCTAssertTrue(model.renameMacro(first, name: "  Build\n"))
        let before = model.macros
        for name in ["Build", " build\n", "BUILD", "", " \n\t "] {
            XCTAssertNotNil(model.macroNameError(name, excluding: second))
            XCTAssertFalse(model.renameMacro(second, name: name))
            XCTAssertEqual(model.macros, before)
        }
        XCTAssertNil(model.macroNameError("build", excluding: first))
        XCTAssertTrue(model.renameMacro(first, name: "build"))
        XCTAssertTrue(model.renameMacro(second, name: "编译"))
        XCTAssertFalse(model.renameMacro(first, name: " 编译 "))
        XCTAssertFalse(model.renameMacro(UUID(), name: "其他"))
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.macros, model.macros)
    }

    func testLegacyNamesAreRepairedOnceWhilePreservingIDsAndSteps() {
        let names = ["运行", " 运行 ", "运行 2", "", "\n", "Build", "build"]
        let macros = names.map { SavedMacro(name: $0) }
        SettingsStorage.save(macros, "macros", defaults: defaults)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.macros.prefix(macros.count).map(\.name), ["运行", "运行 3", "运行 2", "新组合动作", "新组合动作 2", "Build", "build 2"])
        XCTAssertEqual(model.macros.prefix(macros.count).map(\.id), macros.map(\.id))
        XCTAssertEqual(model.macros.prefix(macros.count).map(\.steps), macros.map(\.steps))
        XCTAssertEqual(SettingsStorage.load([SavedMacro].self, "macros", defaults: defaults), model.macros)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.macros, model.macros)
    }

    func testImportRepairsNamesAndKeepsButtonReferencesAcrossBackupRoundTrip() throws {
        let macros = [SavedMacro(name: "开始"), SavedMacro(name: "开始"), SavedMacro(name: " ")]
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .macro, referenceID: macros[1].id.uuidString)
        let backup = SettingsBackup(mapping: mapping, profiles: [], macros: macros, phrases: [])
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        try model.applyConfiguration(backup)
        XCTAssertEqual(model.macros.prefix(macros.count).map(\.name), ["开始", "开始 2", "新组合动作"])
        XCTAssertEqual(model.macros.prefix(macros.count).map(\.id), macros.map(\.id))
        XCTAssertEqual(model.macros.prefix(macros.count).map(\.steps), macros.map(\.steps))
        XCTAssertEqual(model.mapping[.buttonA].referenceID, macros[1].id.uuidString)
        XCTAssertEqual(model.mappingTitle(model.mapping[.buttonA]), "开始 2")
        let exported = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        try model.applyConfiguration(exported)
        XCTAssertEqual(model.macros, exported.macros)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.macros, exported.macros)
        XCTAssertEqual(restored.mapping[.buttonA].referenceID, macros[1].id.uuidString)
    }

    func testStepEditingAndDeletionKeepNamesAndReleaseDeletedName() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let first = model.addMacro()
        let second = model.addMacro()
        var step = MacroStep()
        step.mapping = ButtonMapping(action: .copy)
        step.delay = 0.8
        model.updateMacroSteps([step], for: first)
        XCTAssertEqual(model.macros.first(where: { $0.id == first })?.steps, [step])
        XCTAssertEqual(model.macros.first(where: { $0.id == first })?.name, "新组合动作")
        model.deleteMacro(second)
        XCTAssertTrue(model.renameMacro(first, name: "新组合动作 2"))
        model.updateMacroSteps([], for: UUID())
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.macros, model.macros)
    }

    func testEditorAllowsNestedCallsButRejectsDirectAndIndirectCycles() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let first = model.addMacro()
        let second = model.addMacro()
        let third = model.addMacro()
        func call(_ id: UUID) -> MacroStep {
            MacroStep(mapping: ButtonMapping(action: .macro, referenceID: id.uuidString))
        }
        XCTAssertFalse(model.canNestMacro(first, in: first))
        XCTAssertFalse(model.updateMacroSteps([call(first)], for: first))
        XCTAssertTrue(model.updateMacroSteps([call(second), call(second)], for: first))
        XCTAssertTrue(model.updateMacroSteps([call(third)], for: second))
        XCTAssertFalse(model.canNestMacro(first, in: third))
        let before = model.macros
        XCTAssertFalse(model.updateMacroSteps([call(first)], for: third))
        XCTAssertEqual(model.macros, before)
        XCTAssertTrue(model.updateMacroSteps([], for: second))
        XCTAssertTrue(model.canNestMacro(first, in: third))
        XCTAssertTrue(model.updateMacroSteps([call(first)], for: third))
    }

    func testNestedCallsSurviveBackupAndRestartAndUseUpdatedChildSteps() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let parent = model.addMacro()
        let child = model.addMacro()
        model.updateMacroSteps([MacroStep(mapping: ButtonMapping(action: .macro, referenceID: child.uuidString), delay: 1)], for: parent)
        model.updateMacroSteps([MacroStep(mapping: ButtonMapping(action: .paste), delay: 0.5)], for: child)
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        try model.applyConfiguration(backup)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let root = try XCTUnwrap(restored.macros.first(where: { $0.id == parent }))
        let plan = try MacroExecutionPlan(root, macros: restored.macros)
        XCTAssertEqual(plan.events.map(\.mapping.action), [.paste])
        XCTAssertEqual(plan.duration, 1.5)
        restored.deleteMacro(child)
        XCTAssertThrowsError(try MacroExecutionPlan(root, macros: restored.macros)) { error in
            XCTAssertEqual(error as? MacroExecutionError, .missingReference)
        }
    }
}
