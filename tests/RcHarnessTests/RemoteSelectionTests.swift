import XCTest
@testable import RcHarness

@MainActor
final class RemoteSelectionTests: XCTestCase {
    func testSelectionClearsConnectionStatePersistsAndScopesKeyProfiles() {
        let suite = "RcHarness.RemoteSelectionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = RemoteProfiles.xiaomiRC003
        let second = otherProfile()
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults,
                                         availableRemoteProfiles: [first, second])
        model.saveProfile(name: "仅第一款遥控器")
        let profiles = model.profiles
        model.setConnected(true)
        model.setInput(.buttonA, pressed: true)
        model.setVoice(status: "已连接", ready: true, battery: 0.78)
        model.setStreaming(true)
        model.editorVisible = true
        defaults.set(UUID().uuidString, forKey: SettingsKeys.voicePeripheralUUID)
        var switches: [String] = []
        model.onRemoteProfileChange = { profile in
            switches.append(profile.id)
            XCTAssertFalse(model.isConnected)
            XCTAssertFalse(model.voiceReady)
            XCTAssertFalse(model.isStreaming)
            XCTAssertNil(model.batteryLevel)
            XCTAssertTrue(model.pressedInputs.isEmpty)
            XCTAssertFalse(model.editorVisible)
        }

        model.selectRemoteProfile(second.id)
        XCTAssertEqual(switches, [second.id])
        XCTAssertEqual(model.remoteProfile, second)
        XCTAssertFalse(model.profiles.contains { $0.name == "仅第一款遥控器" })
        XCTAssertNil(defaults.string(forKey: SettingsKeys.voicePeripheralUUID))
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults,
                                            availableRemoteProfiles: [first, second])
        XCTAssertEqual(restored.remoteProfile, second)
        model.selectRemoteProfile(second.id)
        model.selectRemoteProfile("unknown-adapter")
        XCTAssertEqual(switches, [second.id])
        XCTAssertEqual(model.remoteProfile, second)
        model.selectRemoteProfile(first.id)
        XCTAssertEqual(model.profiles, profiles)
    }

    func testUnavailableSavedAdapterFallsBackToSupportedProfile() {
        let suite = "RcHarness.RemoteSelectionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("google-gy3le", forKey: SettingsKeys.selectedRemoteProfileID)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.remoteProfile, RemoteProfiles.xiaomiRC003)
        XCTAssertEqual(model.availableRemoteProfiles, RemoteProfiles.all)
        XCTAssertEqual(model.availableRemoteProfiles.map(\.id), ["xiaomi-rc001", "xiaomi-rc003-ms", "google-g9n9n"])
    }

    private func otherProfile() -> RemoteProfile {
        let reference = RemoteProfiles.xiaomiRC003
        return RemoteProfile(id: "test-adapter", displayName: "Test Remote", shortName: "Test Remote",
                             model: "Test", keyProfilePrefix: "TEST-", vendorID: reference.vendorID, productID: reference.productID,
                             voiceModelNumbers: [], supportsVoiceTap: false, bluetoothNames: [],
                             bluetoothNameFragments: [], inputs: reference.inputs)
    }
}
