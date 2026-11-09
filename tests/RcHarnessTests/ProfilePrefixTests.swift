import SwiftUI
import XCTest
@testable import RcHarness

@MainActor
final class ProfilePrefixTests: XCTestCase {
    func testPrefixVisibilityDefaultsOffAndOnlyChangesPresentation() throws {
        for remote in RemoteProfiles.all {
            let suite = "RcHarness.ProfilePrefixTests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            model.selectRemoteProfile(remote.id)
            XCTAssertFalse(model.showKeyProfilePrefix)
            XCTAssertEqual(model.profileDisplayPrefix, "")
            XCTAssertTrue(model.profiles.allSatisfy { model.profileDisplayName($0) == $0.name })

            XCTAssertTrue(model.saveProfile(name: "工作"))
            XCTAssertEqual(model.actionMessage, "已创建按键方案「工作」")
            let id = try XCTUnwrap(model.selectedProfileID)
            XCTAssertTrue(model.bindProfile(id, to: "claude"))
            model.update(ButtonMapping(action: .copy), for: .buttonA, trigger: .single)
            let backup = model.configurationBackup()
            var mappingChanged = false
            model.onMappingChange = { _ in mappingChanged = true }
            XCTAssertEqual(model.activeMappingName, "工作")

            for visible in [true, false, true] {
                let savedConfigurations = defaults.data(forKey: "RcHarness." + SettingsKeys.Stored.remoteKeyConfigurations)
                model.showKeyProfilePrefix = visible
                let prefix = visible ? remote.keyProfilePrefix : ""
                XCTAssertEqual(model.profileDisplayPrefix, prefix)
                XCTAssertEqual(model.activeMappingName, prefix + "工作")
                XCTAssertTrue(model.profiles.allSatisfy { model.profileDisplayName($0) == prefix + $0.name })
                XCTAssertEqual(model.configurationBackup().profiles, backup.profiles)
                XCTAssertEqual(model.configurationBackup().harnesses, backup.harnesses)
                XCTAssertEqual(model.configurationBackup().remoteKeyConfigurations, backup.remoteKeyConfigurations)
                XCTAssertEqual(defaults.data(forKey: "RcHarness." + SettingsKeys.Stored.remoteKeyConfigurations), savedConfigurations)
                XCTAssertFalse(mappingChanged)

                let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
                XCTAssertEqual(restored.showKeyProfilePrefix, visible)
                XCTAssertEqual(restored.activeMappingName, prefix + "工作")
                XCTAssertEqual(restored.remoteProfile.keyProfilePrefix, remote.keyProfilePrefix)
                XCTAssertEqual(restored.profiles.first { $0.id == id }?.mapping[.buttonA].action, .copy)
            }
        }
    }

    func testEveryRemoteKeepsItsPrefixAcrossNamingAndReloading() throws {
        let expected = ["RC1-", "RC3-", "G9N-"]
        for (remote, prefix) in zip(RemoteProfiles.all, expected) {
            let suite = "RcHarness.ProfilePrefixTests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            model.showKeyProfilePrefix = true
            model.selectRemoteProfile(remote.id)
            XCTAssertEqual(remote.keyProfilePrefix, prefix)
            XCTAssertTrue(model.profiles.allSatisfy { model.profileDisplayName($0) == prefix + $0.name })

            XCTAssertTrue(model.saveProfile(name: "工作"))
            let id = try XCTUnwrap(model.selectedProfileID)
            XCTAssertEqual(model.activeMappingName, prefix + "工作")
            XCTAssertTrue(model.renameProfile(id, name: "写作"))
            XCTAssertEqual(model.activeProfileName, "写作")
            XCTAssertEqual(model.activeMappingName, prefix + "写作")
            XCTAssertFalse(model.renameProfile(id, name: ""))
            XCTAssertEqual(model.activeMappingName, prefix + "写作")

            let copy = try XCTUnwrap(model.duplicateProfile(id))
            XCTAssertEqual(model.activeMappingName, prefix + "写作的复制")
            let backup = model.configurationBackup()
            XCTAssertEqual(backup.profiles.first { $0.id == copy }?.name, "写作的复制")
            let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
            XCTAssertEqual(restored.activeMappingName, prefix + "写作的复制")
            try restored.applyConfiguration(backup)
            restored.activateProfile(copy)
            XCTAssertEqual(restored.activeMappingName, prefix + "写作的复制")
        }
    }

    func testLegacyNamesGainTheSelectedRemotePrefixWithoutChangingBindings() throws {
        let suite = "RcHarness.ProfilePrefixTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = SavedKeyProfile(name: "原有方案", mapping: .defaults)
        SettingsStorage.save([legacy], SettingsKeys.Stored.profiles, defaults: defaults)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        model.showKeyProfilePrefix = true
        let restored = try XCTUnwrap(model.profiles.first { $0.id == legacy.id })
        XCTAssertEqual(restored, legacy)
        XCTAssertEqual(model.profileDisplayName(restored), "RC3-原有方案")
        model.selectRemoteProfile(RemoteProfiles.googleG9N9N.id)
        XCTAssertEqual(model.activeMappingName, "G9N-默认方案")
        model.selectRemoteProfile(RemoteProfiles.xiaomiRC003.id)
        model.activateProfile(legacy.id)
        XCTAssertEqual(model.activeMappingName, "RC3-原有方案")
    }

    func testNameSheetKeepsTheFixedPrefixSeparateFromTheEditableName() {
        var draft = "工作"
        let sheet = ProfileNameSheet(title: "重命名按键方案", symbol: "pencil", confirmTitle: "保存",
                                     name: Binding(get: { draft }, set: { draft = $0 }), prefix: "RC1-",
                                     validateName: { $0.isEmpty ? "方案名称不能为空" : nil },
                                     onCancel: {}, onConfirm: {})
        XCTAssertTrue(sheet.canConfirm)
        sheet.name = ""
        XCTAssertEqual(sheet.prefix, "RC1-")
        XCTAssertFalse(sheet.canConfirm)
        sheet.name = "新名称"
        XCTAssertEqual(sheet.prefix, "RC1-")
        XCTAssertTrue(sheet.canConfirm)
    }
}
