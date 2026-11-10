# RcHarness 全局检查 · 2026-10-22

范围为整个当前工作区，包括未跟踪的实现文件；基准为 `518db3b` 初始提交。规范来源为 README、参考项目审计和产品定位：通过遥控器操作 GPT、Claude Desktop、Cursor 等应用。本次检查未修改业务代码。

## Standards

### [P1] 原生模式无法通过遥控器切回

位置：`Sources/RcHarness/RcHarnessApp.swift:155–158`。

`handle` 首先通过 `guard mode == .mapping` 过滤全部输入，因此默认 Menu 键切入原生模式后，第二次按 Menu 无法再执行切换动作。用户必须回到 Mac 操作菜单栏或主面板。切换动作需要在两种模式中均可触发。

### [P2] 鼠标事件混用 AppKit 和 Quartz 坐标

位置：`Sources/RcHarness/Core.swift:262–277`。

点击事件与指针移动均把 `NSEvent.mouseLocation` 直接用于 CoreGraphics。两者坐标原点不同；只读坐标对照确认，同一光标的 AppKit 与 Quartz Y 坐标关于屏幕高度互补。鼠标点击会发送到纵向镜像位置，移动会跳跃。应统一使用 Quartz 坐标或完整转换坐标。

## Spec

独立的功能审查同样确认了上述模式切换和鼠标落点问题；此外发现：

### [P2] 激活自定义方案后导出，会遗漏默认方案

位置：`Sources/RcHarness/RemoteDashboard.swift:195–218`；`Sources/RcHarness/SettingsState.swift` 中的 `SettingsBackup`。

备份仅包含当前 `mapping` 与自定义 `profiles`，没有独立保存 `baseMapping`。若当前使用自定义方案 B、默认方案为 A，导出后导入会把 B 写成新的默认方案，A 无法从备份恢复。需要独立备份默认映射，并明确当前选中方案的恢复语义。

### [P2] 设置界面无法选择鼠标移动

位置：`Sources/RcHarness/SettingsView.swift:772–779`。

底层已经有 `pointerUp`、`pointerDown`、`pointerLeft`、`pointerRight`，但动作选择列表没有这些选项。README 宣称的鼠标移动不能通过正常设置流程配置。

## 主审补充

### [P2] 音频输出失败时仍显示正在传输

位置：`Sources/RcHarness/RcHarnessApp.swift:143–146`；`Sources/RcHarness/RemoteMicrophoneOutput.swift:104–120`；`Sources/RcHarness/SettingsView.swift:371`。

收到 BLE 开始事件时，先将界面状态设为正在传输，再创建音频输出。麦克风权限不足、输出设备失效或音频引擎启动失败，只写入 `microphone.failure` 与日志，没有把错误反馈给主面板，界面仍显示绿色传输状态。需要分别表达遥控器正在采音、输出是否正常，并展示输出错误。

### [P2] 主应用缺少单实例保护

位置：`Sources/RcHarness/main.swift:7–14`；`Sources/RcHarness/RemoteVolumeSuppression.swift:99–109`。

`SingleInstanceLock` 仅供音量保护子进程使用，主应用未取得锁。分别启动安装版与 `.build` 版，或通过命令行启动第二个实例，会让两个主进程各自监听 HID、发送按键并写入同一份设置。子进程锁不能阻止主应用的重复输入。主应用需要独立的单实例入口，并让后启动实例激活已有窗口。

### [P2] 设置页仍展示旧图标和泛化产品说明

位置：`Sources/RcHarness/SettingsView.swift:525–532`。

Finder、Dock 和菜单栏已经使用新版图形，但设置页仍以 SF Symbol `appletvremote.gen4.fill` 配蓝色底模拟应用图标，说明仍是“让遥控器成为 Mac 的新入口”。浅色和深色实际渲染均能复现。应使用正式应用图标，并说明面向 AI 对话与编程应用的用途。

## 验证

- `swift test`：10 项测试全部通过。
- `scripts/test_microphone_driver.sh`：通过，含 AddressSanitizer / UndefinedBehaviorSanitizer 检查。
- 浅色默认窗口与深色窄窗口，各渲染并检查 7 个页面；渲染日志未出现布局约束错误。
- `/Applications/RcHarness.app` 的签名校验通过，内置应用图标与已确认的 v2 资源逐字节一致。
- 当前菜单栏文字标题为空，辅助功能名称为 RcHarness，状态帮助为“遥控器未连接 · 映射模式”。
- 鼠标坐标差异使用当前系统坐标读取验证，未发送鼠标或键盘操作。

当前遥控器未连接，未完成实机长按、休眠重连、语音尾音，以及 GPT / Claude Desktop / Cursor 的逐应用兼容性验收。测试通过不能覆盖上述应用层问题。

两个审查轴分别确认：Standards 2 项、Spec 4 项，其中 2 项重合；主审补充 3 项，共 7 个独立问题。两轴的首要问题均为模式切换后无法通过遥控器切回。

## 产品层面的后续改进

当前仍以通用按键映射为主，GPT、Claude Desktop、Cursor 需用户自行配置。可增加按应用划分的配置入口与示例方案，明确每个动作实际依赖的应用快捷键和语音工具设置。此项属于产品完善建议，未作为已承诺但缺失的缺陷计数。
