import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum DefaultMacros {
    // Each release adds only its new presets, preserving deletions from older sets.
    static let version = 5

    // macOS defaults: https://learn.chatgpt.com/docs/reference/commands
    // IDs stay fixed so importing an older backup can recognize renamed presets.
    private static let originalCodex: [SavedMacro] = [
        shortcut(1, "新建会话", kVK_ANSI_N, .maskCommand, "⌘N"),
        shortcut(2, "新建独立会话", kVK_ANSI_O, [.maskCommand, .maskAlternate], "⌥⌘O"),
        shortcut(3, "归档会话", kVK_ANSI_A, [.maskCommand, .maskShift], "⇧⌘A"),
        shortcut(4, "标记未读", kVK_ANSI_U, [.maskCommand, .maskShift], "⇧⌘U"),
        shortcut(5, "置顶或取消置顶", kVK_ANSI_P, [.maskCommand, .maskAlternate], "⌥⌘P"),
        shortcut(6, "重命名会话", kVK_ANSI_R, [.maskCommand, .maskAlternate], "⌥⌘R"),
        shortcut(7, "打开侧边会话", kVK_ANSI_S, [.maskCommand, .maskAlternate], "⌥⌘S"),
        shortcut(8, "会话内查找", kVK_ANSI_F, .maskCommand, "⌘F"),
        shortcut(9, "上一个会话", kVK_LeftArrow, [.maskCommand, .maskAlternate], "⌥⌘←"),
        shortcut(10, "下一个会话", kVK_RightArrow, [.maskCommand, .maskAlternate], "⌥⌘→"),
        shortcut(11, "打开命令菜单", kVK_ANSI_K, .maskCommand, "⌘K"),
        shortcut(12, "打开设置", kVK_ANSI_Comma, .maskCommand, "⌘,"),
        shortcut(13, "查看快捷键", kVK_ANSI_Slash, .maskCommand, "⌘/"),
        shortcut(14, "切换侧边栏", kVK_ANSI_B, .maskCommand, "⌘B"),
        shortcut(15, "切换底部面板", kVK_ANSI_J, .maskCommand, "⌘J"),
        shortcut(16, "切换终端", kVK_ANSI_Grave, .maskControl, "⌃`"),
        shortcut(17, "搜索文件", kVK_ANSI_P, .maskCommand, "⌘P"),
        shortcut(18, "切换文件树", kVK_ANSI_E, [.maskCommand, .maskShift], "⇧⌘E"),
        shortcut(19, "打开代码审查", kVK_ANSI_G, [.maskControl, .maskShift], "⌃⇧G"),
        shortcut(20, "切换会话与标签页", kVK_ANSI_B, [.maskCommand, .maskAlternate], "⌥⌘B"),
    ]

    private static let recentCodexChats: [SavedMacro] = [
        shortcut(21, "转到最近聊天1", kVK_ANSI_1, [.maskCommand, .maskAlternate], "⌥⌘1"),
        shortcut(22, "转到最近聊天2", kVK_ANSI_2, [.maskCommand, .maskAlternate], "⌥⌘2"),
        shortcut(23, "转到最近聊天3", kVK_ANSI_3, [.maskCommand, .maskAlternate], "⌥⌘3"),
        shortcut(24, "转到最近聊天4", kVK_ANSI_4, [.maskCommand, .maskAlternate], "⌥⌘4"),
        shortcut(25, "转到最近聊天5", kVK_ANSI_5, [.maskCommand, .maskAlternate], "⌥⌘5"),
        shortcut(26, "转到最近聊天6", kVK_ANSI_6, [.maskCommand, .maskAlternate], "⌥⌘6"),
    ]

    static let codex = originalCodex + recentCodexChats

    // Claude Code desktop shortcuts: https://code.claude.com/docs/en/desktop#keyboard-shortcuts
    // Keep the ranges expanded into individual actions so they can be bound to
    // different remote buttons and edited independently.
    static let claude: [SavedMacro] = [
        claudeShortcut(1, "查看快捷键", kVK_ANSI_Slash, .maskCommand, "⌘/"),
        claudeShortcut(2, "新建会话", kVK_ANSI_N, .maskCommand, "⌘N"),
        claudeShortcut(3, "选择环境1", kVK_ANSI_1, [.maskCommand, .maskAlternate], "⌥⌘1"),
        claudeShortcut(4, "选择环境2", kVK_ANSI_2, [.maskCommand, .maskAlternate], "⌥⌘2"),
        claudeShortcut(5, "选择环境3", kVK_ANSI_3, [.maskCommand, .maskAlternate], "⌥⌘3"),
        claudeShortcut(6, "选择环境4", kVK_ANSI_4, [.maskCommand, .maskAlternate], "⌥⌘4"),
        claudeShortcut(7, "选择环境5", kVK_ANSI_5, [.maskCommand, .maskAlternate], "⌥⌘5"),
        claudeShortcut(8, "选择环境6", kVK_ANSI_6, [.maskCommand, .maskAlternate], "⌥⌘6"),
        claudeShortcut(9, "选择环境7", kVK_ANSI_7, [.maskCommand, .maskAlternate], "⌥⌘7"),
        claudeShortcut(10, "选择环境8", kVK_ANSI_8, [.maskCommand, .maskAlternate], "⌥⌘8"),
        claudeShortcut(11, "选择环境9", kVK_ANSI_9, [.maskCommand, .maskAlternate], "⌥⌘9"),
        claudeShortcut(12, "新建环境", kVK_ANSI_0, [.maskCommand, .maskAlternate], "⌥⌘0"),
        claudeShortcut(13, "关闭会话", kVK_ANSI_W, .maskCommand, "⌘W"),
        claudeShortcut(14, "切换会话（Control+Tab）", kVK_Tab, .maskControl, "⌃Tab"),
        claudeShortcut(15, "切换会话（Control+Shift+Tab）", kVK_Tab, [.maskControl, .maskShift], "⌃⇧Tab"),
        claudeShortcut(16, "下一个会话", kVK_ANSI_RightBracket, [.maskCommand, .maskShift], "⇧⌘]"),
        claudeShortcut(17, "上一个会话", kVK_ANSI_LeftBracket, [.maskCommand, .maskShift], "⇧⌘["),
        claudeShortcut(18, "停止 Claude 回复", kVK_Escape, [], "Esc"),
        claudeShortcut(19, "接受建议提示", kVK_Tab, [], "Tab"),
        claudeShortcut(20, "切换差异面板", kVK_ANSI_D, [.maskCommand, .maskShift], "⇧⌘D"),
        claudeShortcut(21, "切换浏览器面板", kVK_ANSI_B, [.maskCommand, .maskShift], "⇧⌘B"),
        claudeShortcut(22, "浏览器选择元素", kVK_ANSI_S, [.maskCommand, .maskShift], "⇧⌘S"),
        claudeShortcut(23, "切换终端面板", kVK_ANSI_Grave, .maskControl, "⌃`"),
        claudeShortcut(24, "关闭当前面板", kVK_ANSI_Backslash, .maskCommand, "⌘\\"),
        claudeShortcut(25, "从分屏移除会话", kVK_ANSI_W, [.maskCommand, .maskControl], "⌃⌘W"),
        claudeShortcut(26, "打开侧边聊天", kVK_ANSI_Semicolon, .maskCommand, "⌘;"),
        claudeShortcut(27, "循环视图模式", kVK_ANSI_O, .maskControl, "⌃O"),
        claudeShortcut(28, "打开权限模式菜单", kVK_ANSI_M, [.maskCommand, .maskShift], "⇧⌘M"),
        claudeShortcut(29, "打开模型菜单", kVK_ANSI_I, [.maskCommand, .maskShift], "⇧⌘I"),
        claudeShortcut(30, "打开努力程度菜单", kVK_ANSI_E, [.maskCommand, .maskShift], "⇧⌘E"),
        claudeShortcut(31, "菜单选择1", kVK_ANSI_1, [], "1"),
        claudeShortcut(32, "菜单选择2", kVK_ANSI_2, [], "2"),
        claudeShortcut(33, "菜单选择3", kVK_ANSI_3, [], "3"),
        claudeShortcut(34, "菜单选择4", kVK_ANSI_4, [], "4"),
        claudeShortcut(35, "菜单选择5", kVK_ANSI_5, [], "5"),
        claudeShortcut(36, "菜单选择6", kVK_ANSI_6, [], "6"),
        claudeShortcut(37, "菜单选择7", kVK_ANSI_7, [], "7"),
        claudeShortcut(38, "菜单选择8", kVK_ANSI_8, [], "8"),
        claudeShortcut(39, "菜单选择9", kVK_ANSI_9, [], "9"),
    ]

    // macOS defaults: https://cursor.com/docs/reference/keyboard-shortcuts
    // Context-dependent commands stay separate even when they share a binding.
    static let cursor: [SavedMacro] = [
        cursorShortcut(1, "切换侧边面板（Command+I）", kVK_ANSI_I, .maskCommand, "⌘I"),
        cursorShortcut(2, "切换侧边面板（Command+L）", kVK_ANSI_L, .maskCommand, "⌘L"),
        cursorShortcut(3, "切换侧边面板（Command+K）", kVK_ANSI_K, .maskCommand, "⌘K"),
        cursorShortcut(4, "切换 Agent 布局", kVK_ANSI_E, .maskCommand, "⌘E"),
        cursorShortcut(5, "打开模式菜单", kVK_ANSI_Period, .maskCommand, "⌘."),
        cursorShortcut(6, "循环切换 AI 模型", kVK_ANSI_Slash, .maskCommand, "⌘/"),
        cursorShortcut(7, "打开 Cursor 设置", kVK_ANSI_J, [.maskCommand, .maskShift], "⇧⌘J"),
        cursorShortcut(8, "切换语音输入", kVK_Space, [.maskCommand, .maskShift], "⇧⌘Space"),
        cursorShortcut(9, "打开通用设置", kVK_ANSI_Comma, .maskCommand, "⌘,"),
        cursorShortcut(10, "打开命令面板", kVK_ANSI_P, [.maskCommand, .maskShift], "⇧⌘P"),
        cursorShortcut(11, "将消息加入队列", kVK_Return, [], "Enter"),
        cursorShortcut(12, "立即发送消息", kVK_Return, .maskCommand, "⌘Enter"),
        cursorShortcut(13, "停止生成", kVK_Delete, [.maskCommand, .maskShift], "⇧⌘Backspace"),
        cursorShortcut(14, "添加选中代码到上下文", kVK_ANSI_L, [.maskCommand, .maskShift], "⇧⌘L"),
        cursorShortcut(15, "添加剪贴板到上下文", kVK_ANSI_V, .maskCommand, "⌘V"),
        cursorShortcut(16, "添加剪贴板到输入框", kVK_ANSI_V, [.maskCommand, .maskShift], "⇧⌘V"),
        cursorShortcut(17, "接受全部更改", kVK_Return, .maskCommand, "⌘Enter"),
        cursorShortcut(18, "拒绝全部更改", kVK_Delete, [.maskCommand, .maskShift], "⇧⌘Backspace"),
        cursorShortcut(19, "切换到下一条消息", kVK_Tab, [], "Tab"),
        cursorShortcut(20, "循环切换 Agent 模式", kVK_Tab, .maskShift, "⇧Tab"),
        cursorShortcut(21, "切换模型", kVK_ANSI_Slash, [.maskCommand, .maskAlternate], "⌥⌘/"),
        cursorShortcut(22, "新建会话（Command+N）", kVK_ANSI_N, .maskCommand, "⌘N"),
        cursorShortcut(23, "新建会话（Command+R）", kVK_ANSI_R, .maskCommand, "⌘R"),
        cursorShortcut(24, "新建会话标签页", kVK_ANSI_T, .maskCommand, "⌘T"),
        cursorShortcut(25, "上一个会话", kVK_ANSI_LeftBracket, .maskCommand, "⌘["),
        cursorShortcut(26, "下一个会话", kVK_ANSI_RightBracket, .maskCommand, "⌘]"),
        cursorShortcut(27, "关闭会话", kVK_ANSI_W, .maskCommand, "⌘W"),
        cursorShortcut(28, "取消输入框焦点", kVK_Escape, [], "Esc"),
        cursorShortcut(29, "打开引用菜单", kVK_ANSI_2, .maskShift, "⇧2（@）"),
        cursorShortcut(30, "打开快捷命令", kVK_ANSI_Slash, [], "/"),
        cursorShortcut(31, "添加选中代码到新会话（Command+L）", kVK_ANSI_L, .maskCommand, "⌘L"),
        cursorShortcut(32, "添加选中代码到新会话（Command+K）", kVK_ANSI_K, .maskCommand, "⌘K"),
        cursorShortcut(33, "接受建议的下一个词", kVK_RightArrow, .maskCommand, "⌘→"),
        cursorShortcut(34, "在会话中搜索代码库", kVK_Return, .maskCommand, "⌘Enter"),
        cursorShortcut(35, "接受补全建议", kVK_Tab, [], "Tab"),
    ]

    // DeepSeek Harness macOS Desktop defaults, verified against the bundled
    // @deepseek-ai/dsh-client-* command registrations (not the Web defaults).
    // https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/client
    static let deepSeek: [SavedMacro] = [
        deepSeekShortcut(1, "新建会话", kVK_ANSI_N, .maskCommand, "⌘N"),
        deepSeekShortcut(2, "搜索会话", kVK_ANSI_K, .maskCommand, "⌘K"),
        deepSeekShortcut(3, "添加工作区", kVK_ANSI_O, .maskCommand, "⌘O"),
        deepSeekShortcut(4, "重命名会话", kVK_ANSI_G, [.maskCommand, .maskAlternate], "⌥⌘G"),
        deepSeekShortcut(5, "分叉会话", kVK_ANSI_F, [.maskCommand, .maskAlternate], "⌥⌘F"),
        deepSeekShortcut(6, "归档会话", kVK_ANSI_A, [.maskCommand, .maskShift], "⇧⌘A"),
        deepSeekShortcut(7, "切换左侧栏", kVK_ANSI_B, .maskCommand, "⌘B"),
        deepSeekShortcut(8, "切换右侧面板", kVK_ANSI_B, [.maskCommand, .maskAlternate], "⌥⌘B"),
        deepSeekShortcut(9, "分割面板", kVK_ANSI_Backslash, .maskCommand, "⌘\\"),
        deepSeekShortcut(10, "切换面板全屏", kVK_Return, [.maskCommand, .maskAlternate], "⌥⌘Enter"),
        deepSeekShortcut(11, "关闭当前页面或窗口", kVK_ANSI_W, .maskCommand, "⌘W"),
        deepSeekShortcut(12, "刷新当前页面", kVK_ANSI_R, .maskCommand, "⌘R"),
        deepSeekShortcut(13, "浏览工作区文件", kVK_ANSI_P, .maskCommand, "⌘P"),
        deepSeekShortcut(14, "新建浏览器页面", kVK_ANSI_T, .maskCommand, "⌘T"),
        deepSeekShortcut(15, "新建终端", kVK_ANSI_Grave, .maskControl, "⌃`"),
        deepSeekShortcut(16, "打开设置", kVK_ANSI_Comma, .maskCommand, "⌘,"),
        deepSeekShortcut(17, "查看快捷键", kVK_ANSI_Slash, .maskCommand, "⌘/"),
        deepSeekShortcut(18, "发送消息（按忙时设置）", kVK_Return, [], "Enter"),
        deepSeekShortcut(19, "切换忙时发送方式", kVK_Return, .maskCommand, "⌘Enter"),
        deepSeekShortcut(20, "输入时换行", kVK_Return, .maskShift, "⇧Enter"),
        deepSeekShortcut(21, "打开斜杠命令", kVK_ANSI_Slash, [], "/"),
        deepSeekShortcut(22, "打开引用菜单", kVK_ANSI_2, .maskShift, "⇧2（@）"),
        deepSeekStop,
        deepSeekShortcut(25, "批准操作", kVK_Return, [], "Enter"),
        deepSeekShortcut(26, "拒绝操作", kVK_Escape, [], "Esc"),
        deepSeekShortcut(27, "放大内容字号", kVK_ANSI_Equal, .maskCommand, "⌘="),
        deepSeekShortcut(28, "缩小内容字号", kVK_ANSI_Minus, .maskCommand, "⌘-"),
    ]

    private static let deepSeekStop: SavedMacro = {
        var macro = deepSeekShortcut(23, "停止回复（双击 Esc）", kVK_Escape, [], "Esc")
        macro.steps[0].delay = 0.1
        // Reserve 24 for the second press so both step IDs remain stable.
        macro.steps += deepSeekShortcut(24, "", kVK_Escape, [], "Esc").steps
        return macro
    }()

    // WorkBuddy's built-in keyboard shortcut catalog, verified in the macOS app.
    // https://www.workbuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Setting
    // Modifier-only gestures and the global show/hide shortcut are not app actions.
    static let workBuddy: [SavedMacro] = [
        workBuddyShortcut(1, "新建对话", kVK_ANSI_N, .maskCommand, "⌘N"),
        workBuddyShortcut(2, "新建快速问答", kVK_ANSI_N, [.maskCommand, .maskShift], "⇧⌘N"),
        workBuddyShortcut(3, "全局搜索", kVK_ANSI_K, .maskCommand, "⌘K"),
        workBuddyShortcut(4, "打开设置", kVK_ANSI_Comma, .maskCommand, "⌘,"),
        workBuddyShortcut(5, "对话内搜索", kVK_ANSI_F, .maskCommand, "⌘F"),
        workBuddyShortcut(6, "发送消息", kVK_Return, [], "Enter"),
        workBuddyShortcut(7, "输入时换行", kVK_Return, .maskShift, "⇧Enter"),
        workBuddyShortcut(8, "停止生成", kVK_Escape, [], "Esc"),
        workBuddyShortcut(9, "上一个任务", kVK_ANSI_LeftBracket, .maskCommand, "⌘["),
        workBuddyShortcut(10, "下一个任务", kVK_ANSI_RightBracket, .maskCommand, "⌘]"),
        workBuddyShortcut(11, "定位当前任务", kVK_ANSI_E, [.maskCommand, .maskShift], "⇧⌘E"),
        workBuddyShortcut(12, "切换左侧栏", kVK_ANSI_B, .maskCommand, "⌘B"),
        workBuddyShortcut(13, "切换右侧面板", kVK_ANSI_B, [.maskCommand, .maskShift], "⇧⌘B"),
        workBuddyShortcut(14, "进入或退出全屏", kVK_ANSI_F, [.maskControl, .maskCommand], "⌃⌘F"),
        workBuddyShortcut(15, "放大内容字号", kVK_ANSI_Equal, .maskCommand, "⌘="),
        workBuddyShortcut(16, "缩小内容字号", kVK_ANSI_Minus, .maskCommand, "⌘-"),
        workBuddyShortcut(17, "重置内容字号", kVK_ANSI_0, .maskCommand, "⌘0"),
        workBuddyShortcut(18, "唤起选择器", kVK_ANSI_2, .maskShift, "⇧2（@）"),
        workBuddyShortcut(19, "唤起斜杠命令", kVK_ANSI_Slash, [], "/"),
        workBuddyShortcut(20, "新建标签页", kVK_ANSI_T, .maskCommand, "⌘T"),
        workBuddyShortcut(21, "关闭标签页", kVK_ANSI_W, .maskCommand, "⌘W"),
        workBuddyShortcut(22, "下一个标签页", kVK_Tab, .maskControl, "⌃Tab"),
        workBuddyShortcut(23, "上一个标签页", kVK_Tab, [.maskControl, .maskShift], "⌃⇧Tab"),
        workBuddyShortcut(24, "语音录制开关", kVK_ANSI_D, .maskCommand, "⌘D"),
    ]

    static func addingMissing(to macros: [SavedMacro], since version: Int) -> [SavedMacro] {
        let ids = Set(macros.map(\.id))
        let names = Set(macros.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let candidates = (version < 1 ? originalCodex : [])
            + (version < 2 ? recentCodexChats : [])
            + (version < 4 ? claude : [])
            + (version < 5 ? cursor + deepSeek + workBuddy : [])
        return macros + candidates.filter { !ids.contains($0.id) && !names.contains($0.name.lowercased()) }
    }

    private static func claudeShortcut(_ number: Int, _ name: String, _ key: Int, _ flags: CGEventFlags, _ label: String) -> SavedMacro {
        shortcut(number, name, key, flags, label, namespace: 3, prefix: "Claude-")
    }

    private static func cursorShortcut(_ number: Int, _ name: String, _ key: Int, _ flags: CGEventFlags, _ label: String) -> SavedMacro {
        shortcut(number, name, key, flags, label, namespace: 5, prefix: "Cursor-")
    }

    private static func deepSeekShortcut(_ number: Int, _ name: String, _ key: Int, _ flags: CGEventFlags, _ label: String) -> SavedMacro {
        shortcut(number, name, key, flags, label, namespace: 7, prefix: "DeepSeek-")
    }

    private static func workBuddyShortcut(_ number: Int, _ name: String, _ key: Int, _ flags: CGEventFlags, _ label: String) -> SavedMacro {
        shortcut(number, name, key, flags, label, namespace: 9, prefix: "WorkBuddy-")
    }

    private static func shortcut(_ number: Int, _ name: String, _ key: Int, _ flags: CGEventFlags, _ label: String, namespace: Int = 1, prefix: String = "Codex-") -> SavedMacro {
        let suffix = String(format: "%012d", number)
        let id = UUID(uuidString: String(format: "C0DE%04d-0000-0000-0000-", namespace) + suffix)!
        let stepID = UUID(uuidString: String(format: "C0DE%04d-0000-0000-0000-", namespace + 1) + suffix)!
        let mapping = ButtonMapping(action: .recordedShortcut,
                                    shortcut: RecordedShortcut(keyCode: UInt16(key), modifiers: flags.rawValue, label: label))
        return SavedMacro(id: id, name: prefix + name, steps: [MacroStep(id: stepID, mapping: mapping, delay: 0)])
    }
}
