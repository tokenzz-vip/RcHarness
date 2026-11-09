import AppKit
import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class VoiceShortcutSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "RcHarness.VoiceShortcutSettingsTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testBothDefaultsAndXiaomiTapRestrictionPersistThroughImport() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.voiceHoldShortcut, .voiceHoldDefault)
        XCTAssertEqual(model.voiceTapShortcut, .voiceTapDefault)
        XCTAssertEqual(model.voiceMode, .hold)
        let hold = RecordedShortcut(keyCode: 0x28, modifiers: CGEventFlags.maskCommand.rawValue, label: "⌘K")
        let tap = RecordedShortcut(keyCode: 0x31, modifiers: CGEventFlags.maskAlternate.rawValue, label: "⌥Space")
        model.voiceHoldShortcut = hold
        model.voiceTapShortcut = tap
        model.voiceMode = .tap
        XCTAssertEqual(model.voiceMode, .hold)
        XCTAssertEqual(model.effectiveMapping[.options].shortcut, hold)
        var backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        backup.globalButtons?.voiceMode = .tap
        try model.applyConfiguration(backup)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.voiceMode, .hold)
        XCTAssertEqual(restored.voiceHoldShortcut, hold)
        XCTAssertEqual(restored.voiceTapShortcut, tap)
        XCTAssertFalse(restored.voiceFnTap)
    }

    func testOldModifierBindingsMigrateWithoutLosingShortcutAndMissingTapDefaults() throws {
        let legacy = GlobalButtonSettings(voice: ButtonMapping(action: .rightCommand))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "voiceMode")
        json.removeValue(forKey: "voiceTapShortcut")
        let decoded = try JSONDecoder().decode(GlobalButtonSettings.self, from: JSONSerialization.data(withJSONObject: json))
        SettingsStorage.save(decoded, SettingsKeys.Stored.globalButtons, defaults: defaults)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.voiceHoldShortcut.keyCode, VirtualKey.rightCommand)
        XCTAssertEqual(model.voiceTapShortcut, .voiceTapDefault)
        XCTAssertEqual(model.voiceMode, .hold)
        let normalized = try XCTUnwrap(SettingsStorage.load(GlobalButtonSettings.self, SettingsKeys.Stored.globalButtons, defaults: defaults))
        XCTAssertEqual(normalized.voiceTapShortcut, .voiceTapDefault)
        XCTAssertEqual(normalized.voiceMode, .hold)
    }

    func testHeldRecordedShortcutSendsIndependentEdgesAndFnSpaceSharesHIDSource() {
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        sender.sendShortcut(.voiceHoldDefault, pressed: true)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, .flagsChanged)
        sender.sendShortcut(.voiceHoldDefault, pressed: false)
        XCTAssertEqual(events.last?.flags, [])
        sender.sendShortcut(.voiceTapDefault, pressed: true)
        sender.sendShortcut(.voiceTapDefault, pressed: false)
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [63, 63, 49, 49])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.eventSourceStateID) }, [1, 1, 1, 1])
        XCTAssertEqual(events[2].flags, .maskSecondaryFn)
        XCTAssertEqual(events[3].flags, [])
    }

}
