import SwiftUI
import XCTest
@testable import RcHarness

@MainActor
final class ProfileNameSheetTests: XCTestCase {
    func testRenameValidationTracksTheBoundNameAfterSheetCreation() throws {
        let suite = "RcHarness.ProfileNameSheetTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let profile = try XCTUnwrap(model.profiles.first { $0.name == "Codex 按键方案" })
        var draft = ""
        let name = Binding(get: { draft }, set: { draft = $0 })
        // A sheet can retain its content while its binding starts reading the
        // populated draft. Validation must use the same current value.
        let sheet = ProfileNameSheet(title: "重命名按键方案", symbol: "pencil", confirmTitle: "保存",
                                     name: name, validateName: { model.profileNameError($0, excluding: profile.id) },
                                     onCancel: {}, onConfirm: {})
        XCTAssertEqual(sheet.error, "方案名称不能为空")
        XCTAssertFalse(sheet.canConfirm)
        name.wrappedValue = profile.name
        XCTAssertEqual(sheet.name, "Codex 按键方案")
        XCTAssertNil(sheet.error, "A populated rename field must not retain the empty-name error")
        XCTAssertTrue(sheet.canConfirm)

        name.wrappedValue = " \n "
        XCTAssertEqual(sheet.error, "方案名称不能为空")
        XCTAssertFalse(sheet.canConfirm)
        name.wrappedValue = "  workbuddy 按键方案  "
        XCTAssertEqual(sheet.error, "已存在同名方案，请使用其他名称")
        XCTAssertFalse(sheet.canConfirm)
        name.wrappedValue = "  我的 Codex 方案  "
        XCTAssertNil(sheet.error)
        XCTAssertTrue(sheet.canConfirm)
        XCTAssertTrue(model.renameProfile(profile.id, name: sheet.name))
        XCTAssertEqual(model.profiles.first { $0.id == profile.id }?.name, "我的 Codex 方案")
    }

    func testNewProfileValidationTracksTypingAndClearing() {
        let suite = "RcHarness.ProfileNameSheetTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        var draft = ""
        let name = Binding(get: { draft }, set: { draft = $0 })
        let sheet = ProfileNameSheet(title: "新建按键方案", symbol: "plus", confirmTitle: "创建",
                                     name: name, validateName: { $0.isEmpty ? nil : model.profileNameError($0) },
                                     onCancel: {}, onConfirm: {})
        XCTAssertNil(sheet.error)
        XCTAssertFalse(sheet.canConfirm)
        name.wrappedValue = "Codex 按键方案"
        XCTAssertEqual(sheet.error, "已存在同名方案，请使用其他名称")
        XCTAssertFalse(sheet.canConfirm)
        name.wrappedValue = "新方案"
        XCTAssertNil(sheet.error)
        XCTAssertTrue(sheet.canConfirm)
        name.wrappedValue = ""
        XCTAssertNil(sheet.error)
        XCTAssertFalse(sheet.canConfirm)
    }
}
