import Foundation

enum SettingsBackupError: LocalizedError, Equatable {
    case unreadable
    case invalidFormat
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取该文件，请检查文件权限后重试。"
        case .invalidFormat: "文件不是有效的 RcHarness 配置，请使用 RcHarness 导出的 JSON 文件。"
        case .unsupportedVersion(let version): "不支持的配置版本 \(version)，请使用当前版本的 RcHarness 重新导出。"
        }
    }
}

extension RemoteDashboardModel {
    func configurationBackup() -> SettingsBackup {
        var backup = SettingsBackup(mapping: defaultMapping, profiles: profiles, macros: macros, phrases: phrases, harnesses: harnesses,
                                    globalButtons: globalButtons, macroPresetsVersion: defaults.integer(forKey: SettingsKeys.macroPresetsVersion),
                                    remoteKeyConfigurations: keyConfigurationsForBackup())
        backup.version = 4
        return backup
    }

    /// Applies an imported configuration and returns the number of button
    /// mappings or macro steps that reference a missing phrase or macro.
    /// Those references are kept (the editor shows them as unset) so the user
    /// can rebind them instead of silently losing the button.
    @discardableResult
    func applyConfiguration(_ backup: SettingsBackup) throws -> Int {
        guard (1...4).contains(backup.version) else { throw SettingsBackupError.unsupportedVersion(backup.version) }
        editorVisible = false
        beginKeyConfigurationImport(backup.remoteKeyConfigurations ?? [:])
        replaceConfiguration(profiles: backup.profiles, macros: backup.macros, phrases: backup.phrases,
                             harnesses: backup.harnesses ?? HarnessConfiguration.defaults)
        initializeDefaultMacros(version: backup.macroPresetsVersion ?? 0)
        finishKeyConfigurationImport(legacyMapping: backup.mapping, legacyGlobals: backup.globalButtons,
                                     migrateLegacy: backup.version == 1)
        return danglingReferenceCount()
    }

    func danglingReferenceCount() -> Int {
        let phraseIDs = Set(phrases.map(\.id.uuidString))
        let macroIDs = Set(macros.map(\.id.uuidString))
        func isDangling(_ mapping: ButtonMapping) -> Bool {
            switch mapping.action {
            case .phrase: !mapping.referenceID.map(phraseIDs.contains).isTrue
            case .macro: !mapping.referenceID.map(macroIDs.contains).isTrue
            default: false
            }
        }
        let configurations = Array(keyConfigurationsForBackup().values)
        let buttons = configurations.flatMap(\.profiles).flatMap(\.mapping.buttons.values).filter(isDangling).count
        let globals = configurations.flatMap {
            [$0.globalButtons.single, $0.globalButtons.double, $0.globalButtons.long, $0.globalButtons.voice]
        }.filter(isDangling).count
        let steps = macros.flatMap(\.steps).map(\.mapping).filter(isDangling).count
        return buttons + globals + steps
    }

    func exportConfiguration(to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configurationBackup()).write(to: url, options: .atomic)
            actionMessage = "配置已导出"
        } catch {
            actionMessage = "导出失败：" + error.localizedDescription
        }
    }

    func importConfiguration(from url: URL) {
        do {
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw SettingsBackupError.unreadable }
            let backup: SettingsBackup
            do { backup = try JSONDecoder().decode(SettingsBackup.self, from: data) } catch { throw SettingsBackupError.invalidFormat }
            let dangling = try applyConfiguration(backup)
            func renamedCount(_ originals: [SavedKeyProfile], _ repaired: [SavedKeyProfile]) -> Int {
                let names = Dictionary(repaired.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                return originals.filter { profile in names[profile.id].map { $0 != profile.name } ?? false }.count
            }
            let repairedNames: Int
            if let configurations = backup.remoteKeyConfigurations, !configurations.isEmpty {
                let repaired = keyConfigurationsForBackup()
                repairedNames = configurations.reduce(0) { count, entry in
                    count + renamedCount(entry.value.profiles, repaired[entry.key]?.profiles ?? [])
                }
            } else {
                repairedNames = renamedCount(backup.profiles, profiles)
            }
            var notices: [String] = []
            if dangling > 0 { notices.append("\(dangling) 处常用语或组合动作引用已失效，请重新选择。") }
            if repairedNames > 0 { notices.append("已修复 \(repairedNames) 个方案名称，映射与绑定已保留。") }
            actionMessage = (["配置已导入"] + notices).joined(separator: "；")
        } catch {
            actionMessage = "导入失败：" + error.localizedDescription
        }
    }
}

private extension Optional where Wrapped == Bool {
    var isTrue: Bool { self == true }
}
