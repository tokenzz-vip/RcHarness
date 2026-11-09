import XCTest
@testable import RcHarness

final class MacroExecutionTests: XCTestCase {
    func testPhraseTextIsResolvedBeforeSchedulingAndMissingReferencesRejectThePlan() throws {
        var phrase = SavedPhrase(title: "问候", text: "启动时的文本")
        let macro = SavedMacro(name: "稍后输入", steps: [MacroStep(mapping: ButtonMapping(action: .phrase, referenceID: phrase.id.uuidString))])
        let plan = try MacroExecutionPlan(macro, macros: [macro], phrases: [phrase])
        phrase.text = "之后修改的文本"
        XCTAssertEqual(plan.events.first?.text, "启动时的文本")
        XCTAssertThrowsError(try MacroExecutionPlan(macro, macros: [macro], phrases: [])) { error in
            XCTAssertEqual(error as? MacroExecutionError, .missingReference)
        }
    }

    func testModeSwitchInImportedMacroFailsBeforeAnyStepsRun() {
        let macro = SavedMacro(name: "旧组合动作", steps: [step(.copy), step(.switchToNativeMode)])
        XCTAssertThrowsError(try MacroExecutionPlan(macro, macros: [macro])) { error in
            XCTAssertEqual(error as? MacroExecutionError, .unsupportedAction)
        }
    }

    private func step(_ action: RemoteAction, delay: Double = 0, reference: UUID? = nil) -> MacroStep {
        MacroStep(mapping: ButtonMapping(action: action, referenceID: reference?.uuidString), delay: delay)
    }

    func testNestedCallsRunInOrderAndParentWaitStartsAfterChildCompletes() throws {
        let leaf = SavedMacro(name: "叶子", steps: [step(.copy, delay: 0.25), step(.paste, delay: 0.5)])
        let middle = SavedMacro(name: "中间", steps: [step(.enter, delay: 1), step(.macro, delay: 2, reference: leaf.id), step(.escape, delay: 3)])
        let root = SavedMacro(name: "父级", steps: [step(.macro, delay: 4, reference: middle.id), step(.screenshot)])
        let plan = try MacroExecutionPlan(root, macros: [root, middle, leaf])
        XCTAssertEqual(plan.events.map(\.mapping.action), [.enter, .copy, .paste, .escape, .screenshot])
        XCTAssertEqual(plan.events.map(\.offset), [0, 1, 1.25, 3.75, 10.75])
        XCTAssertEqual(plan.duration, 10.75)
    }

    func testRepeatedCallsToSameChildAreAllowedAndKeepTheirWaits() throws {
        let child = SavedMacro(name: "子级", steps: [step(.copy, delay: 1)])
        let root = SavedMacro(name: "父级", steps: [step(.macro, delay: 2, reference: child.id), step(.macro, delay: 3, reference: child.id), step(.paste, delay: 4)])
        let plan = try MacroExecutionPlan(root, macros: [root, child])
        XCTAssertEqual(plan.events.map(\.mapping.action), [.copy, .copy, .paste])
        XCTAssertEqual(plan.events.map(\.offset), [0, 3, 7])
        XCTAssertEqual(plan.duration, 11)
    }

    func testDirectAndIndirectCyclesRejectWholePlan() {
        var first = SavedMacro(name: "一")
        first.steps = [step(.copy), step(.macro, reference: first.id)]
        XCTAssertThrowsError(try MacroExecutionPlan(first, macros: [first])) { error in
            XCTAssertEqual(error as? MacroExecutionError, .circularReference("一"))
        }
        let second = SavedMacro(name: "二", steps: [step(.macro, reference: first.id)])
        first.steps = [step(.copy), step(.macro, reference: second.id)]
        XCTAssertThrowsError(try MacroExecutionPlan(first, macros: [first, second])) { error in
            XCTAssertEqual(error as? MacroExecutionError, .circularReference("一"))
        }
    }

    func testUnsetInvalidOrDeletedReferencesRejectWholePlan() {
        for reference in [nil, "", "invalid", UUID().uuidString] as [String?] {
            let root = SavedMacro(name: "父级", steps: [step(.copy), MacroStep(mapping: ButtonMapping(action: .macro, referenceID: reference))])
            XCTAssertThrowsError(try MacroExecutionPlan(root, macros: [root])) { error in
                XCTAssertEqual(error as? MacroExecutionError, .missingReference)
            }
        }
    }

    func testTotalStepBudgetIncludesNestedCallsAndRejectsExpansionWithoutTruncating() throws {
        let child = SavedMacro(name: "子级", steps: Array(repeating: step(.copy), count: 49))
        var root = SavedMacro(name: "父级", steps: Array(repeating: step(.macro, reference: child.id), count: 2))
        let plan = try MacroExecutionPlan(root, macros: [root, child])
        XCTAssertEqual(plan.events.count, 98)
        root.steps.append(step(.paste))
        XCTAssertThrowsError(try MacroExecutionPlan(root, macros: [root, child])) { error in
            XCTAssertEqual(error as? MacroExecutionError, .tooManySteps)
        }
        let flat = SavedMacro(name: "平铺", steps: Array(repeating: step(.copy), count: 101))
        XCTAssertThrowsError(try MacroExecutionPlan(flat, macros: [flat]))
    }

    func testDeepNestingIsBoundedEvenWhenThereAreNoLeafActions() {
        var macros = [SavedMacro(name: "空", steps: [])]
        for index in 0..<101 {
            macros.append(SavedMacro(name: "层 \(index)", steps: [step(.macro, reference: macros.last!.id)]))
        }
        XCTAssertThrowsError(try MacroExecutionPlan(macros.last!, macros: macros)) { error in
            XCTAssertEqual(error as? MacroExecutionError, .tooManySteps)
        }
    }

    func testEmptyChildWaitsAndInvalidDelaysKeepFiniteOffsets() throws {
        let empty = SavedMacro(name: "空", steps: [])
        let root = SavedMacro(name: "父级", steps: [
            step(.macro, delay: 2, reference: empty.id),
            step(.copy, delay: .nan), step(.paste, delay: .infinity),
            step(.enter, delay: -3), step(.escape, delay: 20),
            step(.screenshot)
        ])
        let plan = try MacroExecutionPlan(root, macros: [root, empty])
        XCTAssertEqual(plan.events.map(\.offset), [2, 2, 2, 2, 12])
        XCTAssertFalse(plan.events.contains { $0.mapping.action == .macro || $0.mapping.action == .switchToNativeMode })
        XCTAssertEqual(plan.duration, 12)
    }
}
