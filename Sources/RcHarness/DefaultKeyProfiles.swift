import Foundation

extension RemoteMapping {
    static func defaults(for profile: RemoteProfile, macros: [SavedMacro]) -> Self {
        harnessDefaults("codex", for: profile, macros: macros)
    }

    static func chromecastDefaults(macros: [SavedMacro]) -> Self {
        defaults(for: RemoteProfiles.googleG9N9N, macros: macros)
    }

    static func codexDefaults(macros: [SavedMacro], remoteProfile: RemoteProfile = RemoteProfiles.xiaomiRC003) -> Self {
        defaults(for: remoteProfile, macros: macros)
    }

    /// The same physical gestures keep their roles across apps and remote families.
    static func harnessDefaults(_ harnessID: String, for profile: RemoteProfile, macros: [SavedMacro]) -> Self {
        guard let preset = HarnessKeyPreset.forHarness(harnessID) else { return .defaults }
        var mapping = Self.defaults
        mapping[.buttonA, .long] = ButtonMapping(action: .openPhrases)
        mapping[.buttonB, .long] = ButtonMapping(action: .rapidDelete)
        mapping[.home] = ButtonMapping(action: .showDesktop)
        mapping[.home, .double] = ButtonMapping(action: .escape)
        let navigation: [ControllerInput] = [.dpadUp, .dpadRight, .dpadDown, .dpadLeft, .rightShoulder, .leftShoulder]
        let navigationActions = profile.adapter == .chromecast
            ? preset.chromecastNavigation ?? preset.navigation : preset.navigation
        for (input, name) in zip(navigation, navigationActions) {
            mapping[input, .double] = preset.action(named: name, macros: macros)
        }
        mapping[.buttonA, .double] = preset.action(named: preset.newConversation, macros: macros)
        let menu: ControllerInput = profile.adapter == .chromecast ? .youtube : .menu
        mapping[menu] = preset.action(named: preset.menuSingle, macros: macros)
        let menuDouble = profile.adapter == .chromecast
            ? preset.chromecastMenuDouble ?? preset.menuDouble : preset.menuDouble
        mapping[menu, .double] = preset.action(named: menuDouble, macros: macros)
        if profile.adapter == .chromecast {
            mapping[.mute] = ButtonMapping(action: .disabled)
            mapping[.netflix] = ButtonMapping(action: .disabled)
            mapping[.mute, .double] = preset.action(named: preset.extraLeft, macros: macros)
            mapping[.netflix, .double] = preset.action(named: preset.extraRight, macros: macros)
        }
        return mapping
    }
}

private struct HarnessKeyPreset {
    let prefix: String
    let definitions: [SavedMacro]
    let newConversation: String
    /// Up, right, down, left, volume up, volume down.
    let navigation: [String]
    let menuSingle: String
    let menuDouble: String
    let extraLeft: String
    let extraRight: String
    // Chromecast has separate session-navigation keys; use its other slots for app features.
    var chromecastNavigation: [String]? = nil
    var chromecastMenuDouble: String? = nil

    func action(named action: String, macros: [SavedMacro]) -> ButtonMapping {
        let name = prefix + "-" + action
        let preset = definitions.first { $0.name == name }
        // Stable IDs retain renamed presets; deleted presets stay disabled.
        let macro = macros.first { $0.id == preset?.id }
            ?? macros.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(name) == .orderedSame }
        return macro.map { ButtonMapping(action: .macro, referenceID: $0.id.uuidString) }
            ?? ButtonMapping(action: .disabled)
    }

    static func forHarness(_ id: String) -> Self? {
        switch id {
        case "codex":
            return Self(prefix: "Codex", definitions: DefaultMacros.codex, newConversation: "新建会话",
                navigation: (1...6).map { "转到最近聊天\($0)" },
                menuSingle: "切换会话与标签页", menuDouble: "新建独立会话",
                extraLeft: "上一个会话", extraRight: "下一个会话")
        case "claude":
            return Self(prefix: "Claude", definitions: DefaultMacros.claude, newConversation: "新建会话",
                navigation: (1...6).map { "选择环境\($0)" },
                menuSingle: "切换会话（Control+Tab）", menuDouble: "新建环境",
                extraLeft: "上一个会话", extraRight: "下一个会话",
                chromecastNavigation: ["循环视图模式", "切换浏览器面板", "切换终端面板", "切换差异面板", "打开模型菜单", "打开努力程度菜单"],
                chromecastMenuDouble: "打开侧边聊天")
        case "cursor":
            return Self(prefix: "Cursor", definitions: DefaultMacros.cursor, newConversation: "新建会话（Command+N）",
                navigation: ["切换侧边面板（Command+I）", "下一个会话", "打开命令面板", "上一个会话",
                             "循环切换 AI 模型", "循环切换 Agent 模式"],
                menuSingle: "切换 Agent 布局", menuDouble: "新建会话标签页",
                extraLeft: "上一个会话", extraRight: "下一个会话",
                chromecastNavigation: ["切换侧边面板（Command+I）", "切换到下一条消息", "打开命令面板", "打开模式菜单",
                                      "循环切换 AI 模型", "循环切换 Agent 模式"])
        case "deepseek":
            return Self(prefix: "DeepSeek", definitions: DefaultMacros.deepSeek, newConversation: "新建会话",
                navigation: ["搜索会话", "切换右侧面板", "浏览工作区文件", "切换左侧栏", "放大内容字号", "缩小内容字号"],
                menuSingle: "搜索会话", menuDouble: "分叉会话",
                extraLeft: "分割面板", extraRight: "切换面板全屏",
                chromecastNavigation: ["添加工作区", "切换右侧面板", "浏览工作区文件", "切换左侧栏", "放大内容字号", "缩小内容字号"])
        case "workbuddy":
            return Self(prefix: "WorkBuddy", definitions: DefaultMacros.workBuddy, newConversation: "新建对话",
                navigation: ["定位当前任务", "下一个任务", "全局搜索", "上一个任务", "放大内容字号", "缩小内容字号"],
                menuSingle: "切换左侧栏", menuDouble: "新建快速问答",
                extraLeft: "上一个任务", extraRight: "下一个任务",
                chromecastNavigation: ["定位当前任务", "下一个标签页", "全局搜索", "上一个标签页", "放大内容字号", "缩小内容字号"])
        case "opencode":
            return Self(prefix: "OpenCode", definitions: DefaultMacros.openCode, newConversation: "新建会话（Command+N）",
                navigation: (1...6).map { "转到会话标签页\($0)" },
                menuSingle: "切换侧边栏", menuDouble: "新建窗口",
                extraLeft: "上一个会话", extraRight: "下一个会话")
        default:
            return nil
        }
    }
}
