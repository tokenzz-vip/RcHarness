import Foundation

enum DeletionTarget: Equatable {
    case phrase(UUID)
    case macro(UUID)
    case profile(UUID, remoteID: String)

    var objectID: UUID {
        switch self {
        case .phrase(let id), .macro(let id), .profile(let id, _): id
        }
    }

    var referenceAction: RemoteAction? {
        switch self {
        case .phrase: .phrase
        case .macro: .macro
        case .profile: nil
        }
    }
}

/// Direct and transitive consumers, across all saved device configurations.
struct DeletionImpact: Equatable {
    struct MappingUse: Equatable, Identifiable {
        let remoteID: String
        let profileID: UUID?
        let name: String
        let direct: Int
        let indirect: Int
        var id: String { remoteID + ":" + (profileID?.uuidString ?? "global") }
        var count: Int { direct + indirect }
    }
    struct MacroUse: Equatable, Identifiable {
        let id: UUID
        let name: String
        let directSteps: Int
    }
    let mappings: [MappingUse]
    let macros: [MacroUse]
    let assignments: [ControllerInput]
    var hasReferences: Bool { !mappings.isEmpty || !macros.isEmpty || !assignments.isEmpty }
    var directMappings: Int { mappings.reduce(0) { $0 + $1.direct } }
    var indirectMappings: Int { mappings.reduce(0) { $0 + $1.indirect } }
    var remoteCount: Int { Set(mappings.map(\.remoteID)).count }

    init(target: DeletionTarget, backup: SettingsBackup) {
        func directlyReferences(_ mapping: ButtonMapping) -> Bool {
            mapping.action == target.referenceAction && mapping.referenceID == target.objectID.uuidString
        }
        var affected = Set<UUID>()
        let deletedMacroID: UUID?
        if case .macro(let id) = target {
            deletedMacroID = id
            affected.insert(id)
        } else {
            deletedMacroID = nil
        }
        var changed = true
        while changed {
            changed = false
            for macro in backup.macros where !affected.contains(macro.id) {
                if macro.steps.contains(where: { step in
                    directlyReferences(step.mapping) || (step.mapping.action == .macro &&
                        step.mapping.referenceID.flatMap(UUID.init(uuidString:)).map(affected.contains) == true)
                }) {
                    affected.insert(macro.id)
                    changed = true
                }
            }
        }
        macros = backup.macros.filter { affected.contains($0.id) && $0.id != deletedMacroID }.map { macro in
            MacroUse(id: macro.id, name: macro.name,
                     directSteps: macro.steps.filter { directlyReferences($0.mapping) }.count)
        }
        func counts(_ mappings: [ButtonMapping]) -> (Int, Int) {
            let direct = mappings.filter(directlyReferences).count
            let indirect = mappings.filter {
                !directlyReferences($0) && $0.action == .macro &&
                    $0.referenceID.flatMap(UUID.init(uuidString:)).map(affected.contains) == true
            }.count
            return (direct, indirect)
        }
        var uses: [MappingUse] = []
        for (remoteID, configuration) in (backup.remoteKeyConfigurations ?? [:]).sorted(by: { $0.key < $1.key }) {
            for profile in configuration.profiles {
                let (direct, indirect) = counts(Array(profile.mapping.buttons.values))
                if direct + indirect > 0 {
                    uses.append(MappingUse(remoteID: remoteID, profileID: profile.id, name: profile.name,
                                           direct: direct, indirect: indirect))
                }
            }
            let globals = configuration.globalButtons
            let mappings = globals.buttons.flatMap { [$0.single, $0.double, $0.long] } + [globals.voice]
            let (direct, indirect) = counts(mappings)
            if direct + indirect > 0 {
                uses.append(MappingUse(remoteID: remoteID, profileID: nil, name: "全局按键",
                                       direct: direct, indirect: indirect))
            }
        }
        mappings = uses
        if case .phrase(let id) = target {
            assignments = PhraseAssignments.inputs.filter { backup.phraseAssignments?[$0] == id }
        } else {
            assignments = []
        }
    }
}

struct PendingDeletion: Identifiable {
    let id = UUID()
    let target: DeletionTarget
    let name: String
    let impact: DeletionImpact
}

/// Neighbours retain manual ordering even when unrelated entries have changed.
struct DeletedPosition {
    let index: Int
    let previous: UUID?
    let next: UUID?

    init(index: Int, ids: [UUID]) {
        self.index = index
        previous = index > 0 ? ids[index - 1] : nil
        next = index + 1 < ids.count ? ids[index + 1] : nil
    }

    func insertionIndex(in ids: [UUID]) -> Int {
        if let next, let index = ids.firstIndex(of: next) { return index }
        if let previous, let index = ids.firstIndex(of: previous) { return index + 1 }
        return min(index, ids.count)
    }
}

struct DeletedConfigurationObject: Identifiable {
    enum Value {
        case phrase(SavedPhrase, assignments: [ControllerInput])
        case macro(SavedMacro)
        case profile(SavedKeyProfile, remoteID: String, wasSelected: Bool)
    }
    let id = UUID()
    let value: Value
    let position: DeletedPosition
    var name: String {
        switch value {
        case .phrase(let phrase, _): phrase.displayTitle
        case .macro(let macro): macro.name
        case .profile(let profile, _, _): profile.name
        }
    }
}

extension RemoteDashboardModel {
    func deletionImpact(for target: DeletionTarget) -> DeletionImpact {
        DeletionImpact(target: target, backup: configurationBackup())
    }

    private func deletionName(for target: DeletionTarget) -> String? {
        switch target {
        case .phrase(let id): return phrases.first { $0.id == id }?.displayTitle
        case .macro(let id): return macros.first { $0.id == id }?.name
        case .profile(let id, let remoteID):
            guard remoteID == remoteProfile.id, canDeleteProfile(id) else { return nil }
            return profiles.first { $0.id == id }?.name
        }
    }

    /// UI entry point: referenced content always requires an impact review.
    func requestDeletion(_ target: DeletionTarget) {
        pendingDeletion = nil
        resolveNotices(from: .configurationDeletion)
        guard let name = deletionName(for: target) else { return }
        let impact = deletionImpact(for: target)
        if impact.hasReferences {
            pendingDeletion = PendingDeletion(target: target, name: name, impact: impact)
        } else {
            deleteConfigurationObject(target)
        }
    }

    func cancelDeletion() { pendingDeletion = nil }

    func confirmDeletion(_ id: UUID) {
        guard let pending = pendingDeletion, pending.id == id else { return }
        guard let name = deletionName(for: pending.target) else {
            pendingDeletion = nil
            postNotice("该项目已删除或当前遥控器已更换，请重新选择。", level: .error, source: .configurationDeletion)
            return
        }
        let impact = deletionImpact(for: pending.target)
        guard impact == pending.impact, name == pending.name else {
            pendingDeletion = PendingDeletion(target: pending.target, name: name, impact: impact)
            postNotice("引用或名称已变化，请核对最新删除影响后再确认。", level: .error, source: .configurationDeletion)
            return
        }
        if deleteConfigurationObject(pending.target) { pendingDeletion = nil }
    }

    /// Low-level operation for non-UI callers; always records undo and retains references.
    @discardableResult
    func deleteConfigurationObject(_ target: DeletionTarget) -> Bool {
        var backup = configurationBackup()
        let deleted: DeletedConfigurationObject
        switch target {
        case .phrase(let id):
            guard let index = backup.phrases.firstIndex(where: { $0.id == id }) else { return false }
            let slots = PhraseAssignments.inputs.filter { backup.phraseAssignments?[$0] == id }
            deleted = DeletedConfigurationObject(value: .phrase(backup.phrases[index], assignments: slots),
                position: DeletedPosition(index: index, ids: backup.phrases.map(\.id)))
            backup.phrases.remove(at: index)
            for input in slots { backup.phraseAssignments?[input] = nil }
        case .macro(let id):
            guard let index = backup.macros.firstIndex(where: { $0.id == id }) else { return false }
            deleted = DeletedConfigurationObject(value: .macro(backup.macros[index]),
                position: DeletedPosition(index: index, ids: backup.macros.map(\.id)))
            backup.macros.remove(at: index)
        case .profile(let id, let remoteID):
            guard remoteID == remoteProfile.id, canDeleteProfile(id),
                  var configuration = backup.remoteKeyConfigurations?[remoteID],
                  let index = configuration.profiles.firstIndex(where: { $0.id == id }) else { return false }
            deleted = DeletedConfigurationObject(value: .profile(configuration.profiles[index], remoteID: remoteID,
                wasSelected: configuration.selectedProfileID == id),
                position: DeletedPosition(index: index, ids: configuration.profiles.map(\.id)))
            configuration.profiles.remove(at: index)
            if configuration.selectedProfileID == id {
                configuration.selectedProfileID = SavedKeyProfile.defaultID
                configuration.selectedHarnessID = nil
            }
            backup.remoteKeyConfigurations?[remoteID] = configuration
            backup.profiles = configuration.profiles
        }
        do {
            try commitDeletionChange(backup)
            deletionUndoStack.append(deleted)
            resolveNotices(from: .configurationDeletion)
            return true
        } catch {
            postNotice("删除未保存，当前配置未更改：" + error.localizedDescription, level: .error, source: .configurationDeletion)
            return false
        }
    }

    func undoDeletion() {
        guard let deleted = deletionUndoStack.last else { return }
        var backup = configurationBackup()
        switch deleted.value {
        case .phrase(let phrase, let assignments):
            guard !backup.phrases.contains(where: { $0.id == phrase.id }) else {
                postNotice("无法撤销：已有相同 ID 的常用语。", level: .error, source: .configurationDeletion)
                return
            }
            guard assignments.allSatisfy({ backup.phraseAssignments?[$0] == nil || backup.phraseAssignments?[$0] == phrase.id }) else {
                postNotice("无法撤销：原五向位置已重新分配，请先解除新分配后重试。", level: .error, source: .configurationDeletion)
                return
            }
            backup.phrases.insert(phrase, at: deleted.position.insertionIndex(in: backup.phrases.map(\.id)))
            for input in assignments { backup.phraseAssignments?[input] = phrase.id }
        case .macro(let macro):
            guard !backup.macros.contains(where: { $0.id == macro.id || $0.name.caseInsensitiveCompare(macro.name) == .orderedSame }) else {
                postNotice("无法撤销：已有相同 ID 或名称的组合动作，请先处理冲突。", level: .error, source: .configurationDeletion)
                return
            }
            backup.macros.insert(macro, at: deleted.position.insertionIndex(in: backup.macros.map(\.id)))
        case .profile(let profile, let remoteID, let wasSelected):
            guard var configuration = backup.remoteKeyConfigurations?[remoteID] else {
                postNotice("无法撤销：原遥控器配置已不存在。", level: .error, source: .configurationDeletion)
                return
            }
            guard !configuration.profiles.contains(where: { $0.id == profile.id || $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }) else {
                postNotice("无法撤销：原遥控器已有相同 ID 或名称的方案，请先处理冲突。", level: .error, source: .configurationDeletion)
                return
            }
            configuration.profiles.insert(profile, at: deleted.position.insertionIndex(in: configuration.profiles.map(\.id)))
            // Restore a fallback selection only; keep a later explicit choice intact.
            if wasSelected, configuration.selectedProfileID == SavedKeyProfile.defaultID, configuration.selectedHarnessID == nil {
                configuration.selectedProfileID = profile.id
            }
            backup.remoteKeyConfigurations?[remoteID] = configuration
            if remoteID == remoteProfile.id { backup.profiles = configuration.profiles }
        }
        do {
            try commitDeletionChange(backup)
            deletionUndoStack.removeLast()
            postNotice("已撤销删除「\(deleted.name)」", level: .success, source: .configurationDeletion)
        } catch {
            postNotice("撤销未保存，当前配置未更改：" + error.localizedDescription, level: .error, source: .configurationDeletion)
        }
    }

    func dismissDeletionUndo() { deletionUndoStack.removeAll() }

    private func commitDeletionChange(_ backup: SettingsBackup) throws {
        let recovery = SettingsStorage.configurationRecovery(defaults: defaults)
        try SettingsStorage.commitConfiguration(backup, recovery: recovery, defaults: defaults)
        installConfiguration(backup, recoveryDate: configurationRecoveryDate, resetDeletionState: false, notifyVoiceChange: false)
    }
}
