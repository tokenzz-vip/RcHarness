import AppKit
import XCTest
@testable import RcHarness

private final class AutosaveRecordingDefaults: UserDefaults {
    var writes: [String] = []
    override func set(_ value: Any?, forKey key: String) {
        writes.append(key)
        super.set(value, forKey: key)
    }
}

@MainActor
final class SettingsAutosaveTests: XCTestCase {
    private var defaults: AutosaveRecordingDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "RcHarness.AutosaveTests." + UUID().uuidString
        defaults = AutosaveRecordingDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testConsecutivePhraseEditsUpdateMemoryWithoutWritingEachKeystroke() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let original = model.phrases
        defaults.writes = []
        for index in 0..<20 { model.phrases[0].text = "正文 \(index)" }
        XCTAssertEqual(model.phrases[0].text, "正文 19")
        XCTAssertTrue(defaults.writes.isEmpty)
        XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), original)
        model.flushPendingWrites()
        XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), model.phrases)
        XCTAssertEqual(defaults.writes.count, 1)
    }

    func testTrailingDebouncePersistsLatestStateAfterEditingPauses() {
        let clock = TestClock()
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults, settingsSchedule: clock.schedule)
        defaults.writes = []
        model.phrases[0].title = "第一次修改"
        clock.advance(0.3)
        XCTAssertTrue(defaults.writes.isEmpty)
        model.phrases[0].text = "最新正文"
        clock.advance(0.3)
        XCTAssertTrue(defaults.writes.isEmpty, "The first timer must not save mid-edit")
        clock.advance(0.11)
        XCTAssertEqual(defaults.writes.count, 1)
        XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), model.phrases)
        clock.advance(1)
        model.flushPendingWrites()
        XCTAssertEqual(defaults.writes.count, 1, "Flush is idempotent after the timer fires")
    }

    func testPhraseAndMacroEditsShareOneSnapshotCommitAndRetainRecovery() throws {
        let clock = TestClock()
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults, settingsSchedule: clock.schedule)
        try model.applyConfiguration(model.configurationBackup())
        let recovery = SettingsStorage.configurationRecoveryData(defaults: defaults)
        let macroID = model.macros[0].id
        defaults.writes = []
        model.phrases[0].text = "编辑中的正文"
        var step = MacroStep()
        step.mapping = ButtonMapping(action: .copy)
        XCTAssertTrue(model.updateMacroSteps([step], for: macroID))
        step.delay = 0.7
        XCTAssertTrue(model.updateMacroSteps([step], for: macroID))
        XCTAssertTrue(defaults.writes.isEmpty)
        XCTAssertEqual(model.macros[0].steps[0].delay, 0.7)
        clock.advance(0.41)
        XCTAssertEqual(defaults.writes, ["RcHarness." + SettingsKeys.Stored.configurationSnapshot])
        XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), model.phrases)
        XCTAssertEqual(SettingsStorage.load([SavedMacro].self, SettingsKeys.Stored.macros, defaults: defaults), model.macros)
        XCTAssertEqual(SettingsStorage.configurationRecoveryData(defaults: defaults), recovery)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.phrases, model.phrases)
        XCTAssertEqual(restored.macros, model.macros)
    }

    func testInitializationAndRemoteNormalizationCommitEachCollectionOnlyOnce() throws {
        _ = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let configurationKeys = [SettingsKeys.Stored.profiles, SettingsKeys.Stored.harnesses,
            SettingsKeys.Stored.macros, SettingsKeys.Stored.phrases, SettingsKeys.Stored.phraseAssignments,
            SettingsKeys.Stored.globalButtons, SettingsKeys.Stored.remoteKeyConfigurations]
        for key in configurationKeys {
            XCTAssertEqual(defaults.writes.filter { $0 == "RcHarness." + key }.count, 1, key)
        }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        try model.applyConfiguration(model.configurationBackup())
        defaults.writes = []
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(defaults.writes.filter { $0 == "RcHarness." + SettingsKeys.Stored.configurationSnapshot }.count, 1)
        defaults.writes = []
        restored.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertEqual(defaults.writes.filter { $0 == "RcHarness." + SettingsKeys.Stored.configurationSnapshot }.count, 1)
        let restarted = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restarted.profiles, restored.profiles)
        XCTAssertEqual(restarted.remoteProfile, restored.remoteProfile)
    }

    func testImportSupersedesPendingEditsAndRecoveryIncludesThem() throws {
        // Invoke even canceled callbacks to check that obsolete producers cannot
        // overwrite a successful replacement or a newer pending edit.
        var callbacks: [() -> Void] = []
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults, settingsSchedule: { _, callback in
            callbacks.append(callback)
            return DispatchWorkItem(block: callback)
        })
        model.phrases[0].text = "导入前尚未落盘的正文"
        let before = model.configurationBackup()
        var incoming = before
        incoming.phrases = [SavedPhrase(title: "导入后", text: "替换正文")]
        defaults.writes = []
        try model.applyConfiguration(incoming)
        XCTAssertEqual(defaults.writes, ["RcHarness." + SettingsKeys.Stored.configurationSnapshot])
        XCTAssertEqual(SettingsStorage.configurationRecovery(defaults: defaults)?.backup, before)
        model.phrases[0].text = "导入后的新编辑"
        defaults.writes = []
        callbacks.dropLast().forEach { $0() }
        XCTAssertTrue(defaults.writes.isEmpty)
        callbacks.last?()
        XCTAssertEqual(defaults.writes.count, 1)
        XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), model.phrases)
    }

    func testRejectedImportLeavesPendingEditsScheduled() {
        let clock = TestClock()
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults, settingsSchedule: clock.schedule)
        model.phrases[0].text = "需要保存的编辑"
        var invalid = model.configurationBackup()
        invalid.version = 999
        XCTAssertThrowsError(try model.applyConfiguration(invalid))
        clock.advance(0.41)
        XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), model.phrases)
    }

    func testDeletionAndUndoCannotBeOverwrittenByEarlierEdits() throws {
        let clock = TestClock()
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults, settingsSchedule: clock.schedule)
        model.phrases.append(SavedPhrase(title: "临时常用语", text: "待删除"))
        let phrase = try XCTUnwrap(model.phrases.last)
        model.deleteConfigurationObject(.phrase(phrase.id))
        clock.advance(1)
        XCTAssertFalse(model.phrases.contains { $0.id == phrase.id })
        XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), model.phrases)
        model.undoDeletion()
        clock.advance(1)
        XCTAssertTrue(model.phrases.contains { $0.id == phrase.id })
        XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), model.phrases)
    }

    func testFocusLossWindowCloseAndPageChangeFlushWithoutWaiting() {
        let clock = TestClock()
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults, settingsSchedule: clock.schedule)
        let controller = DashboardWindowController(model: model)
        controller.window?.contentView = NSView()
        let field = NSTextField()
        let editor = NSTextView()
        controller.window?.contentView?.addSubview(field)
        controller.window?.contentView?.addSubview(editor)
        for (name, view) in [(NSControl.textDidEndEditingNotification, field as NSView),
                             (NSText.didEndEditingNotification, editor as NSView)] {
            model.phrases[0].text += "失焦"
            defaults.writes = []
            NotificationCenter.default.post(name: name, object: NSView())
            XCTAssertTrue(defaults.writes.isEmpty, "Other windows must not flush this editor")
            NotificationCenter.default.post(name: name, object: view)
            XCTAssertEqual(defaults.writes.count, 1)
            XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), model.phrases)
        }
        model.phrases[0].title = "切换页面"
        model.page = .statistics
        XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), model.phrases)
        model.phrases[0].title = "窗口失焦"
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), model.phrases)
        model.phrases[0].title = "关闭窗口"
        controller.window?.close()
        XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), model.phrases)
        defaults.writes = []
        clock.advance(1)
        XCTAssertTrue(defaults.writes.isEmpty)
    }

    func testBatchEncodingFailureRetainsAllPreviousValues() throws {
        enum Failure: Error { case invalid }
        SettingsStorage.save(["old"], SettingsKeys.Stored.phrases, defaults: defaults)
        defaults.writes = []
        XCTAssertThrowsError(try SettingsStorage.saveValues([
            SettingsKeys.Stored.phrases: { try JSONEncoder().encode(["new"]) },
            SettingsKeys.Stored.macros: { throw Failure.invalid },
        ], defaults: defaults))
        XCTAssertTrue(defaults.writes.isEmpty)
        XCTAssertEqual(SettingsStorage.load([String].self, SettingsKeys.Stored.phrases, defaults: defaults), ["old"])
    }

    func testRealTextEditorBindingFlushesWhenNativeFocusMovesAway() async throws {
        let clock = TestClock()
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults, settingsSchedule: clock.schedule)
        model.phrases = [SavedPhrase(title: "测试失焦", text: "原正文")]
        model.page = .phrases
        let controller = DashboardWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<8 { await Task.yield() }
        func editors(in view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { editors(in: $0) }
        }
        let editor = try XCTUnwrap(editors(in: host).first { $0.string == "原正文" })
        XCTAssertTrue(window.makeFirstResponder(editor))
        defaults.writes = []
        editor.insertText("已修改", replacementRange: NSRange(location: 0, length: 3))
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(model.phrases[0].text, "已修改")
        XCTAssertTrue(defaults.writes.isEmpty)
        XCTAssertTrue(window.makeFirstResponder(nil))
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults)?.first?.text, "已修改")
        XCTAssertEqual(defaults.writes.count, 1)

        func fields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        let title = try XCTUnwrap(fields(in: host).first { $0.isEditable && $0.stringValue == "测试失焦" })
        XCTAssertTrue(window.makeFirstResponder(title))
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        defaults.writes = []
        fieldEditor.insertText("新标题", replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(model.phrases[0].title, "新标题")
        XCTAssertTrue(defaults.writes.isEmpty)
        XCTAssertTrue(window.makeFirstResponder(editor))
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults)?.first?.title, "新标题")
        XCTAssertEqual(defaults.writes.count, 1)
    }

    /// Opt-in measurement of the real model setter, isolated from personal settings.
    /// Include the post-import snapshot path because it also encodes the enclosing snapshot.
    func testLargeConfigurationEditingBenchmark() throws {
        guard let output = ProcessInfo.processInfo.environment["RC_HARNESS_AUTOSAVE_BENCHMARK"] else {
            throw XCTSkip("Set RC_HARNESS_AUTOSAVE_BENCHMARK to a result JSON path")
        }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let phrases = (0..<1_000).map { SavedPhrase(title: "常用语 \($0)", text: String(repeating: "a", count: 8_192)) }
        var results: [[String: Double]] = []
        for imported in [false, true] {
            if imported {
                var backup = model.configurationBackup()
                backup.phrases = phrases
                try model.applyConfiguration(backup)
            } else {
                model.phrases = phrases
                model.flushPendingWrites()
            }
            defaults.writes = []
            var samples: [Double] = []
            for index in 0..<40 {
                let start = ProcessInfo.processInfo.systemUptime
                model.phrases[0].text += "\(index % 10)"
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            }
            samples.sort()
            let editWrites = defaults.writes.count
            let flushStart = ProcessInfo.processInfo.systemUptime
            model.flushPendingWrites()
            let flushMS = (ProcessInfo.processInfo.systemUptime - flushStart) * 1_000
            results.append(["importedSnapshot": imported ? 1 : 0, "phraseCount": 1_000,
                "bodyBytes": 8_192, "edits": 40, "medianMS": samples[20], "p95MS": samples[37],
                "maxMS": samples[39], "editWrites": Double(editWrites),
                "flushMS": flushMS, "totalWrites": Double(defaults.writes.count)])
            XCTAssertEqual(SettingsStorage.load([SavedPhrase].self, SettingsKeys.Stored.phrases, defaults: defaults), model.phrases)
        }
        try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: output))
    }
}
