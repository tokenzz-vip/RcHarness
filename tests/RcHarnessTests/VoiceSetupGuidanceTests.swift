import Foundation
import XCTest
@testable import RcHarness

@MainActor
final class VoiceSetupGuidanceTests: XCTestCase {
    func testPermissionActionNavigatesRepeatedlyWithoutChangingConfiguration() throws {
        let suite = "RcHarness.VoiceSetupGuidanceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let before = model.configurationBackup()
        let preferences = defaults.dictionaryRepresentation()
        model.showVoicePermissionNotice()
        XCTAssertTrue(model.actionOpensPermissions)
        model.openPermissions()
        XCTAssertEqual(model.page, .about)
        XCTAssertEqual(model.actionMessage, VoiceSetupGuidance.permissions)
        XCTAssertTrue(model.actionOpensPermissions)
        let first = try XCTUnwrap(model.permissionsNavigationRequest)
        model.openPermissions()
        let second = try XCTUnwrap(model.permissionsNavigationRequest)
        XCTAssertNotEqual(first, second)
        model.finishPermissionsNavigation(first)
        XCTAssertEqual(model.permissionsNavigationRequest, second)
        model.finishPermissionsNavigation(second)
        XCTAssertNil(model.permissionsNavigationRequest)
        XCTAssertEqual(model.configurationBackup(), before)
        XCTAssertTrue(NSDictionary(dictionary: preferences).isEqual(to: defaults.dictionaryRepresentation()))
    }

    func testUnrelatedMessageRetainsPermissionNoticeAndDismissalRemovesOnlyItsAction() throws {
        let suite = "RcHarness.VoiceSetupGuidanceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.showVoicePermissionNotice()
        let permissionID = try XCTUnwrap(model.actionNotices.first?.id)
        model.postNotice("无法连接设备", level: .error, recoveryAction: .connection)
        XCTAssertFalse(model.actionOpensPermissions)
        XCTAssertTrue(model.actionNotices.contains { $0.id == permissionID })
        model.dismissNotice(try XCTUnwrap(model.actionNotices.first?.id))
        XCTAssertTrue(model.actionOpensPermissions)
        model.dismissNotice(permissionID)
        XCTAssertFalse(model.actionOpensPermissions)
    }

    func testInstallationGuidanceNamesSelectedReceiverAndHandlesUnavailableReceiver() {
        let selected = VoiceSetupGuidance.installationComplete(receiverName: "BlackHole 2ch")
        XCTAssertTrue(selected.contains("BlackHole 2ch"))
        XCTAssertFalse(selected.contains("RcHarness 遥控器麦克风"))
        let unavailable = VoiceSetupGuidance.installationComplete(receiverName: nil)
        XCTAssertFalse(unavailable.contains("当前接收设备："))
        XCTAssertTrue(unavailable.contains("连接与语音"))
    }
}
