import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class DefaultMacroTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var newPresets: [SavedMacro] { DefaultMacros.cursor + DefaultMacros.deepSeek + DefaultMacros.workBuddy + DefaultMacros.openCode }
    private var allPresets: [SavedMacro] { DefaultMacros.codex + DefaultMacros.claude + newPresets }

    override func setUp() async throws {
        suiteName = "RcHarness.DefaultMacroTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMappingCardTitlesDistinguishRecentChatsAndPreserveFullNames() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let first = try XCTUnwrap(model.macros.first { $0.name == "Codex-转到最近聊天1" })
        let second = try XCTUnwrap(model.macros.first { $0.name == "Codex-转到最近聊天2" })
        XCTAssertEqual(DefaultMacros.cardTitle(for: first), "转到最近聊天1")
        XCTAssertEqual(DefaultMacros.cardTitle(for: second), "转到最近聊天2")
        XCTAssertEqual(model.mappingTitle(ButtonMapping(action: .macro, referenceID: first.id.uuidString)), "Codex-转到最近聊天1")
        XCTAssertEqual(model.macros.first { $0.id == first.id }?.name, first.name)
    }

    func testMappingCardTitlesKeepCustomAndRenamedMacroNames() throws {
        var renamed = try XCTUnwrap(DefaultMacros.codex.first)
        renamed.name = "Codex-我的自定义动作"
        XCTAssertEqual(DefaultMacros.cardTitle(for: renamed), renamed.name)
        let custom = SavedMacro(name: "Codex-新建会话")
        XCTAssertEqual(DefaultMacros.cardTitle(for: custom), custom.name)
        for macro in allPresets {
            XCTAssertFalse(DefaultMacros.cardTitle(for: macro).isEmpty)
        }
    }

    func testFreshInstallProvidesExecutableAppShortcutsAndDefaultScheme() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.macros, allPresets)
        XCTAssertEqual(model.macros.filter { $0.name.hasPrefix("Codex-") }.count, DefaultMacros.codex.count)
        XCTAssertEqual(model.macros.filter { $0.name.hasPrefix("Claude-") }.count, DefaultMacros.claude.count)
        XCTAssertEqual(model.macros.filter { $0.name.hasPrefix("Cursor-") }.count, 35)
        XCTAssertEqual(model.macros.filter { $0.name.hasPrefix("DeepSeek-") }.count, 27)
        XCTAssertEqual(model.macros.filter { $0.name.hasPrefix("WorkBuddy-") }.count, 24)
        XCTAssertEqual(model.macros.filter { $0.name.hasPrefix("OpenCode-") }.count, 59)
        XCTAssertEqual(Set(model.macros.map(\.id)).count, model.macros.count)
        XCTAssertEqual(Set(model.macros.map(\.name)).count, model.macros.count)
        let stepIDs = model.macros.flatMap { $0.steps.map(\.id) }
        XCTAssertEqual(Set(stepIDs).count, stepIDs.count)
        XCTAssertTrue(Set(stepIDs).isDisjoint(with: Set(model.macros.map(\.id))))
        XCTAssertEqual(model.mapping, .defaults(for: model.remoteProfile, macros: model.macros))
        for macro in model.macros {
            let plan = try MacroExecutionPlan(macro, macros: model.macros)
            XCTAssertEqual(plan.events.count, macro.name == "DeepSeek-停止回复（双击 Esc）" ? 2 : 1)
            for event in plan.events {
                XCTAssertEqual(event.mapping.action, .recordedShortcut)
                XCTAssertNotNil(event.mapping.shortcut)
            }
        }
        let newChat = try XCTUnwrap(model.macros.first { $0.name == "Codex-新建会话" })
        let mapping = try XCTUnwrap(newChat.steps.first?.mapping)
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        sender.send(mapping, pressed: true)
        sender.send(mapping, pressed: false)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [0x2D, 0x2D])
        XCTAssertTrue(events[0].flags.contains(.maskCommand))
        XCTAssertFalse(events[1].flags.contains(.maskCommand))
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.macros, model.macros)
    }

    func testClaudeShortcutsUseClaudePrefixAndProduceExpectedEvents() throws {
        XCTAssertEqual(DefaultMacros.claude.count, 39)
        XCTAssertTrue(DefaultMacros.claude.allSatisfy { $0.name.hasPrefix("Claude-") })
        let cases: [(String, Int64, CGEventFlags)] = [
            ("Claude-新建会话", 0x2D, .maskCommand),
            ("Claude-打开侧边聊天", 0x29, .maskCommand),
            ("Claude-关闭当前面板", 0x2A, .maskCommand),
            ("Claude-切换终端面板", 0x32, .maskControl),
            ("Claude-从分屏移除会话", 0x0D, [.maskCommand, .maskControl]),
            ("Claude-停止 Claude 回复", 0x35, []),
        ]
        for (name, keyCode, flags) in cases {
            let macro = try XCTUnwrap(DefaultMacros.claude.first { $0.name == name })
            let plan = try MacroExecutionPlan(macro, macros: DefaultMacros.claude)
            let mapping = try XCTUnwrap(plan.events.first?.mapping)
            var events: [CGEvent] = []
            let sender = SystemEventSender(postEvent: { events.append($0) })
            sender.send(mapping, pressed: true)
            sender.send(mapping, pressed: false)
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp], name)
            XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [keyCode, keyCode], name)
            XCTAssertEqual(events.first?.flags, flags, name)
            XCTAssertEqual(events.last?.flags, [], name)
        }
    }

    func testNewAppShortcutsProduceExpectedKeysAndModifiers() throws {
        let cases: [(String, Int64, CGEventFlags)] = [
            ("Cursor-切换侧边面板（Command+I）", 0x22, .maskCommand),
            ("Cursor-打开模式菜单", 0x2F, .maskCommand),
            ("Cursor-切换语音输入", 0x31, [.maskCommand, .maskShift]),
            ("Cursor-停止生成", 0x33, [.maskCommand, .maskShift]),
            ("Cursor-拒绝全部更改", 0x33, [.maskCommand, .maskShift]),
            ("Cursor-立即发送消息", 0x24, .maskCommand),
            ("Cursor-接受全部更改", 0x24, .maskCommand),
            ("Cursor-循环切换 Agent 模式", 0x30, .maskShift),
            ("Cursor-切换模型", 0x2C, [.maskCommand, .maskAlternate]),
            ("Cursor-接受建议的下一个词", 0x7C, [.maskCommand, .maskSecondaryFn, .maskNumericPad]),
            ("Cursor-打开引用菜单", 0x13, .maskShift),
            ("DeepSeek-重命名会话", 0x05, [.maskCommand, .maskAlternate]),
            ("DeepSeek-分叉会话", 0x03, [.maskCommand, .maskAlternate]),
            ("DeepSeek-归档会话", 0x00, [.maskCommand, .maskShift]),
            ("DeepSeek-切换右侧面板", 0x0B, [.maskCommand, .maskAlternate]),
            ("DeepSeek-分割面板", 0x2A, .maskCommand),
            ("DeepSeek-切换面板全屏", 0x24, [.maskCommand, .maskAlternate]),
            ("DeepSeek-新建终端", 0x32, .maskControl),
            ("DeepSeek-切换忙时发送方式", 0x24, .maskCommand),
            ("DeepSeek-拒绝操作", 0x35, []),
            ("WorkBuddy-新建快速问答", 0x2D, [.maskCommand, .maskShift]),
            ("WorkBuddy-定位当前任务", 0x0E, [.maskCommand, .maskShift]),
            ("WorkBuddy-进入或退出全屏", 0x03, [.maskControl, .maskCommand]),
            ("WorkBuddy-放大内容字号", 0x18, .maskCommand),
            ("WorkBuddy-上一个标签页", 0x30, [.maskControl, .maskShift]),
            ("WorkBuddy-语音录制开关", 0x02, .maskCommand),
            ("WorkBuddy-唤起选择器", 0x13, .maskShift),
            ("OpenCode-新建会话（Command+N）", 0x2D, .maskCommand),
            ("OpenCode-新建会话（Command+T）", 0x11, .maskCommand),
            ("OpenCode-关闭会话标签页", 0x0D, [.maskCommand, .maskAlternate]),
            ("OpenCode-上一个会话", 0x7E, [.maskAlternate, .maskSecondaryFn, .maskNumericPad]),
            ("OpenCode-下一个未读会话", 0x7D, [.maskAlternate, .maskShift, .maskSecondaryFn, .maskNumericPad]),
            ("OpenCode-切换侧边栏", 0x0B, [.maskCommand, .maskShift]),
            ("OpenCode-选择模型", 0x27, .maskCommand),
            ("OpenCode-循环切换模型变体", 0x02, [.maskCommand, .maskShift]),
            ("OpenCode-上一个 Agent", 0x2F, [.maskCommand, .maskShift]),
            ("OpenCode-打开 MCP 菜单", 0x29, .maskCommand),
            ("OpenCode-切换自动批准", 0x00, [.maskCommand, .maskShift]),
            ("OpenCode-聚焦输入框", 0x25, .maskControl),
            ("OpenCode-切换终端", 0x32, .maskControl),
            ("OpenCode-停止回复（Esc）", 0x35, []),
            ("OpenCode-停止回复（Control+G）", 0x05, .maskControl),
            ("OpenCode-切换忙时发送方式", 0x24, .maskCommand),
            ("OpenCode-转到会话标签页5", 0x17, .maskCommand),
            ("OpenCode-转到会话标签页6", 0x16, .maskCommand),
        ]
        for (name, keyCode, flags) in cases {
            let macro = try XCTUnwrap(newPresets.first { $0.name == name })
            let plan = try MacroExecutionPlan(macro, macros: newPresets)
            XCTAssertEqual(plan.events.count, 1, name)
            let mapping = try XCTUnwrap(plan.events.first?.mapping)
            var events: [CGEvent] = []
            let sender = SystemEventSender(postEvent: { events.append($0) })
            sender.send(mapping, pressed: true)
            sender.send(mapping, pressed: false)
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp], name)
            XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [keyCode, keyCode], name)
            XCTAssertEqual(events.first?.flags, flags, name)
            XCTAssertEqual(events.last?.flags, flags.intersection([.maskSecondaryFn, .maskNumericPad]), name)
        }
    }

    func testDeepSeekStopProducesTwoEscapePressesWithinDefaultStopInterval() throws {
        let macro = try XCTUnwrap(DefaultMacros.deepSeek.first { $0.name == "DeepSeek-停止回复（双击 Esc）" })
        let plan = try MacroExecutionPlan(macro, macros: DefaultMacros.deepSeek)
        XCTAssertEqual(plan.events.map(\.offset), [0, 0.1])
        XCTAssertEqual(plan.duration, 0.1)
        var events: [CGEvent] = []
        let sender = SystemEventSender(postEvent: { events.append($0) })
        for event in plan.events {
            sender.send(event.mapping, pressed: true)
            sender.send(event.mapping, pressed: false)
        }
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp, .keyDown, .keyUp])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [0x35, 0x35, 0x35, 0x35])
        XCTAssertTrue(events.allSatisfy { $0.flags.isEmpty })
    }

    func testVersionFourUpgradeAndImportPreserveEditsBindingsAndOlderPresetDeletions() throws {
        var renamed = DefaultMacros.cursor[0]
        renamed.name = "我的 Cursor 动作"
        renamed.steps = [MacroStep(mapping: ButtonMapping(action: .paste), delay: 0.8)]
        let deepSeekCollision = SavedMacro(name: "  dEePsEeK-新建会话  ", steps: [MacroStep(mapping: ButtonMapping(action: .copy))])
        let workBuddyCollision = SavedMacro(name: "  wOrKbUdDy-新建对话  ", steps: [MacroStep(mapping: ButtonMapping(action: .paste))])
        let existing = [renamed, deepSeekCollision, workBuddyCollision]
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .macro, referenceID: renamed.id.uuidString)
        mapping[.buttonB] = ButtonMapping(action: .macro, referenceID: deepSeekCollision.id.uuidString)
        SettingsStorage.save(existing, SettingsKeys.Stored.macros, defaults: defaults)
        defaults.set(4, forKey: SettingsKeys.macroPresetsVersion)

        let model = RemoteDashboardModel(mapping: mapping, defaults: defaults)
        let upgraded = model.macros
        XCTAssertEqual(upgraded.count, newPresets.count)
        XCTAssertEqual(Array(upgraded.prefix(3)), SavedMacro.normalizingNames(in: existing))
        XCTAssertTrue(Set(upgraded.map(\.id)).isDisjoint(with: Set((DefaultMacros.codex + DefaultMacros.claude).map(\.id))))
        XCTAssertEqual(model.mapping, mapping)
        XCTAssertEqual(defaults.integer(forKey: SettingsKeys.macroPresetsVersion), DefaultMacros.version)
        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).macros, upgraded)

        let oldBackup = SettingsBackup(mapping: mapping, profiles: [], macros: existing, phrases: [], macroPresetsVersion: 4)
        try model.applyConfiguration(oldBackup)
        XCTAssertEqual(model.macros, upgraded)
        XCTAssertEqual(model.mapping, mapping)
        for presets in [DefaultMacros.cursor, DefaultMacros.deepSeek, DefaultMacros.workBuddy] {
            let added = try XCTUnwrap(model.macros.first { $0.id == presets[1].id })
            model.deleteMacro(added.id)
        }
        let edited = try XCTUnwrap(model.macros.first { $0.name == "WorkBuddy-停止生成" })
        XCTAssertTrue(model.renameMacro(edited.id, name: "我的停止动作"))
        XCTAssertTrue(model.updateMacroSteps([MacroStep(mapping: ButtonMapping(action: .copy))], for: edited.id))
        let expected = model.macros
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        XCTAssertEqual(backup.macroPresetsVersion, DefaultMacros.version)
        try model.applyConfiguration(backup)
        XCTAssertEqual(model.macros, expected)
        XCTAssertEqual(model.mapping, mapping)
        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).macros, expected)
    }

    func testVersionFiveUpgradeOnlyAddsOpenCodeAndPreservesEditsAndDeletionsAcrossImport() throws {
        var renamed = DefaultMacros.openCode[0]
        renamed.name = "我的 OpenCode 会话"
        renamed.steps = [MacroStep(mapping: ButtonMapping(action: .paste), delay: 0.8)]
        let collision = SavedMacro(name: "  oPeNcOdE-打开设置  ", steps: [MacroStep(mapping: ButtonMapping(action: .copy))])
        let existing = [renamed, collision]
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .macro, referenceID: renamed.id.uuidString)
        mapping[.buttonB] = ButtonMapping(action: .macro, referenceID: collision.id.uuidString)
        SettingsStorage.save(existing, SettingsKeys.Stored.macros, defaults: defaults)
        defaults.set(5, forKey: SettingsKeys.macroPresetsVersion)

        let model = RemoteDashboardModel(mapping: mapping, defaults: defaults)
        let upgraded = model.macros
        XCTAssertEqual(upgraded.count, DefaultMacros.openCode.count)
        XCTAssertEqual(Array(upgraded.prefix(2)), SavedMacro.normalizingNames(in: existing))
        let olderPresets = DefaultMacros.codex + DefaultMacros.claude + DefaultMacros.cursor + DefaultMacros.deepSeek + DefaultMacros.workBuddy
        XCTAssertTrue(Set(upgraded.map(\.id)).isDisjoint(with: Set(olderPresets.map(\.id))))
        XCTAssertEqual(model.mapping, mapping)
        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).macros, upgraded)
        try model.applyConfiguration(SettingsBackup(mapping: mapping, profiles: [], macros: existing, phrases: [], macroPresetsVersion: 5))
        XCTAssertEqual(model.macros, upgraded)
        XCTAssertEqual(model.mapping, mapping)

        let added = try XCTUnwrap(model.macros.first { $0.id == DefaultMacros.openCode[1].id })
        XCTAssertEqual(DefaultMacros.cardTitle(for: added), "新建会话（Command+T）")
        model.deleteMacro(added.id)
        let expected = model.macros
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        XCTAssertEqual(backup.macroPresetsVersion, DefaultMacros.version)
        try model.applyConfiguration(backup)
        XCTAssertEqual(model.macros, expected)
        XCTAssertEqual(model.mapping, mapping)
        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).macros, expected)
    }

    func testVersionTwoUpgradeAndImportAddClaudeWithoutRestoringCodexOrChangingBindings() throws {
        var renamed = DefaultMacros.claude[1]
        renamed.name = "我的 Claude 会话"
        renamed.steps = [MacroStep(mapping: ButtonMapping(action: .paste), delay: 0.8)]
        let sameName = SavedMacro(name: "  cLaUdE-查看快捷键  ", steps: [MacroStep(mapping: ButtonMapping(action: .copy))])
        let existing = [renamed, sameName]
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .macro, referenceID: renamed.id.uuidString)
        SettingsStorage.save(existing, SettingsKeys.Stored.macros, defaults: defaults)
        defaults.set(2, forKey: SettingsKeys.macroPresetsVersion)
        let model = RemoteDashboardModel(mapping: mapping, defaults: defaults)
        let upgraded = model.macros
        XCTAssertEqual(upgraded.count, DefaultMacros.claude.count + newPresets.count)
        XCTAssertEqual(Array(upgraded.prefix(2)), SavedMacro.normalizingNames(in: existing))
        XCTAssertTrue(Set(upgraded.map(\.id)).isDisjoint(with: Set(DefaultMacros.codex.map(\.id))))
        XCTAssertEqual(model.mapping[.buttonA].referenceID, renamed.id.uuidString)
        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).macros, upgraded)

        let oldBackup = SettingsBackup(mapping: mapping, profiles: [], macros: existing, phrases: [], macroPresetsVersion: 2)
        XCTAssertEqual(try model.applyConfiguration(oldBackup), 0)
        XCTAssertEqual(model.macros, upgraded)
        XCTAssertEqual(model.mapping[.buttonA].referenceID, renamed.id.uuidString)
        let added = try XCTUnwrap(model.macros.first { $0.name == "Claude-关闭会话" })
        model.deleteMacro(added.id)
        let newBackup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        XCTAssertEqual(newBackup.macroPresetsVersion, DefaultMacros.version)
        try model.applyConfiguration(newBackup)
        XCTAssertFalse(model.macros.contains { $0.id == added.id })
        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).macros, model.macros)
    }

    func testVersionThreeInstallAddsClaudePresetsWhenOnlyCodexPresetsExist() throws {
        SettingsStorage.save(DefaultMacros.codex, SettingsKeys.Stored.macros, defaults: defaults)
        defaults.set(3, forKey: SettingsKeys.macroPresetsVersion)

        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)

        XCTAssertEqual(model.macros.count, allPresets.count)
        XCTAssertEqual(model.macros.filter { $0.name.hasPrefix("Claude-") }.count, DefaultMacros.claude.count)
        XCTAssertEqual(defaults.integer(forKey: SettingsKeys.macroPresetsVersion), DefaultMacros.version)
    }

    func testUpgradeAndLegacyImportKeepExistingNamesIDsStepsAndReferences() throws {
        let sameName = SavedMacro(name: "  codex-新建会话  ", steps: [MacroStep(mapping: ButtonMapping(action: .copy))])
        var renamed = DefaultMacros.codex[1]
        renamed.name = "自定义独立会话"
        renamed.steps = [MacroStep(mapping: ButtonMapping(action: .paste), delay: 0.8)]
        let existing = [sameName, renamed, SavedMacro(name: "我的动作")]
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .macro, referenceID: sameName.id.uuidString)
        SettingsStorage.save(existing, SettingsKeys.Stored.macros, defaults: defaults)
        let model = RemoteDashboardModel(mapping: mapping, defaults: defaults)
        XCTAssertEqual(model.macros.count, allPresets.count + 1)
        XCTAssertEqual(Array(model.macros.prefix(3)), SavedMacro.normalizingNames(in: existing))
        XCTAssertEqual(model.mapping[.buttonA].referenceID, sameName.id.uuidString)
        // A JSON backup with no initialization field is the legacy format.
        let backup = SettingsBackup(mapping: mapping, profiles: [], macros: existing, phrases: [])
        let imported = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(backup))
        XCTAssertNil(imported.macroPresetsVersion)
        XCTAssertEqual(try model.applyConfiguration(imported), 0)
        XCTAssertEqual(model.macros.count, allPresets.count + 1)
        XCTAssertEqual(Array(model.macros.prefix(3)), SavedMacro.normalizingNames(in: existing))
        XCTAssertEqual(model.mapping[.buttonA].referenceID, sameName.id.uuidString)
    }

    func testEditsAndDeletedPresetsSurviveRestartAndBackupImport() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        let first = try XCTUnwrap(model.macros.first)
        XCTAssertTrue(model.renameMacro(first.id, name: "我的新会话"))
        XCTAssertTrue(model.updateMacroSteps([MacroStep(mapping: ButtonMapping(action: .copy))], for: first.id))
        for macro in model.macros where macro.id != first.id { model.deleteMacro(macro.id) }
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        XCTAssertEqual(backup.macroPresetsVersion, DefaultMacros.version)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.macros, model.macros)
        try restored.applyConfiguration(backup)
        XCTAssertEqual(restored.macros, model.macros)
        restored.deleteMacro(first.id)
        let emptyBackup = restored.configurationBackup()
        try model.applyConfiguration(emptyBackup)
        XCTAssertTrue(model.macros.isEmpty)
        XCTAssertTrue(RemoteDashboardModel(mapping: .defaults, defaults: defaults).macros.isEmpty)
    }

    func testVersionOneUpgradeAddsRecentChatsWithoutRestoringDeletedOriginalPresets() throws {
        var edited = DefaultMacros.codex[0]
        edited.name = "我的新会话"
        edited.steps = [MacroStep(mapping: ButtonMapping(action: .copy))]
        SettingsStorage.save([edited], SettingsKeys.Stored.macros, defaults: defaults)
        defaults.set(1, forKey: SettingsKeys.macroPresetsVersion)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(model.macros.count, 46 + newPresets.count)
        XCTAssertEqual(model.macros.first, edited)
        // Number-row key codes are not consecutive (5 precedes 6 in HIToolbox).
        let keyCodes: [Int64] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16]
        for number in 1...6 {
            let macro = try XCTUnwrap(model.macros.first { $0.name == "Codex-转到最近聊天\(number)" })
            let plan = try MacroExecutionPlan(macro, macros: model.macros)
            XCTAssertEqual(plan.events.count, 1)
            let mapping = try XCTUnwrap(plan.events.first?.mapping)
            XCTAssertEqual(mapping.shortcut?.label, "⌥⌘\(number)")
            var events: [CGEvent] = []
            let sender = SystemEventSender(postEvent: { events.append($0) })
            sender.send(mapping, pressed: true)
            sender.send(mapping, pressed: false)
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
            XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [keyCodes[number - 1], keyCodes[number - 1]])
            XCTAssertEqual(events.first?.flags, [.maskCommand, .maskAlternate])
        }
        let recentChat = try XCTUnwrap(model.macros.first { $0.name == "Codex-转到最近聊天6" })
        model.deleteMacro(recentChat.id)
        let restored = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(restored.macros, model.macros)
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        try restored.applyConfiguration(backup)
        XCTAssertEqual(restored.macros, model.macros)
    }

    func testVersionOneBackupOnlyAddsMissingRecentChatsAndPreservesBindings() throws {
        let existing = SavedMacro(name: " codex-转到最近聊天1 ", steps: [MacroStep(mapping: ButtonMapping(action: .paste))])
        var mapping = RemoteMapping.defaults
        mapping[.buttonA] = ButtonMapping(action: .macro, referenceID: existing.id.uuidString)
        let backup = SettingsBackup(mapping: mapping, profiles: [], macros: [existing], phrases: [], macroPresetsVersion: 1)
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        XCTAssertEqual(try model.applyConfiguration(backup), 0)
        XCTAssertEqual(model.macros.count, 45 + newPresets.count)
        XCTAssertEqual(model.macros.first?.id, existing.id)
        XCTAssertEqual(model.macros.first?.steps, existing.steps)
        XCTAssertEqual(model.mapping[.buttonA].referenceID, existing.id.uuidString)
        XCTAssertEqual(RemoteDashboardModel(mapping: .defaults, defaults: defaults).macros, model.macros)
    }
}
