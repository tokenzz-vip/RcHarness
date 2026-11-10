# JoyHarness 遥控器功能审计

审计对象：[`nixihz/JoyHarness`](https://github.com/nixihz/JoyHarness)，本地审计快照 `1e13f47aa459631cb8eea8a0d8a1e37d80e3bd79`（2026-10-21）。重点是 Xiaomi Bluetooth Remote 2 Pro（型号 `RC003-MS`）及其与 Codex Micro 的连接边界。

RcHarness 的产品约束已收窄为 **Apple Silicon（arm64）+ macOS 15 及以上 + 纯软件适配**。因此，本文只把 JoyHarness 中不依赖 RP2040 的遥控器能力作为 RcHarness 候选功能；依赖开发板的部分保留为排除项和边界说明。遥控器适配按设备驱动设计，当前仅以仓库内的 `RC003-MS` 作为参考，不表示首期只能支持这一款。

## 结论

“遥控器部分不需要另外嫁接硬件即可完整功能”这句话需要拆成两种目标：

| 目标 | 是否需要 RP2040/额外硬件 | 结论 |
|---|---:|---|
| RC003-MS 按键控制 Mac：方向键、Enter、Backspace、Esc、模式切换、截图，以及自定义快捷键 | 否 | 直接由 macOS IOHID 接收，Joy Harness 用 CoreGraphics/系统键发送输出 |
| RC003-MS 内置麦克风输入到语音应用 | 否（但需要安装随 App 提供的 HAL 音频组件） | 由 CoreBluetooth 接收 ATVV BLE 音频并输出为 Joy Harness 虚拟麦克风 |
| 音量键切换六个 Codex 任务槽位 | 是 | 默认映射是 `previousSlot`/`nextSlot`，需要 RP2040 Vendor HID |
| Codex 原生审批/拒绝、Codex Micro `ACT10` 按住说话、槽位打开/同步 | 是 | 这些动作通过 RP2040 的 USB CDC + Vendor HID 送入 Codex Desktop |
| JoyHarness 宣传的完整“遥控器 + Codex”能力 | 是 | 仅有 RC003-MS 时不能称为完整功能 |

因此，按 RcHarness 的目标范围，RC003-MS 的 HID 映射和内置麦克风均可采用纯软件实现，**无需焊接、嫁接或另加微控制器**。JoyHarness 的 Codex Micro 槽位、审批和原生按住说话明确排除在 RcHarness 首期之外，因为它们必须加入已刷固件的 Raspberry Pi Pico/兼容 RP2040，并使用数据线连接 Mac。

## 代码证据

### RC003-MS 输入不经过 RP2040

`README.md` 明确说明 RC003-MS 通过 macOS IOHID 直接检测；`Sources/JoyHarness/XiaomiRemoteHID.swift` 使用 `IOHIDManager`，按小米厂商/产品 ID 匹配设备、注册输入回调并把 HID usage 转成内部 `ControllerInput`。这条链路没有串口或 RP2040 依赖。

默认映射位于 `Sources/JoyHarness/ControllerMapping.swift`：

- OK → Enter；Back → Backspace；Home → Escape；方向键 → 系统方向键；
- Menu → Toggle Native/Mapping Mode；Custom → 截图；
- Voice → Right Command（面向 Spokenly 等外部语音应用）；
- 音量 −/+ → 上一个/下一个 Codex 槽位。

其中最后一项是“按键本身可读”与“动作能否完成”的分界：按键能被 RC003-MS 直接读到，但槽位动作随后需要 RP2040。

### 遥控器内置麦克风不经过 RP2040

`Sources/JoyHarness/XiaomiRemoteVoice.swift` 使用 CoreBluetooth 扫描并连接 RC003 语音服务，验证型号 `RC003`/`RC003-MS`，订阅音频/控制特征并解码 16 kHz IMA/DVI ADPCM。`JoyHarnessMain.swift` 把解码后的 PCM 送入 `RemoteMicrophoneOutput`；`docs/xiaomi-remote-voice.md` 规定由随 App 打包的 `JoyHarnessMicrophone.driver` 提供 CoreAudio 虚拟输入设备。

这条链路所需的是蓝牙、系统权限和软件驱动安装，不是额外硬件。第一次启用 HAL 组件需要管理员授权并会短暂重载音频服务；外部语音应用还要拥有自己的麦克风权限。

### Codex Micro 动作明确依赖 RP2040

`Sources/JoyHarness/JoyHarnessMain.swift` 中：

- `selectSlot` 只有在 `rp2040.isConnected` 时才执行；
- `approve`、`deny`、`toggleFastMode` 通过 `tapMicroKey("ACT07/ACT08/ACT06")`；
- 按键桥的 `keyHandler` 把 Micro key 发送到 `rp2040.sendKey`；
- 其他鼠标、滚轮和系统键则直接交给本机的 mouse/system-key bridge。

仓库 README 的能力矩阵也明确区分：仅 App + controller 能提供鼠标、滚动、系统键和诊断；App + controller + RP2040 才提供完整 Codex 输入、按住说话和确认反馈。RP2040 固件暴露 `Codex Micro` Vendor HID 和 `Joy Harness Bridge` USB CDC 两个接口，需刷入固件并保持数据线连接。

## 运行前置条件

不增加 RP2040 时，至少需要：

1. Apple Silicon Mac，macOS 15 或更高版本；
2. RC003-MS 通过系统蓝牙配对；
3. 给 Joy Harness 授予 Input Monitoring；需要鼠标/系统键时再授予 Accessibility；
4. 启用随 App 提供的 Remote Microphone HAL 组件，并在系统/语音应用中选择 `Joy Harness 遥控器麦克风`；
5. 如果安装了 Karabiner-Elements，关闭该遥控器的 Modify events，避免它占用 HID 设备。

如果只使用遥控器按键映射，不启用麦克风，则不需要安装 HAL 组件。RcHarness 首期不实现 Codex Micro 完整能力，因此不要求 Codex Desktop Micro、RP2040 固件或数据线。

## 验证边界

仓库包含 `Tests/JoyHarnessTests/XiaomiRemoteTests.swift`、`RemoteVoiceTests.swift` 和麦克风输出生命周期测试，覆盖 HID 映射、语音协议、ADPCM 分包和无硬件生命周期。仓库语音文档记录了 2026-09-19 的 RC003 实机收音、解码和 CoreAudio 加载结果；但同一文档仍把 Spokenly 的按住录音、识别效果以及句首/句尾完整性列为待实机验收。因此，源码和自动化测试足以确认架构边界，不能替代目标 Mac、目标 RC003-MS 和目标语音应用上的端到端验收。

本次审计还运行了 `python3 tests/test_firmware_contract.py`（2/2 通过）和 `bash scripts/test_microphone_driver.sh`（ASan/UBSan 通过）。SwiftPM 的 Swift 测试因等待 Sparkle 依赖获取未完成，不能据此宣称 Swift 测试全量通过。

## 参考源码

- [JoyHarness README](https://github.com/nixihz/JoyHarness/blob/1e13f47aa459631cb8eea8a0d8a1e37d80e3bd79/README.md)
- [RC003 HID 解析与 IOHID 管理](https://github.com/nixihz/JoyHarness/blob/1e13f47aa459631cb8eea0d8a1e37d80e3bd79/Sources/JoyHarness/XiaomiRemoteHID.swift)
- [RC003 BLE 语音实现](https://github.com/nixihz/JoyHarness/blob/1e13f47aa459631cb8eea0d8a1e37d80e3bd79/Sources/JoyHarness/XiaomiRemoteVoice.swift)
- [遥控器默认映射](https://github.com/nixihz/JoyHarness/blob/1e13f47aa459631cb8eea0d8a1e37d80e3bd79/Sources/JoyHarness/ControllerMapping.swift)
- [主程序桥接与 RP2040 路由](https://github.com/nixihz/JoyHarness/blob/1e13f47aa459631cb8eea0d8a1e37d80e3bd79/Sources/JoyHarness/JoyHarnessMain.swift)
- [RC003 麦克风链路与实机验证记录](https://github.com/nixihz/JoyHarness/blob/1e13f47aa459631cb8eea0d8a1e37d80e3bd79/docs/xiaomi-remote-voice.md)
- [遥控器测试](https://github.com/nixihz/JoyHarness/blob/1e13f47aa459631cb8eea0d8a1e37d80e3bd79/tests/JoyHarnessTests/XiaomiRemoteTests.swift)
