import SwiftUI
import XCTest
@testable import RcHarness

@MainActor
final class MacroReferencePickerTests: XCTestCase {
    func testFilteringPreservesTheBindingAndKeepsItsCurrentSelectionAvailable() throws {
        let suite = "RcHarness.MacroReferencePickerTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let selected = try XCTUnwrap(model.macros.first { $0.tagIDs == ["codex"] })
        let sharedID = model.addMacro(tagIDs: ["codex", "cursor"])
        var referenceID: String? = selected.id.uuidString
        var tagIDs: Set<String> = []
        var referenceWrites = 0
        let picker = MacroReferencePicker(referenceID: Binding(get: { referenceID }, set: {
            referenceWrites += 1
            referenceID = $0
        }), tagIDs: Binding(get: { tagIDs }, set: { tagIDs = $0 }), model: model)
        let before = model.configurationBackup()
        XCTAssertEqual(picker.matchingMacros, model.macros)
        XCTAssertNil(picker.selectedOutsideFilter)

        picker.tagIDs = ["cursor"]
        XCTAssertTrue(picker.matchingMacros.contains { $0.id == sharedID })
        XCTAssertFalse(picker.matchingMacros.contains { $0.id == selected.id })
        XCTAssertEqual(picker.selectedOutsideFilter, selected)
        XCTAssertEqual(picker.referenceID, selected.id.uuidString)

        picker.tagIDs = ["codex"]
        XCTAssertTrue(picker.matchingMacros.contains { $0.id == sharedID })
        XCTAssertTrue(picker.matchingMacros.contains { $0.id == selected.id })
        XCTAssertNil(picker.selectedOutsideFilter)
        picker.tagIDs = ["codex", "cursor"]
        XCTAssertTrue(picker.matchingMacros.contains { $0.id == selected.id })
        XCTAssertEqual(picker.matchingMacros.filter { $0.id == sharedID }.count, 1)
        XCTAssertTrue(picker.matchingMacros.allSatisfy { !$0.tagIDs.isDisjoint(with: ["codex", "cursor"]) })
        picker.tagIDs = []
        XCTAssertEqual(picker.matchingMacros, model.macros)
        XCTAssertEqual(referenceWrites, 0, "Changing a filter must never write the selected action")
        XCTAssertEqual(model.configurationBackup(), before)
    }

    func testEmptyFiltersAndDeletedReferencesPreserveSelectionWithoutPickingAnotherAction() throws {
        let suite = "RcHarness.MacroReferencePickerTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let selected = try XCTUnwrap(model.macros.first)
        var referenceID: String? = selected.id.uuidString
        var tagIDs: Set<String> = [MacroTag.general.id]
        let picker = MacroReferencePicker(referenceID: Binding(get: { referenceID }, set: { referenceID = $0 }),
                                          tagIDs: Binding(get: { tagIDs }, set: { tagIDs = $0 }), model: model)
        XCTAssertTrue(picker.matchingMacros.isEmpty)
        XCTAssertEqual(picker.selectedOutsideFilter, selected)
        XCTAssertEqual(referenceID, selected.id.uuidString)
        model.deleteMacro(selected.id)
        XCTAssertNil(picker.selectedMacro)
        XCTAssertNil(picker.selectedOutsideFilter)
        XCTAssertEqual(referenceID, selected.id.uuidString)
        picker.tagIDs = ["claude"]
        XCTAssertFalse(picker.matchingMacros.isEmpty)
        XCTAssertEqual(referenceID, selected.id.uuidString)
        picker.referenceID = ""
        XCTAssertNil(picker.selectedMacro)
        XCTAssertEqual(referenceID, "")
    }
}
