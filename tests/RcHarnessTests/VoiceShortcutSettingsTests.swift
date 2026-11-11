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
        let hold = VoiceShortcutChoice.singles[2].shortcut
        let tap = VoiceShortcutChoice.pairs[6].shortcut
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

    func testGoogleTapImportAndSwitchBackToHoldKeepBothShortcutsAndXiaomiDisabled() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertEqual(model.voiceMode, .hold, "Existing Google configurations default to hold")
        let hold = VoiceShortcutChoice.singles[2].shortcut
        let tap = VoiceShortcutChoice.pairs[6].shortcut
        model.voiceHoldShortcut = hold
        model.voiceTapShortcut = tap
        model.voiceMode = .tap
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        model.voiceMode = .hold
        try model.applyConfiguration(backup)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.voiceMode, .tap)
        XCTAssertEqual(restored.effectiveMapping[.options].shortcut, tap)
        restored.voiceMode = .hold
        XCTAssertEqual(restored.effectiveMapping[.options].shortcut, hold)
        XCTAssertEqual(restored.voiceTapShortcut, tap)
        for profile in [RemoteProfiles.xiaomiRC001, RemoteProfiles.xiaomiRC003] {
            restored.selectRemoteProfile(profile.id)
            restored.voiceMode = .tap
            XCTAssertEqual(restored.voiceMode, .hold)
            XCTAssertFalse(restored.remoteProfile.supportsVoiceTap)
            XCTAssertEqual(restored.configurationBackup().globalButtons?.voiceMode, .hold)
        }
        restored.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertEqual(restored.voiceMode, .hold)
        XCTAssertEqual(restored.voiceHoldShortcut, hold)
        XCTAssertEqual(restored.voiceTapShortcut, tap)
    }

    func testHeldRecordedShortcutSendsIndependentEdgesAndFnSpaceSharesHIDSource() {
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        sender.sendShortcut(.voiceHoldDefault, pressed: true)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, .flagsChanged)
        sender.sendShortcut(.voiceHoldDefault, pressed: false)
        XCTAssertEqual(events.last?.flags, [])
        let fnSpace = RecordedShortcut(keyCode: 49, modifiers: CGEventFlags.maskSecondaryFn.rawValue, label: "Fn + Space")
        sender.sendShortcut(fnSpace, pressed: true)
        sender.sendShortcut(fnSpace, pressed: false)
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [63, 63, 49, 49])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.eventSourceStateID) }, [1, 1, 1, 1])
        XCTAssertEqual(events[2].flags, .maskSecondaryFn)
        XCTAssertEqual(events[3].flags, [])
    }

    func testInvalidOldVoiceBindingsMigrateAndSaveFallback() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        var backup = model.configurationBackup()
        let fnSpace = RecordedShortcut(keyCode: 49, modifiers: CGEventFlags.maskSecondaryFn.rawValue, label: "Fn + Space")
        backup.globalButtons?.voice = ButtonMapping(action: .recordedShortcut, shortcut: fnSpace)
        backup.globalButtons?.voiceTapShortcut = fnSpace
        try model.applyConfiguration(backup)
        XCTAssertEqual(model.voiceHoldShortcut, .voiceHoldDefault)
        XCTAssertEqual(model.voiceTapShortcut, .voiceHoldDefault)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.voiceHoldShortcut, .voiceHoldDefault)
        XCTAssertEqual(restored.voiceTapShortcut, .voiceHoldDefault)
    }

}
