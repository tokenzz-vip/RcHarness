import AppKit
import XCTest
@testable import RcHarness

@MainActor
final class SettingsTests: XCTestCase {
    func testThemeModeDefaultsToSystemAndRejectsUnknownSavedValues() {
        let suite = "RcHarness.ThemeTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).themeMode, .system)
        defaults.set("unknown", forKey: SettingsKeys.themeMode)
        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).themeMode, .system)
        XCTAssertNil(AppThemeMode.system.appearance)
        XCTAssertEqual(AppThemeMode.light.appearance?.name, .aqua)
        XCTAssertEqual(AppThemeMode.dark.appearance?.name, .darkAqua)
    }

    func testThemeModeNotifiesTheAppAndPersistsAcrossLaunches() {
        let suite = "RcHarness.ThemeTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        var appliedModes: [AppThemeMode] = []
        model.onThemeModeChange = { appliedModes.append($0) }

        for mode in [AppThemeMode.light, .dark, .system] {
            model.themeMode = mode
            XCTAssertEqual(appliedModes.last, mode)
            XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).themeMode, mode)
        }
        XCTAssertEqual(appliedModes, [.light, .dark, .system])
    }

    @MainActor
    func testFreshSettingsOpenTheMainPanelAtLaunch() {
        let suite = "RcHarness.LaunchTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)

        XCTAssertTrue(model.openAtLaunch)
    }

    @MainActor
    func testClosingTheDashboardNotifiesTheWindowController() {
        let suite = "RcHarness.WindowTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = DashboardWindowController(model: RemoteDashboardModel(mapping: .defaults, defaults: defaults))
        var didClose = false
        controller.onWindowClose = { didClose = true }
        controller.window?.close()

        XCTAssertTrue(didClose)
    }

    @MainActor
    func testGainClampsWithoutRecursivePublishedUpdates() {
        let suite = "RcHarness.GainTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.gain = 12
        XCTAssertEqual(model.gain, 12)
        model.gain = 99
        XCTAssertEqual(model.gain, 24)
        model.gain = .nan
        XCTAssertEqual(model.gain, 0)
        XCTAssertEqual(defaults.double(forKey: "RcHarness.gain"), 0)
    }

    func testUnreadableSettingsArePreservedBeforeFallbackIsSaved() {
        let suite = "RcHarness.StorageTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("invalid settings".utf8)
        defaults.set(original, forKey: "RcHarness.profiles")
        XCTAssertNil(SettingsStorage.load([SavedKeyProfile].self, "profiles", defaults: defaults))
        XCTAssertNil(RemoteMapping.legacy(profileID: "remote", defaults: defaults))
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.profiles.first?.id, SavedKeyProfile.defaultID)
        XCTAssertEqual(model.profiles.map(\.name), ["默认方案"] + HarnessConfiguration.defaults.map { $0.name + " 按键方案" })
        XCTAssertEqual(defaults.data(forKey: "RcHarness.recovery.profiles"), original)
        XCTAssertNotEqual(defaults.data(forKey: "RcHarness.profiles"), original)
    }

    @MainActor
    func testDefaultProfileIsTheOnlyCopyOfTheDefaultMapping() {
        let suite = "RcHarness.StorageTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacy = RemoteMapping.defaults
        legacy[.buttonA] = ButtonMapping(action: .copy)
        SettingsStorage.save(legacy, "mappings.v2.xiaomi-rc003-ms", defaults: defaults)
        let first = RemoteDashboardModel(mapping: RemoteMapping.legacy(profileID: "xiaomi-rc003-ms", defaults: defaults)!, defaults: defaults)
        XCTAssertEqual(first.mapping[.buttonA].action, .copy)
        first.update(ButtonMapping(action: .paste), for: .buttonA, trigger: .single)
        XCTAssertNil(defaults.data(forKey: "RcHarness.baseMapping"))
        XCTAssertEqual(SettingsStorage.load(RemoteMapping.self, "mappings.v2.xiaomi-rc003-ms", defaults: defaults), legacy)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.mapping[.buttonA].action, .paste)
        XCTAssertEqual(restored.configurationBackup().mapping[.buttonA].action, .paste)
    }

    @MainActor
    func testUsageIsSavedLazilyAndFlushedOnDemand() {
        let suite = "RcHarness.StorageTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for _ in 0..<5 {
            model.setInput(.buttonA, pressed: true)
            model.setInput(.buttonA, pressed: false)
        }
        XCTAssertEqual(model.usageStore.usage.days.last?.presses["buttonA"], 5)
        XCTAssertNil(defaults.data(forKey: "RcHarness.usage"))
        model.flushPendingWrites()
        XCTAssertEqual(SettingsStorage.load(LocalUsage.self, "usage", defaults: defaults)?.days.last?.presses["buttonA"], 5)
    }

    @MainActor
    func testUsageCanBeClearedAndPersistsImmediately() {
        let suite = "RcHarness.StorageTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults)
        store.record(.buttonA)
        store.recordVoice(seconds: 12)

        store.clear()
        store.flush()

        XCTAssertTrue(store.usage.days.isEmpty)
        XCTAssertTrue(store.usage.sessions.isEmpty)
        let saved = SettingsStorage.load(LocalUsage.self, "usage", defaults: defaults)
        XCTAssertTrue(saved?.days.isEmpty == true)
        XCTAssertTrue(saved?.sessions.isEmpty == true)
    }

    func testRecentVoiceRankingSurvivesLongHistoricalSessions() {
        var usage = LocalUsage()
        let today = Date()
        let old = Calendar.current.date(byAdding: .day, value: -14, to: today)!
        let count = RemoteProfiles.all.map { $0.inputs.count }.max()! + 3
        for index in 0..<count { usage.recordVoice(seconds: Double(100 + index), at: old) }
        for index in 1...count { usage.recordVoice(seconds: Double(index), at: today) }
        let recent = usage.sessions.filter { Calendar.current.isDate($0.date, inSameDayAs: today) }
        XCTAssertEqual(recent.count, RemoteProfiles.all.map { $0.inputs.count }.max()!)
        XCTAssertEqual(recent.first?.seconds, Double(count))
        XCTAssertEqual(recent.last?.seconds, 4)
        XCTAssertEqual(usage.sessions.first?.seconds, Double(99 + count))
        XCTAssertEqual(usage.days.last?.voiceSeconds, Double(count * (count + 1) / 2))
    }

    func testOldMappingDecodesWithNewOptionalFieldsAndGestures() throws {
        let old = Data(#"{"buttons":{"buttonA":{"action":"copy"}}}"#.utf8)
        let mapping = try JSONDecoder().decode(RemoteMapping.self, from: old)
        XCTAssertEqual(mapping[.buttonA].action, .copy)
        XCTAssertNil(mapping[.buttonA].referenceID)
        XCTAssertEqual(mapping[.buttonA, .double].action, .disabled)
        for trigger in ButtonTrigger.allCases {
            XCTAssertEqual(mapping[.power, trigger].action, .disabled)
        }
    }

    func testPowerFromHIDSupportsSingleDoubleAndLongGestures() throws {
        var mapping = RemoteMapping.defaults
        mapping[.power, .single] = ButtonMapping(action: .copy)
        mapping[.power, .double] = ButtonMapping(action: .paste)
        mapping[.power, .long] = ButtonMapping(action: .screenshot)
        let restored = try JSONDecoder().decode(RemoteMapping.self, from: JSONEncoder().encode(mapping))
        XCTAssertEqual(restored, mapping)
        let parser = XiaomiRemoteHIDParser()
        let clock = TestClock()
        let engine = RemoteGestureController(schedule: clock.schedule)
        var events: [(RemoteAction, Bool)] = []
        engine.onOutput = { events.append(($0.action, $1)) }
        func sendPower(_ pressed: Bool) {
            for event in parser.parse(usagePage: 0x0C, usage: 0x30, value: pressed ? 1 : 0) {
                engine.handle(event.input, pressed: event.isPressed, mapping: restored)
            }
        }
        sendPower(true)
        sendPower(false)
        XCTAssertTrue(events.isEmpty)
        clock.advance(0.38)
        XCTAssertEqual(events.map(\.0), [.copy, .copy])
        XCTAssertEqual(events.map(\.1), [true, false])

        events.removeAll()
        sendPower(true)
        sendPower(false)
        sendPower(true)
        sendPower(false)
        clock.advance(0.38)
        XCTAssertEqual(events.map(\.0), [.paste, .paste])
        XCTAssertEqual(events.map(\.1), [true, false])

        events.removeAll()
        sendPower(true)
        clock.advance(0.65)
        sendPower(false)
        clock.advance(0.38)
        XCTAssertEqual(events.map(\.0), [.screenshot, .screenshot])
        XCTAssertEqual(events.map(\.1), [true, false])
    }

    func testBackupRoundTripPreservesGestureReferencesAndProfiles() throws {
        let phrase = SavedPhrase(title: "问候", text: "你好 👋")
        var mapping = RemoteMapping.defaults
        mapping[.buttonA, .double] = ButtonMapping(action: .phrase, referenceID: phrase.id.uuidString)
        let profile = SavedKeyProfile(name: "工作", applicationPath: "/Applications/Xcode.app", mapping: mapping)
        let backup = SettingsBackup(mapping: mapping, profiles: [profile], macros: [SavedMacro(name: "开始")], phrases: [phrase])
        let decoded = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(backup))
        XCTAssertEqual(decoded.mapping[.buttonA, .double].referenceID, phrase.id.uuidString)
        XCTAssertEqual(decoded.profiles, [profile])
        XCTAssertEqual(decoded.phrases, [phrase])
        XCTAssertEqual(decoded.macros.first?.steps.count, 1)
    }

    func testUsageAggregatesByDayAndDoesNotRecordInvalidDuration() {
        var usage = LocalUsage()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        usage.record(.buttonA, at: date)
        usage.record(.buttonA, at: date.addingTimeInterval(1))
        usage.recordVoice(seconds: 12, at: date)
        usage.recordVoice(seconds: .infinity, at: date)
        XCTAssertEqual(usage.days.count, 1)
        XCTAssertEqual(usage.days[0].count, 2)
        XCTAssertEqual(usage.days[0].voiceSeconds, 12)
        XCTAssertEqual(usage.sessions.count, 1)
    }

    @MainActor
    func testImmediateGestureReleasesOriginalMappingAfterEdit() {
        let engine = RemoteGestureController()
        var events: [(RemoteAction, Bool)] = []
        engine.onOutput = { events.append(($0.action, $1)) }
        var mapping = RemoteMapping.defaults
        engine.handle(.buttonA, pressed: true, mapping: mapping)
        mapping[.buttonA] = ButtonMapping(action: .copy)
        engine.handle(.buttonA, pressed: false, mapping: mapping)
        XCTAssertEqual(events.map(\.0), [.enter, .enter])
        XCTAssertEqual(events.map(\.1), [true, false])
    }

    @MainActor
    func testDoubleGestureSuppressesPendingSingle() {
        let clock = TestClock()
        let engine = RemoteGestureController(schedule: clock.schedule)
        var events: [RemoteAction] = []
        engine.onOutput = { if $1 { events.append($0.action) } }
        var mapping = RemoteMapping.defaults
        mapping[.buttonA, .double] = ButtonMapping(action: .copy)
        engine.handle(.buttonA, pressed: true, mapping: mapping)
        engine.handle(.buttonA, pressed: false, mapping: mapping)
        engine.handle(.buttonA, pressed: true, mapping: mapping)
        engine.handle(.buttonA, pressed: false, mapping: mapping)
        clock.advance(0.38)
        XCTAssertEqual(events, [.copy])
    }

    @MainActor
    func testLongGestureDoesNotEmitSingleOnRelease() {
        let clock = TestClock()
        let engine = RemoteGestureController(schedule: clock.schedule)
        var events: [RemoteAction] = []
        engine.onOutput = { if $1 { events.append($0.action) } }
        var mapping = RemoteMapping.defaults
        mapping[.buttonA, .long] = ButtonMapping(action: .paste)
        engine.handle(.buttonA, pressed: true, mapping: mapping)
        clock.advance(0.65)
        engine.handle(.buttonA, pressed: false, mapping: mapping)
        XCTAssertEqual(events, [.paste])
    }

    @MainActor
    func testCancelReleasesHeldKeyAndDropsPendingSingle() {
        let clock = TestClock()
        let engine = RemoteGestureController(schedule: clock.schedule)
        var events: [(RemoteAction, Bool)] = []
        engine.onOutput = { events.append(($0.action, $1)) }
        var mapping = RemoteMapping.defaults
        engine.handle(.dpadUp, pressed: true, mapping: mapping)
        mapping[.buttonA, .double] = ButtonMapping(action: .copy)
        engine.handle(.buttonA, pressed: true, mapping: mapping)
        engine.handle(.buttonA, pressed: false, mapping: mapping)
        engine.cancel()
        clock.advance(0.38)
        XCTAssertEqual(events.map(\.0), [.arrowUp, .arrowUp])
        XCTAssertEqual(events.map(\.1), [true, false])
    }
}
