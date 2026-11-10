import Foundation
import XCTest
@testable import RcHarness

@MainActor
final class ActionNoticeTests: XCTestCase {
    func testSuccessExpiresAtThreeSecondsWithoutRemovingAnEarlierFailure() throws {
        try withModel { model, clock in
            let failure = model.postNotice("接收设备不可用", level: .error, recoveryAction: .connection)
            let success = model.postNotice("已复制", level: .success)
            clock.advance(2.99)
            XCTAssertEqual(model.actionNotices.map(\.id), [success, failure])
            clock.advance(0.01)
            XCTAssertEqual(model.actionNotices.map(\.id), [failure])
            clock.advance(600)
            XCTAssertEqual(model.actionNotices.map(\.id), [failure])
        }
    }

    func testRepeatedSuccessGetsANewLifetimeEvenWhenTextMatches() throws {
        try withModel { model, clock in
            let first = model.postNotice("已复制", level: .success)
            clock.advance(2)
            let second = model.postNotice("已复制", level: .success)
            XCTAssertNotEqual(first, second)
            clock.advance(1)
            XCTAssertEqual(model.actionNotices.map(\.id), [second])
            clock.advance(2)
            XCTAssertTrue(model.actionNotices.isEmpty)
        }
    }

    func testImportFailurePersistsAcrossNavigationAndUnrelatedOperations() throws {
        try withModel { model, clock in
            model.importConfiguration(from: URL(fileURLWithPath: "/nonexistent/\(UUID()).json"))
            let failure = try XCTUnwrap(model.actionNotices.first)
            XCTAssertEqual(failure.level, .error)
            XCTAssertEqual(failure.recoveryAction, .configuration)
            model.page = .mapping
            model.performNoticeRecovery(try XCTUnwrap(failure.recoveryAction))
            XCTAssertEqual(model.page, .about)
            model.postNotice("已复制", level: .success)
            clock.advance(60)
            XCTAssertEqual(model.actionNotices, [failure])
            let phrase = try XCTUnwrap(model.phrases.first)
            model.requestDeletion(.phrase(phrase.id))
            XCTAssertTrue(model.actionNotices.contains(failure))
            model.dismissNotice(failure.id)
            XCTAssertFalse(model.actionNotices.contains(failure))
        }
    }

    func testLongFailureRetainsTheEntireMessageAcrossTimeAndNavigation() throws {
        try withModel { model, clock in
            let message = "导入失败：\n" + (1...100).map {
                "第 \($0) 项：无法读取方案，请检查文件权限与配置格式。"
            }.joined(separator: "\n")
            model.postNotice(message, level: .error, recoveryAction: .configuration, source: .configurationImport)
            model.page = .connection
            clock.advance(60)
            XCTAssertEqual(model.actionNotices.first?.message, message)
            XCTAssertTrue(model.actionNotices.first?.message.hasSuffix("请检查文件权限与配置格式。") == true)
        }
    }

    func testSuccessfulImportResolvesOnlyTheImportFailure() throws {
        try withModel { model, clock in
            model.importConfiguration(from: URL(fileURLWithPath: "/nonexistent/\(UUID()).json"))
            let audio = model.postNotice("音频设备不可用", level: .error, recoveryAction: .connection, source: .audioOutput)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: file) }
            try JSONEncoder().encode(model.configurationBackup()).write(to: file)
            model.importConfiguration(from: file)
            try model.confirmConfigurationImport(try XCTUnwrap(model.pendingConfigurationImport?.id))
            clock.advance(60)
            XCTAssertFalse(model.actionNotices.contains { $0.source == .configurationImport })
            XCTAssertTrue(model.actionNotices.contains { $0.id == audio })
        }
    }

    func testAudioFailureKeepsRepairEntryUntilStreamingActuallyRecovers() throws {
        try withModel { model, clock in
            model.audioOutputState = .failed("无法启动所选接收设备，请刷新设备或重新安装麦克风组件。")
            let notice = try XCTUnwrap(model.actionNotices.first)
            XCTAssertEqual(notice.level, .error)
            model.page = .macros
            clock.advance(60)
            XCTAssertEqual(model.actionNotices, [notice])
            model.performNoticeRecovery(try XCTUnwrap(notice.recoveryAction))
            XCTAssertEqual(model.page, .connection)
            XCTAssertEqual(model.actionNotices, [notice])
            model.audioOutputState = .idle
            model.audioOutputState = .preparing
            XCTAssertEqual(model.actionNotices, [notice])
            model.audioOutputState = .streaming
            XCTAssertTrue(model.actionNotices.isEmpty)
        }
    }

    func testWarningsRemainAvailableAndClosingOneDoesNotCloseOthers() throws {
        try withModel { model, clock in
            let warning = model.postNotice("配置中有失效引用", level: .warning, recoveryAction: .configuration)
            let failure = model.postNotice("无法连接", level: .error, recoveryAction: .connection)
            model.showNextNotice()
            XCTAssertEqual(model.actionNotices.first?.id, warning)
            clock.advance(600)
            model.dismissNotice(warning)
            XCTAssertEqual(model.actionNotices.map(\.id), [failure])
        }
    }

    func testRepeatedRecoveryRequestsKeepTheLatestDestinationAndDoNotDismissFailures() throws {
        try withModel { model, _ in
            let failure = model.postNotice("设备不可用", level: .error, recoveryAction: .connection)
            model.performNoticeRecovery(.connection)
            let first = try XCTUnwrap(model.noticeNavigationRequest)
            XCTAssertEqual(first.action, .connection)
            model.performNoticeRecovery(.configuration)
            let second = try XCTUnwrap(model.noticeNavigationRequest)
            XCTAssertNotEqual(first.id, second.id)
            XCTAssertEqual(second.action, .configuration)
            XCTAssertEqual(model.page, .about)
            model.finishNoticeNavigation(first.id)
            XCTAssertEqual(model.noticeNavigationRequest?.id, second.id)
            model.finishNoticeNavigation(second.id)
            XCTAssertNil(model.noticeNavigationRequest)
            XCTAssertEqual(model.actionNotices.map(\.id), [failure])
        }
    }

    private func withModel(_ body: (RemoteDashboardModel, TestClock) throws -> Void) throws {
        let suite = "RcHarness.ActionNoticeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock()
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults,
                                         noticeSchedule: clock.schedule(after:operation:))
        try body(model, clock)
    }
}
