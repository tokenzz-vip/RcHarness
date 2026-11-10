import XCTest
@testable import RcHarness

final class PhraseOrderingTests: XCTestCase {
    @MainActor
    private func withModel(_ body: (RemoteDashboardModel) throws -> Void) rethrows {
        let suite = "PhraseOrderingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(RemoteDashboardModel(mapping: .defaults, defaults: defaults))
    }

    @MainActor
    func testAssignedPhrasesAppearInUpDownLeftRightConfirmOrder() {
        withModel { model in
            let entries = (0..<7).map { SavedPhrase(title: "条目\($0)", text: "内容\($0)") }
            model.phrases = entries
            model.phraseAssignments[.buttonA] = entries[0].id
            model.phraseAssignments[.dpadRight] = entries[2].id
            model.phraseAssignments[.dpadLeft] = entries[4].id
            model.phraseAssignments[.dpadDown] = entries[3].id
            model.phraseAssignments[.dpadUp] = entries[6].id
            XCTAssertEqual(model.orderedPhrases.map(\.id), [6, 3, 4, 2, 0, 1, 5].map { entries[$0].id })
            XCTAssertEqual(model.phrases, entries)

            // The earliest assigned position wins; deleted references do not create rows.
            model.phraseAssignments[.dpadDown] = entries[6].id
            model.phraseAssignments[.dpadRight] = UUID()
            XCTAssertEqual(model.orderedPhrases.map(\.id), [6, 4, 0, 1, 2, 3, 5].map { entries[$0].id })
            XCTAssertEqual(model.orderedPhrases.count, entries.count)
        }
    }

    @MainActor
    func testDraggingUnboundRowsPreservesBoundSlotsAndRestoresTheirManualPositionOnUnbind() {
        withModel { model in
            let entries = (0..<5).map { SavedPhrase(title: "条目\($0)", text: "内容\($0)") }
            model.phrases = entries
            model.phraseAssignments[.dpadUp] = entries[1].id
            model.phraseAssignments[.buttonA] = entries[3].id
            let assignments = model.phraseAssignments
            let profiles = model.profiles
            let globals = model.globalButtons
            model.moveUnboundPhrases(fromOffsets: IndexSet(integer: 0), toOffset: 3)
            XCTAssertEqual(model.phrases.map(\.id), [2, 1, 4, 3, 0].map { entries[$0].id })
            XCTAssertEqual(model.orderedPhrases.map(\.id), [1, 3, 2, 4, 0].map { entries[$0].id })
            XCTAssertEqual(model.phraseAssignments, assignments)
            XCTAssertEqual(model.profiles, profiles)
            XCTAssertEqual(model.globalButtons, globals)
            XCTAssertEqual(model.phrases.first(where: { $0.id == entries[0].id })?.text, entries[0].text)
            model.moveUnboundPhrases(fromOffsets: IndexSet(integer: 2), toOffset: 0)
            XCTAssertEqual(model.phrases, entries)
            model.phraseAssignments[.dpadUp] = nil
            model.phraseAssignments[.buttonA] = nil
            XCTAssertEqual(model.orderedPhrases, entries)
        }
    }

    @MainActor
    func testMoveSurvivesRestartBackupImportAndRemoteSwitch() throws {
        try withModel { model in
            let entries = (0..<4).map { SavedPhrase(title: "条目\($0)", text: "内容\($0)") }
            model.phrases = entries
            model.phraseAssignments[.dpadDown] = entries[2].id
            model.moveUnboundPhrases(fromOffsets: IndexSet(integer: 2), toOffset: 0)
            let expected = model.orderedPhrases
            let manual = model.phrases
            let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
            model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
            XCTAssertEqual(model.orderedPhrases, expected)
            let restored = RemoteDashboardModel(mapping: .defaults, defaults: model.defaults)
            XCTAssertEqual(restored.orderedPhrases, expected)
            XCTAssertEqual(restored.phrases, manual)
            restored.phrases = []
            restored.phraseAssignments = PhraseAssignments()
            try restored.applyConfiguration(backup)
            XCTAssertEqual(restored.orderedPhrases, expected)
            XCTAssertEqual(restored.phrases, manual)
        }
    }

    @MainActor
    func testRebindingImmediatelyReordersWithoutChangingManualOrder() {
        withModel { model in
            let entries = (0..<4).map { SavedPhrase(title: "条目\($0)", text: "内容\($0)") }
            model.phrases = entries
            model.phraseAssignments[.buttonA] = entries[3].id
            XCTAssertEqual(model.orderedPhrases.map(\.id), [3, 0, 1, 2].map { entries[$0].id })
            model.phraseAssignments[.dpadUp] = entries[2].id
            XCTAssertEqual(model.orderedPhrases.map(\.id), [2, 3, 0, 1].map { entries[$0].id })
            model.phraseAssignments[.buttonA] = entries[0].id
            XCTAssertEqual(model.orderedPhrases.map(\.id), [2, 0, 1, 3].map { entries[$0].id })
            model.phraseAssignments = PhraseAssignments()
            XCTAssertEqual(model.orderedPhrases, entries)
        }
    }
}
