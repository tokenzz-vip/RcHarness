# OpenCode 桌面版快捷键审查（2026-11-12）

审查对象：提交 `7a90209b78c1b821d9b01c9a36bcd53daad03da8` 中 `DefaultMacros.openCode` 的 59 项预设。

## 结论与核验边界

59 项均有 OpenCode 2.2.7 macOS 桌面版源码依据，未发现抄入其他应用快捷键或修饰键、Carbon 虚拟键名称映射错误。其中 `/` 与 `@` 是文本触发器，不是独立注册的快捷键。确认来源不等于在任意页面、焦点、输入法、键盘布局或用户自定义键位下都能执行。

本机 `/Applications/OpenCode.app` 的 Info.plist 和 app.asar/package.json 均为 2.2.7。提取 app.asar 的 sourcesContent 后，与官方 v2.2.7 标签（`fedc6f208aa2bd54c1019227214568083f6380ad`）逐字节比对了桌面菜单、命令解析器、输入命令、输入编辑器、建议状态机、会话命令、标题栏、标签栏、新会话命令和终端插件共 10 个关键文件，全部一致。下表链接固定到该提交，避免 dev 分支变化。

本次未向真实用户会话注入按键，也未逐项执行会触发发送、停止或自动批准的应用操作；属于源码与事件生成检查，不是 59 项端到端实机通过声明。

## 发现

1. **[P2] ⌘Enter 的名称会掩盖立即发送行为。** `DefaultMacros.swift:257` 叫“切换忙时发送方式”，但编辑器直接调用 `submit({ alternate: true })`。它使用与 Enter 相反的交付方式提交当前内容，不是仅切换后续发送的设置。建议改为“使用另一种忙时方式发送消息”。
2. **[P2] `/`、`@` 缺少文本触发的条件说明。** `DefaultMacros.swift:261–262` 只发送原始键；不先聚焦或调整光标。已有正文中插入 `/` 不会满足斜杠菜单的全文匹配条件；词内插入 `@` 不满足新引用的边界条件。`⇧2` 也只在相应键盘布局下产生 `@`。建议名称标明“输入 /（空输入框）”“输入 @（开头或空白后）”，并说明需要输入框焦点。
3. **[P3] 三个“内容字号”动作实际调整页面缩放。** `DefaultMacros.swift:263–265` 对应 `view.zoomIn`、`view.zoomOut`、`view.resetZoom`。安装包主进程最终调用 `webContents.setZoomFactor`，会缩放界面。建议改为“放大界面”“缩小界面”“重置界面缩放”。
4. **[P3] ⌘1–9 的名称承诺了固定的会话目标。** `DefaultMacros.swift:266–274` 名称均为“转到会话标签页”，但侧面板聚焦时会被 `sideTabShortcuts` 接管，⌘9 还表示最后一个侧面板标签。`docs/behavior.md` 已说明此差异，动作选择器名称仍容易误导。建议使用“转到标签页…”并附带焦点说明。

上述问题是动作含义和适用条件的问题，没有证据支持将它们改成其他应用的组合键。本次未修改预设、用户配置或运行时逻辑。

## 逐项核对

表中“来源”是固定版本的真实注册/处理代码位置；“一致”表示按键来源一致，动作名称和限制仍以备注及上述发现为准。macOS 中源码的 `mod` 解析为 Command。

| 序号 | 当前动作名称（省略 OpenCode-） | 当前按键 | 来源 | 核对结果与限制 |
| --- | --- | --- | --- | --- |
| 1 | 新建会话（Command+N） | ⌘N | [T:46](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/titlebar.tsx#L46) | 一致。 |
| 2 | 新建会话（Command+T） | ⌘T | [T:46](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/titlebar.tsx#L46) | 焦点在侧面板时改为新建侧面板标签页。 |
| 3 | 新建窗口 | ⇧⌘N | [D:124](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/commands/desktop-menu.ts#L124) | 一致。 |
| 4 | 关闭当前标签页 | ⌘W | [T:464](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/titlebar.tsx#L464) | 会话页面的侧面板命令可优先接管。 |
| 5 | 关闭会话标签页 | ⌥⌘W | [T:472](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/titlebar.tsx#L472) | 一致。 |
| 6 | 重新打开已关闭标签页 | ⇧⌘T | [T:479](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/titlebar.tsx#L479) | 可重新打开会话或侧面板标签页，取决于上下文。 |
| 7 | 上一个会话 | ⌥↑ | [B:50](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L50) | 一致。 |
| 8 | 下一个会话 | ⌥↓ | [B:52](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L52) | 一致。 |
| 9 | 上一个未读会话 | ⌥⇧↑ | [B:579](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L579) | 一致。 |
| 10 | 下一个未读会话 | ⌥⇧↓ | [B:586](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L586) | 一致。 |
| 11 | 上一个标签页（Option+Command+左） | ⌥⌘← | [B:551](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L551) | 会话/侧面板标签页随焦点选择。 |
| 12 | 下一个标签页（Option+Command+右） | ⌥⌘→ | [B:559](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L559) | 会话/侧面板标签页随焦点选择。 |
| 13 | 上一个标签页（Control+Shift+Tab） | ⌃⇧Tab | [B:551](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L551) | 会话/侧面板标签页随焦点选择。 |
| 14 | 下一个标签页（Control+Tab） | ⌃Tab | [B:559](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L559) | 会话/侧面板标签页随焦点选择。 |
| 15 | 切换侧边栏 | ⇧⌘B | [L:32](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/shell.tsx#L32) | 一致。 |
| 16 | 切换主页 | ⌘B | [T:420](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/titlebar.tsx#L420) | 一致。 |
| 17 | 搜索会话 | ⇧⌘F | [T:431](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/titlebar.tsx#L431) | 一致。 |
| 18 | 当前页面查找 | ⌘F | [F:191](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/session/timeline/search-controller.ts#L191) | 随页面注册不同查找命令；会话内查找、主页会话搜索、设置搜索等。 |
| 19 | 后退 | ⌘[ | [T:51](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/titlebar.tsx#L51) | 一致。 |
| 20 | 前进 | ⌘] | [T:53](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/titlebar.tsx#L53) | 一致。 |
| 21 | 选择项目 | ⇧⌘O | [T:49](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/titlebar.tsx#L49) | 一致。 |
| 22 | 循环切换工作区 | ⌥⌘L | [W:43](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/new-session/commands.tsx#L43) | 仅新会话页且工作区功能启用。 |
| 23 | 打开文件 | ⌘P | [S:544](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/session/commands/use-session-commands.tsx#L544) | 一致。 |
| 24 | 添加选中代码到上下文 | ⇧⌘L | [S:627](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/session/commands/use-session-commands.tsx#L627) | 必须有可加入上下文的代码选区。 |
| 25 | 切换审查面板 | ⇧⌘R | [S:638](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/session/commands/use-session-commands.tsx#L638) | 一致。 |
| 26 | 切换底部面板 | ⌘J | [S:646](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/session/commands/use-session-commands.tsx#L646) | 仅底部面板功能可用时注册。 |
| 27 | 切换终端 | ⌃` | [P:6](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/gui-plugins/src/terminal/index.ts#L6) | 由内置 terminal GUI 插件注册。 |
| 28 | 打开命令菜单（Command+K） | ⌘K | [K:22](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/commands/command.tsx#L22) | 一致。 |
| 29 | 打开命令菜单（Command+Shift+P） | ⇧⌘P | [K:22](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/commands/command.tsx#L22) | 一致。 |
| 30 | 打开设置 | ⌘, | [D:92](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/commands/desktop-menu.ts#L92) | 一致。 |
| 31 | 选择模型 | ⌘' | [C:111](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/composer/commands.tsx#L111) | 一致。 |
| 32 | 循环切换模型变体 | ⇧⌘D | [C:119](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/composer/commands.tsx#L119) | 一致。 |
| 33 | 下一个 Agent | ⌘. | [C:146](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/composer/commands.tsx#L146) | Agent 控件可见时启用。 |
| 34 | 上一个 Agent | ⇧⌘. | [C:155](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/composer/commands.tsx#L155) | Agent 控件可见时启用；本次未实机逐键确认。 |
| 35 | 打开 MCP 菜单 | ⌘; | [S:685](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/session/commands/use-session-commands.tsx#L685) | 一致。 |
| 36 | 切换自动批准 | ⇧⌘A | [S:696](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/session/commands/use-session-commands.tsx#L696) | 有项目时切换该项目自动批准，否则修改默认值。 |
| 37 | 聚焦输入框 | ⌃L | [S:657](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/session/commands/use-session-commands.tsx#L657) | 一致。 |
| 38 | 将运行任务转入后台 | ⌃B | [S:505](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/session/commands/use-session-commands.tsx#L505) | 只有 blocking() 为真时启用，不能对任意后台状态强制执行。 |
| 39 | 上一条消息 | ⌥⌘[ | [S:666](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/session/commands/use-session-commands.tsx#L666) | 一致。 |
| 40 | 下一条消息 | ⌥⌘] | [S:674](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/session/commands/use-session-commands.tsx#L674) | 一致。 |
| 41 | 发送消息（按忙时设置） | Enter | [E:367](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/composer/editor/editor.tsx#L367) | 输入框聚焦；候选菜单可能优先处理 Enter。 |
| 42 | 切换忙时发送方式 | ⌘Enter | [E:372](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/composer/editor/editor.tsx#L372) | 直接以 alternate 方式提交本条消息；不修改持久发送设置。 |
| 43 | 输入时换行 | ⇧Enter | [E:377](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/composer/editor/editor.tsx#L377) | 输入框聚焦，且未被输入法或候选菜单优先处理。 |
| 44 | 停止回复（Esc） | Esc | [I:542](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/composer/editor/interaction.ts#L542) | 输入框聚焦；弹层、Shell 模式、队列编辑可能先消费 Esc。 |
| 45 | 停止回复（Control+G） | ⌃G | [I:542](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/composer/editor/interaction.ts#L542) | 输入框聚焦且任务运行/等待；历史弹层可能先消费。 |
| 46 | 打开斜杠命令 | / | [Q:230](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/composer/suggestions/machine.ts#L230) | 普通字符输入；仅全文符合 /^\/(\S*)$/ 时弹出斜杠菜单。 |
| 47 | 打开引用菜单 | ⇧2（@） | [Q:215](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/composer/suggestions/machine.ts#L215) | 普通字符输入；新引用要求 @ 位于开头或空白之后；⇧2 依赖键盘布局。 |
| 48 | 放大内容字号 | ⌘= | [D:221](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/commands/desktop-menu.ts#L221) | 实际为页面缩放，不是单独设置文字字号。 |
| 49 | 缩小内容字号 | ⌘- | [D:227](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/commands/desktop-menu.ts#L227) | 实际为页面缩放，不是单独设置文字字号。 |
| 50 | 重置内容字号 | ⌘0 | [D:215](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/commands/desktop-menu.ts#L215) | 实际为重置页面缩放。 |
| 51 | 转到会话标签页1 | ⌘1 | [B:598](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L598) | 默认选择第 1 个可见会话标签；侧面板聚焦时选择侧面板标签。 |
| 52 | 转到会话标签页2 | ⌘2 | [B:598](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L598) | 默认选择第 2 个可见会话标签；侧面板聚焦时选择侧面板标签。 |
| 53 | 转到会话标签页3 | ⌘3 | [B:598](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L598) | 默认选择第 3 个可见会话标签；侧面板聚焦时选择侧面板标签。 |
| 54 | 转到会话标签页4 | ⌘4 | [B:598](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L598) | 默认选择第 4 个可见会话标签；侧面板聚焦时选择侧面板标签。 |
| 55 | 转到会话标签页5 | ⌘5 | [B:598](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L598) | 默认选择第 5 个可见会话标签；侧面板聚焦时选择侧面板标签。 |
| 56 | 转到会话标签页6 | ⌘6 | [B:598](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L598) | 默认选择第 6 个可见会话标签；侧面板聚焦时选择侧面板标签。 |
| 57 | 转到会话标签页7 | ⌘7 | [B:598](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L598) | 默认选择第 7 个可见会话标签；侧面板聚焦时选择侧面板标签。 |
| 58 | 转到会话标签页8 | ⌘8 | [B:598](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L598) | 默认选择第 8 个可见会话标签；侧面板聚焦时选择侧面板标签。 |
| 59 | 转到会话标签页9 | ⌘9 | [B:598](https://github.com/anomalyco/opencode/blob/fedc6f208aa2bd54c1019227214568083f6380ad/packages/app/src/shell/titlebar/tab-strip.tsx#L598) | 会话区选择第 9 个可见会话标签；侧面板聚焦时选择最后一个侧面板标签。 |

## 测试与覆盖限制

执行 `swift test --filter DefaultMacroTests`：14 项测试全部通过。现有按键事件用例通过 `SystemEventSender(postEvent:)` 捕获事件，未向真实会话发送事件。测试覆盖事件按键、修饰键、预设初始化、升级及用户编辑保留；不能证明 OpenCode 接收后一定完成对应动作，也不能发现名称和真实语义不一致。

预设并未穷举 OpenCode 的全部快捷键。例如本版还注册了 ⌘U（添加附件）、⇧⌘X（切换 Shell 输入模式）和 ⌃R（重命名会话）；缺少这些不影响现有 59 项的来源结论。
