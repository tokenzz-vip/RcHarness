import Foundation

enum SettingsBackupError: LocalizedError, Equatable {
    case unreadable
    case invalidFormat
    case unsupportedVersion(Int)
    case noRecovery
    case stalePreview

    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取该文件，请检查文件权限后重试。"
        case .invalidFormat: "文件不是有效的 RcHarness 配置，请使用 RcHarness 导出的 JSON 文件。"
        case .unsupportedVersion(let version): "不支持的配置版本 \(version)，请使用当前版本的 RcHarness 重新导出。"
        case .noRecovery: "没有可恢复的替换前配置。"
        case .stalePreview: "导入预览已关闭或更新，请重新选择配置。"
        }
    }
}

extension RemoteDashboardModel {
    func configurationBackup() -> SettingsBackup {
        var backup = SettingsBackup(mapping: defaultMapping, profiles: profiles, macros: macros, phrases: phrases, harnesses: harnesses,
                                    globalButtons: globalButtons, macroPresetsVersion: configurationMacroPresetsVersion,
                                    remoteKeyConfigurations: keyConfigurationsForBackup())
        backup.phraseAssignments = phraseAssignments
        backup.version = 4
        return backup
    }

    /// Non-UI replacements share validation, a recovery point and a single commit.
    @discardableResult
    func applyConfiguration(_ backup: SettingsBackup) throws -> Int {
        let prepared = try PreparedConfiguration(backup, remoteProfile: remoteProfile)
        try commitConfiguration(prepared)
        return prepared.danglingReferences
    }

    private func commitConfiguration(_ prepared: PreparedConfiguration) throws {
        let recovery = ConfigurationRecovery(date: Date(), backup: configurationBackup())
        // Nothing in the model changes if encoding the replacement or backup fails.
        try SettingsStorage.commitConfiguration(prepared.backup, recovery: recovery, defaults: defaults)
        installConfiguration(prepared.backup, recoveryDate: recovery.date)
    }

    func danglingReferenceCount() -> Int {
        PreparedConfiguration.danglingReferenceCount(in: configurationBackup())
    }

    func exportConfiguration(to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configurationBackup()).write(to: url, options: .atomic)
            resolveNotices(from: .configurationExport)
            postNotice("配置已导出", level: .success)
        } catch {
            postNotice("导出失败：" + error.localizedDescription, level: .error,
                       recoveryAction: .configuration, source: .configurationExport)
        }
    }

    /// Selecting a file only prepares the sheet. The decoded value is retained so
    /// later changes to the file cannot change what the user confirmed.
    func importConfiguration(from url: URL) {
        pendingConfigurationImport = nil
        do {
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw SettingsBackupError.unreadable }
            let backup: SettingsBackup
            do { backup = try JSONDecoder().decode(SettingsBackup.self, from: data) } catch { throw SettingsBackupError.invalidFormat }
            let prepared = try PreparedConfiguration(backup, remoteProfile: remoteProfile)
            pendingConfigurationImport = ConfigurationImportPreview(source: url.lastPathComponent, isRecovery: false,
                current: ConfigurationCounts(configurationBackup()), prepared: prepared)
        } catch {
            postNotice("导入失败：" + error.localizedDescription, level: .error,
                       recoveryAction: .configuration, source: .configurationImport)
        }
    }

    func previewConfigurationRecovery() {
        pendingConfigurationImport = nil
        do {
            guard let recovery = SettingsStorage.configurationRecovery(defaults: defaults) else { throw SettingsBackupError.noRecovery }
            let prepared = try PreparedConfiguration(recovery.backup, remoteProfile: remoteProfile, preservingSelection: true)
            pendingConfigurationImport = ConfigurationImportPreview(
                source: recovery.date.formatted(date: .abbreviated, time: .shortened) + " 的替换前备份", isRecovery: true,
                current: ConfigurationCounts(configurationBackup()), prepared: prepared)
        } catch {
            postNotice("恢复失败：" + error.localizedDescription, level: .error,
                       recoveryAction: .configuration, source: .configurationRecovery)
        }
    }

    func cancelConfigurationImport() { pendingConfigurationImport = nil }

    func confirmConfigurationImport(_ id: UUID) throws {
        guard let preview = pendingConfigurationImport, preview.id == id,
              preview.prepared.remoteProfileID == remoteProfile.id else { throw SettingsBackupError.stalePreview }
        try commitConfiguration(preview.prepared)
        pendingConfigurationImport = nil
        let title = preview.isRecovery ? "配置已恢复" : "配置已导入"
        resolveNotices(from: preview.isRecovery ? .configurationRecovery : .configurationImport)
        postNotice(([title, "已自动保存替换前配置，可在设置中恢复。"] + preview.prepared.notices).joined(separator: "；"),
                   level: preview.prepared.notices.isEmpty ? .success : .warning, recoveryAction: .configuration)
    }
}
