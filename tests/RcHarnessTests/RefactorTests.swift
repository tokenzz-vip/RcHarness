import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class RefactorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "RcHarness.RefactorTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testEverySynthesizedEventGoesThroughTheInjectedPoster() {
        var events: [CGEvent] = []
        var opened: [URL] = []
        let sender = SystemEventSender(postEvent: { events.append($0) }, openApplication: { opened.append($0) })
        sender.typeText("你好👋")
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        sender.send(ButtonMapping(action: .scrollUp), pressed: true)
        XCTAssertEqual(events.last?.type, .scrollWheel)
        events.removeAll()
        sender.send(ButtonMapping(action: .volumeUp), pressed: true)
        sender.send(ButtonMapping(action: .volumeUp), pressed: false)
        XCTAssertEqual(events.count, 2)
        sender.send(ButtonMapping(action: .openApplication, applicationPath: "/Applications/Notes.app"), pressed: true)
        XCTAssertEqual(opened, [URL(fileURLWithPath: "/Applications/Notes.app")])
    }

    func testSharedHeldModifierWaitsForEveryOwnerBeforeRelease() {
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        let command = ButtonMapping(action: .leftCommand)
        sender.send(command, pressed: true)
        sender.send(command, pressed: true)
        sender.send(command, pressed: false)
        XCTAssertEqual(events.count, 1, "The first owner release must not release Command")
        XCTAssertTrue(events[0].flags.contains(.maskCommand))
        sender.send(command, pressed: false)
        XCTAssertEqual(events.count, 2)
        XCTAssertFalse(events[1].flags.contains(.maskCommand))
    }

    func testVoiceAndOrdinaryMappingShareModifiersWithoutClearingOtherKeys() {
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        let command = ButtonMapping(action: .leftCommand)
        let voice = RecordedShortcut(keyCode: VirtualKey.command, modifiers: 0x00100008, label: "Command")
        sender.send(command, pressed: true)
        sender.sendShortcut(voice, pressed: true)
        sender.send(command, pressed: false)
        XCTAssertEqual(events.count, 1)
        sender.send(ButtonMapping(action: .enter), pressed: true)
        sender.send(ButtonMapping(action: .enter), pressed: false)
        XCTAssertTrue(events.last!.flags.contains(.maskCommand), "An unrelated key-up must retain the voice modifier")
        sender.sendShortcut(voice, pressed: false)
        XCTAssertFalse(events.last!.flags.contains(.maskCommand))
    }

    func testReleasingOneMouseOrMediaMappingWaitsForTheOtherMapping() {
        for action in [RemoteAction.mouseLeft, .mouseRight, .volumeUp] {
            var events: [CGEvent] = []
            let sender = SystemEventSender(postEvent: { events.append($0) })
            let mapping = ButtonMapping(action: action)
            sender.send(mapping, pressed: true)
            sender.send(mapping, pressed: true)
            sender.send(mapping, pressed: false)
            XCTAssertEqual(events.count, 1)
            sender.send(mapping, pressed: false)
            XCTAssertEqual(events.count, 2)
        }
    }

    func testOverlappingShortcutsReleaseUsingTheOriginalKeySource() {
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        let withFn = RecordedShortcut(keyCode: VirtualKey.command,
            modifiers: CGEventFlags.maskSecondaryFn.union(.maskCommand).rawValue, label: "Fn Command")
        sender.sendShortcut(withFn, pressed: true)
        sender.send(ButtonMapping(action: .leftCommand), pressed: true)
        sender.sendShortcut(withFn, pressed: false)
        XCTAssertEqual(events.count, 1)
        sender.send(ButtonMapping(action: .leftCommand), pressed: false)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.getIntegerValueField(.eventSourceStateID), events.last?.getIntegerValueField(.eventSourceStateID))
    }

    func testVoiceStatisticsUseInjectedMonotonicTimeAndDiagnosticsIncludeSelectedModel() {
        var time: TimeInterval = 100
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults, monotonicTime: { time })
        model.setStreaming(true)
        time += 3.5
        model.setStreaming(false)
        XCTAssertEqual(model.usageStore.usage.sessions.first?.seconds, 3.5)
        model.voiceDiagnostics = "ConnectionPhase=等待重连\nLastConnectionFailure=型号不符"
        XCTAssertTrue(model.diagnosticsText.contains("RemoteModel=RC003-MS"))
        XCTAssertTrue(model.diagnosticsText.contains("OutputUID="))
        XCTAssertTrue(model.diagnosticsText.contains("LastConnectionFailure=型号不符"))
    }

    func testBacklogKeepsTheNewestSamplesWithinTheLimit() {
        var backlog = PCMBacklog()
        XCTAssertEqual(backlog.append([1, 2, 3], limit: 4), 0)
        XCTAssertEqual(backlog.append([4, 5, 6], limit: 4), 2)
        XCTAssertEqual(backlog.packets.flatMap { $0 }, [3, 4, 5, 6])
        XCTAssertEqual(backlog.append([7], limit: 0), 5)
        XCTAssertTrue(backlog.isEmpty)
        backlog.append([8], limit: 10)
        backlog.prepend([[6, 7]])
        XCTAssertEqual(backlog.count, 3)
        XCTAssertEqual(backlog.drain(), [[6, 7], [8]])
        XCTAssertEqual(backlog.count, 0)
    }

    func testProfileNamesAreTrimmedUniqueAndNonEmpty() {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertTrue(model.saveProfile(name: "  工作  "))
        let work = model.selectedProfileID!
        XCTAssertEqual(model.activeMappingName, "工作")
        XCTAssertFalse(model.saveProfile(name: "工作"))
        XCTAssertTrue(model.saveProfile(name: "Writing"))
        let writing = model.selectedProfileID!
        XCTAssertTrue(model.renameProfile(writing, name: " writing\n"), "Renaming to its own name with different case is allowed")
        XCTAssertFalse(model.renameProfile(writing, name: "工作"))
        XCTAssertFalse(model.renameProfile(writing, name: "   "))
        XCTAssertFalse(model.renameProfile(SavedKeyProfile.defaultID, name: "其他"))
        XCTAssertTrue(model.renameProfile(writing, name: " 写作 "))
        XCTAssertEqual(model.profiles.first(where: { $0.id == writing })?.name, "写作")
        let copy = model.duplicateProfile(work)!
        let secondCopy = model.duplicateProfile(work)!
        XCTAssertEqual(model.profiles.first(where: { $0.id == copy })?.name, "工作的复制")
        XCTAssertEqual(model.profiles.first(where: { $0.id == secondCopy })?.name, "工作的复制 2")
    }

    func testImportReportsDanglingReferencesAndReadableErrors() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .phrase, referenceID: UUID().uuidString)
        mapping[.buttonB, .double] = ButtonMapping(action: .macro, referenceID: nil)
        let macro = SavedMacro(name: "缺失", steps: [MacroStep(mapping: ButtonMapping(action: .macro, referenceID: UUID().uuidString))])
        let backup = SettingsBackup(mapping: mapping, profiles: [], macros: [macro], phrases: [])
        XCTAssertEqual(try model.applyConfiguration(backup), 3)
        XCTAssertThrowsError(try model.applyConfiguration(SettingsBackup(version: 7, mapping: .defaults, profiles: [], macros: [], phrases: []))) {
            XCTAssertEqual($0 as? SettingsBackupError, .unsupportedVersion(7))
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = directory.appendingPathComponent("invalid.json")
        try Data("{}".utf8).write(to: invalid)
        model.importConfiguration(from: invalid)
        XCTAssertTrue(model.actionMessage.contains("不是有效的 RcHarness 配置"))
        model.importConfiguration(from: directory.appendingPathComponent("missing.json"))
        XCTAssertTrue(model.actionMessage.contains("无法读取"))
        let exported = directory.appendingPathComponent("export.json")
        model.exportConfiguration(to: exported)
        model.importConfiguration(from: exported)
        let preview = try XCTUnwrap(model.pendingConfigurationImport)
        XCTAssertEqual(preview.prepared.danglingReferences, 3)
        try model.confirmConfigurationImport(preview.id)
        XCTAssertTrue(model.actionMessage.hasPrefix("配置已导入"))
        XCTAssertTrue(model.actionMessage.contains("3 处常用语或组合动作引用已失效"))
    }

    func testDriverAndAppAgreeOnTheFlushProperty() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let driver = try String(contentsOf: root.appendingPathComponent("Drivers/RcHarnessMicrophone/Driver.c"), encoding: .utf8)
        let value = String(format: "0x%08x", RcHarnessMicrophoneProtocol.flushProperty)
        XCTAssertTrue(driver.contains("FlushProperty = \(value)"), "Driver.c must define FlushProperty = \(value)")
    }

    func testAppBundleAllowsSystemLocalizationInNativeFilePanels() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plistURL = root.appendingPathComponent("Sources/RcHarness/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "zh-Hans")
        XCTAssertEqual(plist["CFBundleLocalizations"] as? [String], ["zh-Hans", "en"])
        XCTAssertEqual(plist["CFBundleAllowMixedLocalizations"] as? Bool, true)
    }

    func testRemoteProfileOwnsHardwareIdentity() {
        let profile = RemoteProfiles.xiaomiRC003
        XCTAssertTrue(profile.supportsBLEVoice)
        XCTAssertTrue(profile.acceptsVoiceModel("RC003-MS"))
        XCTAssertFalse(profile.acceptsVoiceModel("RC004"))
        XCTAssertFalse(profile.acceptsVoiceModel(nil))
        XCTAssertTrue(profile.matchesBluetoothName(" MI RC "))
    }

    func testStatisticsSummaryFiltersByRange() {
        var usage = LocalUsage()
        let now = Date()
        let old = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        usage.record(.buttonA, at: old)
        usage.record(.buttonB, at: now)
        usage.record(.buttonB, at: now)
        usage.recordVoice(seconds: 4, at: now)
        let day = UsageSummary(usage: usage, range: .day, now: now)
        XCTAssertEqual(day.pressCount, 2)
        XCTAssertEqual(day.buttonRanking.first?.key, "buttonB")
        XCTAssertEqual(day.buttonRanking.count, ControllerInput.allCases.count)
        XCTAssertEqual(day.buttonRanking.first { $0.key == ControllerInput.buttonA.rawValue }?.value, 0)
        XCTAssertEqual(day.chartBuckets.count, 1)
        XCTAssertEqual(day.chartBuckets.first?.count, 2)
        let all = UsageSummary(usage: usage, range: .all, now: now)
        XCTAssertEqual(all.pressCount, 3)
        XCTAssertEqual(all.activeDays, 2)
        XCTAssertEqual(all.sessions.count, 1)
        XCTAssertEqual(UsageSummary(usage: usage, range: .lastSevenDays, now: now).chartBuckets.count, 7)
    }

    func testStatisticsRankingIncludesEveryInputWithoutPresses() {
        for range in StatisticsRange.allCases {
            let summary = UsageSummary(usage: LocalUsage(), range: range)
            XCTAssertEqual(Set(summary.buttonRanking.map(\.key)), Set(ControllerInput.allCases.map(\.rawValue)))
            XCTAssertTrue(summary.buttonRanking.allSatisfy { $0.value == 0 })
            XCTAssertEqual(summary.buttonRanking.map(\.key), summary.buttonRanking.map(\.key).sorted())
            XCTAssertEqual(summary.pressCount, 0)
            XCTAssertEqual(summary.activeDays, 0)
        }
    }

    func testStatisticsVoiceRankingUsesAFixedLimitForAllRemotes() {
        var usage = LocalUsage()
        let now = Date()
        let old = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        for seconds in 1...20 {
            usage.recordVoice(seconds: Double(seconds), at: now)
            usage.recordVoice(seconds: Double(seconds + 100), at: old)
        }
        let day = UsageSummary(usage: usage, range: .day, now: now)
        XCTAssertEqual(day.rankedSessions.count, UsageSummary.voiceRankingLimit)
        XCTAssertEqual(day.rankedSessions.first?.seconds, 20)
        XCTAssertEqual(day.rankedSessions.last?.seconds, 6)
        let all = UsageSummary(usage: usage, range: .all, now: now)
        XCTAssertEqual(all.rankedSessions.count, UsageSummary.voiceRankingLimit)
        XCTAssertEqual(all.rankedSessions.first?.seconds, 120)
        XCTAssertTrue(UsageSummary(usage: LocalUsage(), range: .day).rankedSessions.isEmpty)
    }
}
