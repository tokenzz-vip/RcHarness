import XCTest
@testable import RcHarness

@MainActor
final class DefaultPhraseTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "RcHarness.DefaultPhraseTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testNewInstallationSeedsBilingualPhrasesAndPersistsThem() {
        withDefaults { defaults in
            let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            XCTAssertEqual(model.phrases, DefaultPhrases.all)
            XCTAssertEqual(model.phrases.count, 16)
            XCTAssertEqual(Set(model.phrases.map(\.id)).count, model.phrases.count)
            for phrase in model.phrases {
                XCTAssertFalse(phrase.title.isEmpty)
                XCTAssertFalse(phrase.englishTitle.isEmpty)
                XCTAssertTrue(phrase.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
                XCTAssertFalse(phrase.englishText.isEmpty)
                XCTAssertTrue(phrase.englishText.unicodeScalars.allSatisfy(\.isASCII))
            }
            XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), model.phrases)
            let expected: [ControllerInput: String] = [
                .dpadUp: "继续执行", .dpadDown: "检查结果", .dpadLeft: "解释一下",
                .dpadRight: "修复问题", .buttonA: "确认方案",
            ]
            for (input, title) in expected {
                XCTAssertEqual(model.phrases.first { $0.id == model.phraseAssignments[input] }?.title, title)
            }
            XCTAssertEqual(model.phraseAssignments.slots.count, expected.count)
            XCTAssertEqual(SettingsStorage.load(PhraseAssignments.self, SettingsKeys.Stored.phraseAssignments, defaults: defaults), model.phraseAssignments)
            XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).phrases, model.phrases)
        }
    }

    func testPreviouslyInstalledPresetsGetBindingsOnceAndRespectLaterChanges() {
        withDefaults { defaults in
            SettingsStorage.save(DefaultPhrases.all, SettingsKeys.Stored.phrases, defaults: defaults)
            SettingsStorage.save(PhraseAssignments(), SettingsKeys.Stored.phraseAssignments, defaults: defaults)
            defaults.set(true, forKey: SettingsKeys.aiPhrasePresetsInitialized)
            let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            XCTAssertEqual(model.phraseAssignments, DefaultPhrases.assignments(for: model.phrases))
            XCTAssertEqual(model.phraseAssignments.slots.count, 5)
            model.phraseAssignments[.dpadUp] = model.phrases[6].id
            model.phraseAssignments[.dpadDown] = nil
            let expected = model.phraseAssignments
            model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
            XCTAssertEqual(model.phraseAssignments, expected)
            XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).phraseAssignments, expected)
            model.phraseAssignments = PhraseAssignments()
            XCTAssertTrue(RemoteDashboardModel(mapping: .defaults, defaults: defaults).phraseAssignments.slots.isEmpty)
        }
    }

    func testRecommendationsReuseIdenticalSavedContentAndSkipDeletedPresets() {
        var phrases = DefaultPhrases.all
        let original = phrases.removeFirst()
        let replacement = SavedPhrase(title: "我的继续指令", text: original.text, englishText: original.englishText)
        phrases.append(replacement)
        phrases.removeAll { $0.title == "修复问题" }
        let assignments = DefaultPhrases.assignments(for: phrases)
        XCTAssertEqual(assignments[.dpadUp], replacement.id)
        XCTAssertNil(assignments[.dpadRight])
        XCTAssertEqual(assignments.slots.count, 4)
    }

    func testRecommendedBindingsOutputChineseOnSinglePressAndEnglishOnDoublePress() {
        withDefaults { defaults in
            let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            for input in PhraseAssignments.inputs {
                let phrase = model.phrases.first { $0.id == model.phraseAssignments[input] }!
                for doublePress in [false, true] {
                    let clock = TestClock()
                    let picker = PhrasePickerModel(schedule: clock.schedule)
                    var outputs: [String] = []
                    picker.onOutput = { outputs.append($0) }
                    picker.present(phrases: model.phrases, assignments: model.phraseAssignments)
                    for _ in 0..<(doublePress ? 2 : 1) {
                        picker.handle(input, pressed: true)
                        picker.handle(input, pressed: false)
                    }
                    clock.advance(RemoteGestureController.doubleTapWindow)
                    XCTAssertEqual(outputs, [doublePress ? phrase.englishText : phrase.text])
                }
            }
        }
    }

    func testUpgradePreservesCustomContentBindingsAndOrderWithoutDuplicates() {
        withDefaults { defaults in
            let custom = SavedPhrase(title: DefaultPhrases.all[0].title, text: "保留我自己的内容", englishText: "Keep my own text")
            let sameContent = SavedPhrase(title: "已有翻译", text: DefaultPhrases.all[1].text,
                                          englishText: DefaultPhrases.all[1].englishText)
            var editedPreset = DefaultPhrases.all[2]
            editedPreset.title = "我的计划"
            editedPreset.text = "我修改过的计划内容"
            let existing = [custom, sameContent, editedPreset]
            var assignments = PhraseAssignments()
            assignments[.dpadUp] = custom.id
            assignments[.buttonA] = editedPreset.id
            SettingsStorage.save(existing, SettingsKeys.Stored.phrases, defaults: defaults)
            SettingsStorage.save(assignments, SettingsKeys.Stored.phraseAssignments, defaults: defaults)

            let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            XCTAssertEqual(Array(model.phrases.prefix(existing.count)), existing)
            XCTAssertEqual(model.phraseAssignments, assignments)
            XCTAssertEqual(model.phrases.count, existing.count + DefaultPhrases.all.count - 2)
            XCTAssertFalse(model.phrases.contains { $0.id == DefaultPhrases.all[1].id })
            XCTAssertEqual(model.phrases.first { $0.id == DefaultPhrases.all[0].id }?.title, custom.title + " 2")
            XCTAssertEqual(Set(model.phrases.map(\.id)).count, model.phrases.count)
            XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).phrases, model.phrases)
        }
    }

    func testEditsDeletionsAndEmptyImportsSurviveRestartAndRemoteSwitch() throws {
        try withDefaults { defaults in
            let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            var edited = model.phrases[0]
            edited.text = "修改后的中文"
            edited.englishText = "Edited English"
            model.phrases = [edited]
            model.phraseAssignments[.dpadLeft] = edited.id
            model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
            XCTAssertEqual(model.phrases, [edited])

            let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            XCTAssertEqual(restored.phrases, [edited])
            XCTAssertEqual(restored.phraseAssignments[.dpadLeft], edited.id)
            let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(restored.configurationBackup()))
            try withDefaults { importDefaults in
                let imported = RemoteDashboardModel(mapping: .defaults, defaults: importDefaults)
                try imported.applyConfiguration(backup)
                XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: importDefaults).phrases, [edited])
                var empty = backup
                empty.phrases = []
                empty.phraseAssignments = PhraseAssignments()
                try imported.applyConfiguration(empty)
                let emptyRestored = RemoteDashboardModel(mapping: .defaults, defaults: importDefaults)
                XCTAssertTrue(emptyRestored.phrases.isEmpty)
                XCTAssertTrue(emptyRestored.phraseAssignments.slots.isEmpty)
            }
            model.phrases = []
            model.flushPendingWrites()
            XCTAssertTrue(RemoteDashboardModel(mapping: .defaults, defaults: defaults).phrases.isEmpty)
        }
    }
}
