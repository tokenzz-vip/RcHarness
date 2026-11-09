import AppKit
import XCTest
@testable import RcHarness

@MainActor
final class MappingResetTests: XCTestCase {
    func testCancelPreservesCustomMappingAndPersistedSettings() {
        withModel { model, defaults in
            model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .single)
            let profiles = model.profiles
            SettingsDialogs.resetMapping(model) { alert in
                XCTAssertEqual(alert.buttons.first?.title, "取消")
                return .alertFirstButtonReturn
            }
            XCTAssertEqual(model.profiles, profiles)
            let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            XCTAssertEqual(restored.mapping[.buttonA].action, .copy)
        }
    }

    func testConfirmRestoresOnlyTheSelectedProfileAndPreservesGlobalSettings() throws {
        try withModel { model, defaults in
            model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .single)
            let originalID = try XCTUnwrap(model.selectedProfileID)
            XCTAssertTrue(model.saveProfile(name: "自定义"))
            let customID = try XCTUnwrap(model.selectedProfileID)
            let globalButtons = model.globalButtons
            SettingsDialogs.resetMapping(model) { alert in
                XCTAssertTrue(alert.messageText.contains("自定义"))
                return .alertSecondButtonReturn
            }
            XCTAssertEqual(model.mapping[.buttonA].action, .enter)
            XCTAssertEqual(model.globalButtons, globalButtons)
            let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            XCTAssertEqual(restored.profiles.first { $0.id == customID }?.mapping[.buttonA].action, .enter)
            XCTAssertEqual(restored.profiles.first { $0.id == originalID }?.mapping[.buttonA].action, .copy)
        }
    }

    func testSwitchingProfileOrRemoteDuringConfirmationDoesNotResetEitherTarget() throws {
        try withModel { model, _ in
            model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .single)
            let originalID = try XCTUnwrap(model.selectedProfileID)
            XCTAssertTrue(model.saveProfile(name: "另一个方案"))
            model.update(ButtonMapping(action: .paste), for: .buttonA, trigger: .single)
            let otherID = try XCTUnwrap(model.selectedProfileID)
            model.activateProfile(originalID)
            SettingsDialogs.resetMapping(model) { _ in
                model.activateProfile(otherID)
                return .alertSecondButtonReturn
            }
            XCTAssertEqual(model.mapping[.buttonA].action, .paste)
            model.activateProfile(originalID)
            XCTAssertEqual(model.mapping[.buttonA].action, .copy)
            let originalRemote = model.remoteProfile.id
            let otherRemote = try XCTUnwrap(model.availableRemoteProfiles.first { $0.id != originalRemote })
            SettingsDialogs.resetMapping(model) { _ in
                model.selectRemoteProfile(otherRemote.id)
                model.update(ButtonMapping(action: .paste), for: .buttonA, trigger: .single)
                return .alertSecondButtonReturn
            }
            XCTAssertEqual(model.mapping[.buttonA].action, .paste)
            model.selectRemoteProfile(originalRemote)
            XCTAssertEqual(model.mapping[.buttonA].action, .copy)
        }
    }

    private func withModel(_ body: (RemoteDashboardModel, UserDefaults) throws -> Void) rethrows {
        let suite = "RcHarness.MappingResetTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(RemoteDashboardModel(mapping: .defaults, defaults: defaults), defaults)
    }
}
