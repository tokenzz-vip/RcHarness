import AppKit
import SwiftUI
import XCTest
@testable import RcHarness

final class PhrasePickerTests: XCTestCase {
    @MainActor
    func testCompactDiscKeepsSingleAndDoubleClickOutputForEveryDirection() async throws {
        _ = NSApplication.shared
        let clock = TestClock()
        let picker = PhrasePickerModel(schedule: clock.schedule)
        let phrases = PhraseAssignments.inputs.enumerated().map { index, _ in
            SavedPhrase(title: "常用语\(index)", text: "内容1-\(index)", englishText: "内容2-\(index)")
        }
        var assignments = PhraseAssignments()
        for (input, phrase) in zip(PhraseAssignments.inputs, phrases) { assignments[input] = phrase.id }
        var outputs: [String] = []
        picker.onOutput = { outputs.append($0) }
        let host = NSHostingView(rootView: PhrasePickerView(model: picker))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: PhrasePickerView.panelSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func flushUI() async {
            for _ in 0..<3 {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }
        func click(_ point: NSPoint, count: Int) throws {
            let point = NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
            let location = host.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: count, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0))
                NSApp.sendEvent(event)
            }
        }
        for (input, point): (ControllerInput, NSPoint) in [
            (.dpadUp, NSPoint(x: 148, y: 88)), (.dpadLeft, NSPoint(x: 70, y: 166)),
            (.buttonA, NSPoint(x: 148, y: 166)), (.dpadRight, NSPoint(x: 226, y: 166)),
            (.dpadDown, NSPoint(x: 148, y: 244))
        ] {
            let phrase = try XCTUnwrap(phrases.first { $0.id == assignments[input] })
            for doubleClick in [false, true] {
                picker.present(phrases: phrases, assignments: assignments)
                host.layoutSubtreeIfNeeded()
                await flushUI()
                let count = outputs.count
                try click(point, count: 1)
                await flushUI()
                if doubleClick {
                    try click(point, count: 2)
                    await flushUI()
                }
                clock.advance(RemoteGestureController.doubleTapWindow)
                XCTAssertEqual(outputs.count, count + 1, "Each key must produce exactly one output")
                XCTAssertEqual(outputs.last, doubleClick ? phrase.englishText : phrase.text, input.label)
                XCTAssertFalse(picker.isPresented)
            }
        }
        picker.present(phrases: phrases, assignments: assignments)
        await flushUI()
        try click(NSPoint(x: 272, y: 24), count: 1)
        await flushUI()
        XCTAssertFalse(picker.isPresented, "The compact close button must dismiss the panel")

        if let folder = ProcessInfo.processInfo.environment["RC_HARNESS_COMPACT_PICKER_SNAPSHOTS"] {
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let titles = ["继续执行并汇报最终结果", "检查实现和验证结果", "解释一下这部分的工作原理",
                          "修复当前发现的问题", "确认并按这个方案执行"]
            let longPhrases = titles.map { SavedPhrase(title: $0, text: "内容1") }
            var longAssignments = PhraseAssignments()
            for (input, phrase) in zip(PhraseAssignments.inputs, longPhrases) { longAssignments[input] = phrase.id }
            for name in ["long-light", "long-dark", "unassigned", "empty-content"] {
                window.appearance = NSAppearance(named: name == "long-dark" ? .darkAqua : .aqua)
                picker.present(phrases: name == "unassigned" ? [] : longPhrases, assignments: longAssignments)
                if name == "empty-content" { picker.output(longPhrases[0], language: .english) }
                await flushUI()
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
    }

    func testLegacyPhrasesKeepTheirIDAndChineseContent() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"title\":\"问候\",\"text\":\"你好\"}".utf8)
        let phrase = try JSONDecoder().decode(SavedPhrase.self, from: data)
        XCTAssertEqual(phrase.id, id)
        XCTAssertEqual(phrase.text, "你好")
        XCTAssertEqual(phrase.englishTitle, "")
        XCTAssertEqual(phrase.englishText, "")
        let bilingual = SavedPhrase(id: id, title: phrase.title, text: phrase.text,
                                    englishTitle: "Greeting", englishText: "Hello")
        XCTAssertEqual(try JSONDecoder().decode(SavedPhrase.self, from: JSONEncoder().encode(bilingual)), bilingual)
    }

    @MainActor
    func testEverySlotUsesSingleChineseAndDoubleEnglish() {
        for input in PhraseAssignments.inputs {
            let clock = TestClock()
            let picker = PhrasePickerModel(schedule: clock.schedule)
            let phrase = SavedPhrase(title: "问候", text: "你好", englishTitle: "Greeting", englishText: "Hello")
            var assignments = PhraseAssignments()
            assignments[input] = phrase.id
            var outputs: [String] = []
            picker.onOutput = { outputs.append($0) }
            picker.present(phrases: [phrase], assignments: assignments)
            XCTAssertTrue(picker.handle(input, pressed: true))
            XCTAssertTrue(picker.handle(input, pressed: false))
            XCTAssertTrue(outputs.isEmpty)
            clock.advance(RemoteGestureController.doubleTapWindow)
            XCTAssertEqual(outputs, ["你好"])
            XCTAssertFalse(picker.isPresented)
            XCTAssertFalse(picker.handle(input, pressed: true))
            XCTAssertFalse(picker.handle(input, pressed: false))

            picker.present(phrases: [phrase], assignments: assignments)
            picker.handle(input, pressed: true)
            picker.handle(input, pressed: false)
            clock.advance(0.1)
            picker.handle(input, pressed: true)
            picker.handle(input, pressed: false)
            clock.advance(1)
            XCTAssertEqual(outputs, ["你好", "Hello"])
        }
    }

    @MainActor
    func testOpeningPressRepeatsAndDismissedReleasesCannotLeakOrOutput() {
        let clock = TestClock()
        let picker = PhrasePickerModel(schedule: clock.schedule)
        let phrase = SavedPhrase(title: "问候", text: "你好", englishText: "Hello")
        var assignments = PhraseAssignments()
        assignments[.buttonA] = phrase.id
        var outputs: [String] = []
        picker.onOutput = { outputs.append($0) }
        XCTAssertFalse(picker.handle(.buttonA, pressed: true))
        picker.present(phrases: [phrase], assignments: assignments)
        XCTAssertTrue(picker.handle(.buttonA, pressed: true))
        XCTAssertTrue(picker.handle(.buttonA, pressed: false))
        clock.advance(1)
        XCTAssertTrue(outputs.isEmpty)
        picker.handle(.buttonA, pressed: true)
        picker.handle(.buttonA, pressed: true)
        picker.handle(.buttonA, pressed: false)
        picker.handle(.dpadLeft, pressed: true)
        picker.handle(.buttonB, pressed: true)
        XCTAssertFalse(picker.isPresented)
        XCTAssertTrue(picker.handle(.dpadLeft, pressed: false))
        XCTAssertTrue(picker.handle(.buttonB, pressed: false))
        clock.advance(1)
        XCTAssertTrue(outputs.isEmpty)
        XCTAssertFalse(picker.handle(.dpadLeft, pressed: true))
    }

    @MainActor
    func testCancelledResetAndMissingEnglishNeverProduceDelayedOrFallbackText() {
        let clock = TestClock()
        let picker = PhrasePickerModel(schedule: clock.schedule)
        let phrase = SavedPhrase(title: "问候", text: "你好")
        var assignments = PhraseAssignments()
        assignments[.dpadUp] = phrase.id
        assignments[.dpadDown] = UUID()
        var outputs: [String] = []
        picker.onOutput = { outputs.append($0) }
        picker.present(phrases: [phrase], assignments: assignments)
        XCTAssertNil(picker.phrases[.dpadDown])
        picker.handle(.dpadUp, pressed: true)
        picker.handle(.dpadUp, pressed: false)
        picker.cancel(.dpadUp)
        clock.advance(1)
        XCTAssertTrue(outputs.isEmpty)
        for _ in 0..<2 {
            picker.handle(.dpadUp, pressed: true)
            picker.handle(.dpadUp, pressed: false)
        }
        XCTAssertTrue(picker.isPresented)
        XCTAssertTrue(picker.message.contains("内容2为空"))
        clock.advance(1)
        XCTAssertTrue(outputs.isEmpty)
        picker.handle(.dpadUp, pressed: true)
        picker.handle(.dpadUp, pressed: false)
        picker.reset()
        clock.advance(1)
        XCTAssertTrue(outputs.isEmpty)
        XCTAssertFalse(picker.handle(.dpadUp, pressed: true))
    }

    @MainActor
    func testHiddenDismissDoesNotStealAnOrdinaryHeldReleaseAndPresentedTextIsASnapshot() {
        let clock = TestClock()
        let picker = PhrasePickerModel(schedule: clock.schedule)
        XCTAssertFalse(picker.handle(.options, pressed: true))
        picker.dismiss()
        XCTAssertFalse(picker.handle(.options, pressed: false))
        var phrase = SavedPhrase(title: "问候", text: "原始中文", englishText: "Original")
        var assignments = PhraseAssignments()
        assignments[.buttonA] = phrase.id
        var outputs: [String] = []
        picker.onOutput = { outputs.append($0) }
        picker.present(phrases: [phrase], assignments: assignments)
        phrase.text = "修改后的中文"
        assignments[.buttonA] = nil
        picker.handle(.buttonA, pressed: true)
        picker.handle(.buttonA, pressed: false)
        clock.advance(RemoteGestureController.doubleTapWindow)
        XCTAssertEqual(outputs, ["原始中文"])
    }

    @MainActor
    func testAssignmentsPersistAndBackUpIndependentlyOfMappingsAndRemoteSelection() throws {
        let suite = "PhrasePickerTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profiles = model.profiles
        let globals = model.globalButtons
        let phrase = SavedPhrase(title: "问候", text: "你好", englishTitle: "Greeting", englishText: "Hello")
        model.phrases = [phrase]
        model.phraseAssignments[.dpadUp] = phrase.id
        XCTAssertEqual(model.profiles, profiles)
        XCTAssertEqual(model.globalButtons, globals)
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertEqual(model.phraseAssignments[.dpadUp], phrase.id)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.phraseAssignments[.dpadUp], phrase.id)
        XCTAssertEqual(restored.phrases, [phrase])
        restored.phraseAssignments = PhraseAssignments()
        try restored.applyConfiguration(backup)
        XCTAssertEqual(restored.phraseAssignments[.dpadUp], phrase.id)
        XCTAssertEqual(restored.phrases.first?.englishText, "Hello")
        var legacy = backup
        legacy.phraseAssignments = nil
        try restored.applyConfiguration(legacy)
        XCTAssertTrue(restored.phraseAssignments.slots.isEmpty)
    }

    func testOpenActionRoundTripsButCannotRunAsAMacro() throws {
        let mapping = ButtonMapping(action: .openPhrases)
        XCTAssertEqual(try JSONDecoder().decode(ButtonMapping.self, from: JSONEncoder().encode(mapping)), mapping)
        let macro = SavedMacro(name: "打开", steps: [MacroStep(mapping: mapping)])
        XCTAssertThrowsError(try MacroExecutionPlan(macro, macros: [macro])) {
            XCTAssertEqual($0 as? MacroExecutionError, .unsupportedAction)
        }
    }
}
