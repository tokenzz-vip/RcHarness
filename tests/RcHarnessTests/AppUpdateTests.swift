import AppKit
import SwiftUI
import XCTest
@testable import RcHarness

@MainActor
final class AppUpdateTests: XCTestCase {
    func testConfigurationRequiresHTTPSAndAnEd25519PublicKey() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let valid: [String: Any] = ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": key]
        XCTAssertTrue(AppUpdateModel.hasValidConfiguration(valid))
        XCTAssertFalse(AppUpdateModel.hasValidConfiguration([:]))
        XCTAssertFalse(AppUpdateModel.hasValidConfiguration(["SUFeedURL": "http://example.com/feed", "SUPublicEDKey": key]))
        XCTAssertFalse(AppUpdateModel.hasValidConfiguration(["SUFeedURL": "https://example.com/feed", "SUPublicEDKey": "placeholder"]))
    }

    func testChecksAreGatedByDriverStateAndPreferencesStayInSync() {
        let driver = UpdateDriverStub()
        let model = AppUpdateModel()
        model.checkForUpdates()
        model.start(driver: driver)
        XCTAssertTrue(model.isConfigured)
        XCTAssertTrue(model.canCheckForUpdates)
        model.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
        XCTAssertFalse(model.canCheckForUpdates)
        model.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
        let checkedAt = Date(timeIntervalSince1970: 123)
        driver.lastUpdateCheckDate = checkedAt
        driver.canCheckForUpdates = true
        driver.onChange?()
        XCTAssertEqual(model.lastUpdateCheckDate, checkedAt)
        model.setAutomaticallyChecksForUpdates(true)
        XCTAssertTrue(driver.automaticallyChecksForUpdates)
        XCTAssertTrue(model.automaticallyChecksForUpdates)
        driver.automaticallyChecksForUpdates = false
        driver.onChange?()
        XCTAssertFalse(model.automaticallyChecksForUpdates)
    }

    func testErrorsAreRetainedUntilRetryAndStartIsIdempotent() {
        let driver = UpdateDriverStub()
        let model = AppUpdateModel()
        model.start(driver: driver)
        model.start(driver: UpdateDriverStub())
        driver.onError?("网络连接失败")
        driver.onChange?()
        XCTAssertEqual(model.errorMessage, "网络连接失败")
        model.checkForUpdates()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(driver.checks, 1)
    }

    func testStartFailureDoesNotEnableUIAndCanBeRetried() {
        let driver = UpdateDriverStub()
        driver.startError = NSError(domain: "test", code: 1)
        let model = AppUpdateModel()
        model.start(driver: driver)
        XCTAssertFalse(model.canCheckForUpdates)
        XCTAssertFalse(model.isConfigured)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(driver.onChange)
        model.start(driver: UpdateDriverStub())
        XCTAssertTrue(model.canCheckForUpdates)
        XCTAssertNil(model.errorMessage)
    }

    func testUpdateFailureDoesNotPostDashboardNoticeOrClearOtherErrors() throws {
        let suite = "RcHarness.AppUpdateNoticeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let driver = UpdateDriverStub()
        model.updates.start(driver: driver)
        let audio = model.postNotice("接收设备不可用", level: .error, source: .audioOutput)
        driver.onError?("检查更新失败：网络连接失败")
        XCTAssertEqual(model.updates.errorMessage, "检查更新失败：网络连接失败")
        XCTAssertEqual(model.actionNotices.map(\.id), [audio])
        model.page = .connection
        driver.onError?("检查更新失败：获取升级信息失败")
        XCTAssertEqual(model.actionNotices.map(\.id), [audio])
        model.updates.checkForUpdates()
        XCTAssertNil(model.updates.errorMessage)
        XCTAssertEqual(model.actionNotices.map(\.id), [audio])
    }

    func testLongUpdateFailureDoesNotExpandVersionCard() async throws {
        _ = NSApplication.shared
        let suite = "RcHarness.AppUpdateLayoutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let driver = UpdateDriverStub()
        model.updates.start(driver: driver)
        let host = NSHostingView(rootView: AboutPage(model: model)
            .padding(SettingsStyle.pagePadding)
            .frame(width: 900)
            .fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await settle(host)
        let baseline = host.fittingSize.height
        driver.onError?(String(repeating: "检查更新失败：获取升级信息时出现错误，请稍后重试。", count: 8))
        await settle(host)
        XCTAssertEqual(host.fittingSize.height, baseline, accuracy: 0.1,
                       "Update failures must not change the version card layout")
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<3 {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }
    }
}

@MainActor
private final class UpdateDriverStub: AppUpdateDriving {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var lastUpdateCheckDate: Date?
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var checks = 0
    var startError: Error?
    func start() throws { if let startError { throw startError } }
    func checkForUpdates() {
        checks += 1
        canCheckForUpdates = false
        onChange?()
    }
}
