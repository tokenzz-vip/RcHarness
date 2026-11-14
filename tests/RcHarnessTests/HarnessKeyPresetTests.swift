import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import RcHarness

@MainActor
final class HarnessKeyPresetTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "RcHarness.HarnessKeyPresetTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testEachHarnessUsesItsOwnExecutableShortcutsAcrossAllRemotesAndReset() throws {
        // Up, right, down, left, volume up, volume down; then OK, menu single/double and Google extras.
        let cases: [(String, String, [String])] = [
            ("claude", "Claude", ["选择环境1", "选择环境2", "选择环境3", "选择环境4", "选择环境5", "选择环境6",
                                  "新建会话", "切换会话（Control+Tab）", "新建环境", "上一个会话", "下一个会话"]),
            ("cursor", "Cursor", ["切换侧边面板（Command+I）", "下一个会话", "打开命令面板", "上一个会话",
                                  "循环切换 AI 模型", "循环切换 Agent 模式", "新建会话（Command+N）", "切换 Agent 布局",
                                  "新建会话标签页", "上一个会话", "下一个会话"]),
            ("deepseek", "DeepSeek", ["搜索会话", "切换右侧面板", "浏览工作区文件", "切换左侧栏", "放大内容字号", "缩小内容字号",
                                      "新建会话", "搜索会话", "分叉会话", "分割面板", "切换面板全屏"]),
            ("workbuddy", "WorkBuddy", ["定位当前任务", "下一个任务", "全局搜索", "上一个任务", "放大内容字号", "缩小内容字号",
                                        "新建对话", "切换左侧栏", "新建快速问答", "上一个任务", "下一个任务"]),
            ("opencode", "OpenCode", ["转到会话标签页1", "转到会话标签页2", "转到会话标签页3", "转到会话标签页4", "转到会话标签页5", "转到会话标签页6",
                                      "新建会话（Command+N）", "切换侧边栏", "新建窗口", "上一个会话", "下一个会话"]),
        ]
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for remote in RemoteProfiles.all {
            model.selectRemoteProfile(remote.id)
            let globals = model.globalButtons
            for (id, prefix, baseNames) in cases {
                var names = baseNames
                if remote.adapter == .chromecast {
                    switch id {
                    case "claude":
                        names.replaceSubrange(0..<6, with: ["循环视图模式", "切换浏览器面板", "切换终端面板", "切换差异面板", "打开模型菜单", "打开努力程度菜单"])
                        names[8] = "打开侧边聊天"
                    case "cursor":
                        names[1] = "切换到下一条消息"
                        names[3] = "打开模式菜单"
                    case "deepseek": names[0] = "添加工作区"
                    case "workbuddy":
                        names[1] = "下一个标签页"
                        names[3] = "上一个标签页"
                    default: break
                    }
                }
                model.activateHarness(id)
                let original = model.mapping
                let menu: ControllerInput = remote.adapter == .chromecast ? .youtube : .menu
                var gestures: [(ControllerInput, ButtonTrigger)] = [
                    (.dpadUp, .double), (.dpadRight, .double), (.dpadDown, .double), (.dpadLeft, .double),
                    (.rightShoulder, .double), (.leftShoulder, .double), (.buttonA, .double), (menu, .single), (menu, .double),
                ]
                if remote.adapter == .chromecast { gestures += [(.mute, .double), (.netflix, .double)] }
                for ((input, trigger), name) in zip(gestures, names) {
                    let button = model.effectiveMapping[input, trigger]
                    XCTAssertEqual(button.action, .macro)
                    let macro = try XCTUnwrap(model.macros.first { $0.id.uuidString == button.referenceID })
                    XCTAssertEqual(macro.name, prefix + "-" + name)
                    XCTAssertNoThrow(try MacroExecutionPlan(macro, macros: model.macros))
                    XCTAssertTrue(macro.tagIDs.contains(id))
                }
                XCTAssertEqual(model.effectiveMapping[.home].action, .showDesktop)
                XCTAssertEqual(model.effectiveMapping[.home, .double].action, .escape)
                XCTAssertEqual(model.effectiveMapping[.buttonA].action, .enter)
                XCTAssertEqual(model.effectiveMapping[.buttonA, .long].action, .openPhrases)
                XCTAssertEqual(model.effectiveMapping[.buttonB, .long].action, .rapidDelete)
                XCTAssertEqual(model.effectiveMapping[.rightShoulder].action, .volumeUp)
                XCTAssertEqual(model.effectiveMapping[.leftShoulder].action, .volumeDown)
                model.update(ButtonMapping(action: .copy), for: .dpadUp, trigger: .single)
                model.resetMapping()
                XCTAssertEqual(model.mapping, original, id)
                XCTAssertEqual(model.globalButtons, globals)
                XCTAssertEqual(model.danglingReferenceCount(), 0)
            }
        }
        let backup = try JSONDecoder().decode(SettingsBackup.self, from: JSONEncoder().encode(model.configurationBackup()))
        try model.applyConfiguration(backup)
        let restarted = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for restored in [model, restarted] {
            for remote in RemoteProfiles.all {
                let expected = try XCTUnwrap(backup.remoteKeyConfigurations?[remote.id])
                let actual = try XCTUnwrap(restored.configurationBackup().remoteKeyConfigurations?[remote.id])
                XCTAssertEqual(actual.profiles, expected.profiles)
                XCTAssertEqual(actual.harnessProfileIDs, expected.harnessProfileIDs)
                XCTAssertEqual(actual.initializedHarnessIDs, expected.initializedHarnessIDs)
                XCTAssertEqual(actual.globalButtons, expected.globalButtons)
            }
        }
    }

    func testGoogleOverridesMatchActualMacShortcutsAndKeepCodexGlobalRoles() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults,
                                         remoteProfile: RemoteProfiles.googleG9N9N)
        let globals = model.globalButtons
        let cases: [(String, ControllerInput, Int, CGEventFlags)] = [
            ("claude", .dpadUp, kVK_ANSI_O, .maskControl),
            ("claude", .dpadRight, kVK_ANSI_B, [.maskCommand, .maskShift]),
            ("claude", .dpadDown, kVK_ANSI_Grave, .maskControl),
            ("claude", .dpadLeft, kVK_ANSI_D, [.maskCommand, .maskShift]),
            ("claude", .rightShoulder, kVK_ANSI_I, [.maskCommand, .maskShift]),
            ("claude", .leftShoulder, kVK_ANSI_E, [.maskCommand, .maskShift]),
            ("claude", .youtube, kVK_ANSI_Semicolon, .maskCommand),
            ("claude", .mute, kVK_ANSI_LeftBracket, [.maskCommand, .maskShift]),
            ("claude", .netflix, kVK_ANSI_RightBracket, [.maskCommand, .maskShift]),
            ("cursor", .dpadRight, kVK_Tab, []),
            ("cursor", .dpadLeft, kVK_ANSI_Period, .maskCommand),
            ("cursor", .mute, kVK_ANSI_LeftBracket, .maskCommand),
            ("cursor", .netflix, kVK_ANSI_RightBracket, .maskCommand),
            ("deepseek", .dpadUp, kVK_ANSI_O, .maskCommand),
            ("workbuddy", .dpadRight, kVK_Tab, .maskControl),
            ("workbuddy", .dpadLeft, kVK_Tab, [.maskControl, .maskShift]),
            ("workbuddy", .mute, kVK_ANSI_LeftBracket, .maskCommand),
            ("workbuddy", .netflix, kVK_ANSI_RightBracket, .maskCommand),
            ("opencode", .dpadUp, kVK_ANSI_1, .maskCommand),
            ("opencode", .leftShoulder, kVK_ANSI_6, .maskCommand),
            ("opencode", .mute, kVK_UpArrow, .maskAlternate),
            ("opencode", .netflix, kVK_DownArrow, .maskAlternate),
        ]
        for (id, input, key, modifiers) in cases {
            model.activateHarness(id)
            let reference = model.effectiveMapping[input, .double].referenceID
            let macro = try XCTUnwrap(model.macros.first { $0.id.uuidString == reference })
            let shortcut = try XCTUnwrap(MacroExecutionPlan(macro, macros: model.macros).events.first?.mapping.shortcut)
            XCTAssertEqual(shortcut.keyCode, UInt16(key), id)
            XCTAssertEqual(shortcut.modifiers, modifiers.rawValue, id)
            XCTAssertEqual(model.globalButtons, globals)
            XCTAssertEqual(model.effectiveMapping[.power].action, .openHarnessSwitcher)
            XCTAssertEqual(model.effectiveMapping[.power, .double].action, .disabled)
            XCTAssertEqual(model.effectiveMapping[.power, .long].action, .switchToNativeMode)
            XCTAssertEqual(model.effectiveMapping[.inputSource].action, .switchApplications)
            XCTAssertEqual(model.effectiveMapping[.inputSource, .double].action, .showAllWindows)
            XCTAssertEqual(model.effectiveMapping[.inputSource, .long].action, .showDesktop)
            XCTAssertEqual(model.effectiveMapping[.options].shortcut, globals.voiceTapShortcut)
            XCTAssertEqual(model.effectiveMapping[.mute].action, .disabled)
            XCTAssertEqual(model.effectiveMapping[.netflix].action, .disabled)
        }
    }

    func testRenamedDeletedAndSameNameReplacementShortcutsAreRespectedForEveryHarness() throws {
        let model = RemoteDashboardModel(mapping: .defaults, defaults: defaults)
        for remote in RemoteProfiles.all {
            for harness in HarnessConfiguration.defaults {
                let original = harness.defaultMapping(macros: model.macros, remoteProfile: remote)
                let newChat = try XCTUnwrap(model.macros.first { $0.id.uuidString == original[.buttonA, .double].referenceID })
                var macros = model.macros
                macros[try XCTUnwrap(macros.firstIndex { $0.id == newChat.id })].name = "重命名后的动作"
                XCTAssertEqual(harness.defaultMapping(macros: macros, remoteProfile: remote)[.buttonA, .double].referenceID,
                               newChat.id.uuidString)
                macros.removeAll { $0.id == newChat.id }
                XCTAssertEqual(harness.defaultMapping(macros: macros, remoteProfile: remote)[.buttonA, .double].action, .disabled)
                let replacement = SavedMacro(name: newChat.name.lowercased(), steps: newChat.steps)
                macros.append(replacement)
                XCTAssertEqual(harness.defaultMapping(macros: macros, remoteProfile: remote)[.buttonA, .double].referenceID,
                               replacement.id.uuidString)
            }
        }
    }
}
