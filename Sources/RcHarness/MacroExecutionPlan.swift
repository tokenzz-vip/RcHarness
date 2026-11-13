import Foundation

enum MacroExecutionError: LocalizedError, Equatable {
    case circularReference(String)
    case missingReference
    case tooManySteps
    case unsupportedAction

    var errorDescription: String? {
        switch self {
        case .circularReference(let name): "组合动作「\(name)」存在循环引用，请修改后重试。"
        case .missingReference: "组合动作中的引用未设置或已删除，请重新选择。"
        case .tooManySteps: "组合动作展开后超过 100 个步骤，请减少步骤或嵌套调用。"
        case .unsupportedAction: "组合动作不支持模式切换、切换应用、打开 Harness 列表或唤出常用语，请移除该步骤后重试。"
        }
    }
}

/// Expand a snapshot before scheduling so nested calls never restart the runner.
struct MacroExecutionPlan {
    struct Event: Equatable {
        let mapping: ButtonMapping
        let offset: TimeInterval
        let text: String?
    }

    let events: [Event]
    let duration: TimeInterval

    init(_ macro: SavedMacro, macros: [SavedMacro], phrases: [SavedPhrase] = []) throws {
        let byID = Dictionary(macros.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let phrasesByID = Dictionary(phrases.map { ($0.id.uuidString, $0.text) }, uniquingKeysWith: { first, _ in first })
        var events: [Event] = []
        var offset: TimeInterval = 0
        var remainingSteps = 100

        func expand(_ macro: SavedMacro, path: Set<UUID>) throws {
            guard !path.contains(macro.id) else { throw MacroExecutionError.circularReference(macro.name) }
            let path = path.union([macro.id])
            for step in macro.steps {
                guard remainingSteps > 0 else { throw MacroExecutionError.tooManySteps }
                remainingSteps -= 1
                guard step.mapping.action != .switchToNativeMode, step.mapping.action != .openHarnessSwitcher,
                      step.mapping.action != .openPhrases, step.mapping.action != .switchApplications else {
                    throw MacroExecutionError.unsupportedAction
                }
                if step.mapping.action == .macro {
                    guard let reference = step.mapping.referenceID.flatMap(UUID.init(uuidString:)),
                          let child = byID[reference] else { throw MacroExecutionError.missingReference }
                    try expand(child, path: path)
                } else {
                    var text: String?
                    if step.mapping.action == .phrase {
                        guard let id = step.mapping.referenceID, let phrase = phrasesByID[id] else {
                            throw MacroExecutionError.missingReference
                        }
                        text = phrase
                    }
                    events.append(Event(mapping: step.mapping, offset: offset, text: text))
                }
                offset += min(10, max(0, step.delay.isFinite ? step.delay : 0))
            }
        }

        try expand(macro, path: [])
        self.events = events
        duration = offset
    }

    static func wouldCreateCycle(referencing childID: UUID, from parentID: UUID, macros: [SavedMacro]) -> Bool {
        let byID = Dictionary(macros.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pending = [childID]
        var visited = Set<UUID>()
        while let id = pending.popLast() {
            if id == parentID { return true }
            guard visited.insert(id).inserted, let macro = byID[id] else { continue }
            pending.append(contentsOf: macro.steps.compactMap { step in
                step.mapping.action == .macro ? step.mapping.referenceID.flatMap(UUID.init(uuidString:)) : nil
            })
        }
        return false
    }
}
