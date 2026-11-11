# G9N9N 点按持续语音的可行性 · 2026-11-11

> 后续实现：同日已新增 Google 专用 on-request 点按路径，保留长按默认及小米点按禁用。下文保留实现前的研究结论，当前行为与验收边界见 [G9N9N 适配说明](google-g9n9n.md)。

目标：语音键点一下，松手后继续收音；再点同一语音键停止，并配合微信、豆包或讯飞输入法完成听写。本轮只查阅项目代码、既有实机记录及公开一手源码，未主动开启麦克风、采集用户音频、修改产品实现或安装应用。

## 结论

**有协议上的可行路径，但当前 RcHarness 尚未实现，也没有本项目 G9N9N 固件 26.2 点按持续收音的实测证据。仅启用输入法的点按快捷键不能完成这个目标。** 必须同时解决遥控器松手后持续送音频、第二次语音点击可观测、输入法开始/结束动作配对三个问题。现有自动化测试证明软件已有快捷键锁存骨架，不证明遥控器固件接受这种收音方式。[1][2][3]

目前可以确认的是：2026-11-07 的本机 G9N9N 记录完成按住收音，松手后停止采音；没有做 PTT 或 on-request 模式的对照。因此不能断言其硬件只能长按，也不能宣称已经支持点按。[1]

## 已有实现与缺口

| 层次 | 当前实现 | 点按持续语音需要补充 |
| --- | --- | --- |
| 遥控器收音 | Google 发送 `GET_CAPS = 0A 01 00 00 02 02`，只校验版本、16 kHz 编码和帧长；未保存 interaction model 或启动原因 | 记录并解析协商后的模型、启动/停止原因，实测松手后仍有新增音频包 |
| 语音按键 | Google HID 映射没有语音键，使用 ATVV 音频 START/STOP 合成按下/释放 | 将物理点击与音频生命周期分开，确认第二次点击是否有 HID、START_SEARCH 或其他可区分通知 |
| 快捷键 | `RemoteVoiceSessionController` 的 toggle 可忽略首次释放/STOP，结束时再发一次点按快捷键 | 不能把保留输入法窗口当作持续收音；应处理遥控器停流、超时与输入法状态同步 |
| 配置 | `supportsVoiceTap = false`，模式归一化为 hold | 经实机验证后再开放对应能力和 UI |

来源：[能力请求与解析](../Sources/RcHarness/RemoteVoiceProtocol.swift)、[Google 身份能力](../Sources/RcHarness/Core.swift)、[HID 映射](../Sources/RcHarness/XiaomiRemoteHID.swift)、[BLE 收音与语音边沿](../Sources/RcHarness/XiaomiRemoteVoice.swift)、[会话状态机](../Sources/RcHarness/RemoteVoiceSessionController.swift)。

第二次点击存在具体阻断：`RcHarnessApp.handle` 只有在 `heldVoiceInput != input` 时才尝试 `finishToggle()`。若改用 PTT 后松手不再产生音频 STOP，`heldVoiceInput` 可能一直为 `.options`，再次语音按下被过滤；BLE 的 `RemoteVoiceButtonState` 也会去重未释放的按下。即使遥控器已持续收音，简单把 `supportsVoiceTap` 改为 `true` 仍不能保证同一语音键停止。[2][3]

## 官方参考固件提供的路径

Google 托管的 Telink 参考头文件把 interaction model 定义为 on-request `0x00`、PTT `0x01`、HTT `0x03`，不是任意可组合的独立标志。当前项目请求的末字节 `0x02` 是既有实测成功配置；源码注释称其为 hold-only，但不能据此把 `0x02` 当作所有 ATVV 固件通用的标准枚举。[4]

Telink 参考实现将主机请求的模型写入当前模型：PTT 按下启动；松键停止函数只结束 HTT。Realtek 参考实现也存在 PTT 与 HTT 独立分支，协商时会将固件默认模型限制到主机支持级别。由此推断，**先尝试请求 PTT、读取回复确认模型，再验证松手后音频是否持续**，比只更改输入法快捷键更接近目标。但这些是参考实现，不是本机 G9N9N 固件源码，修改请求值本身不构成成功证据。[5][6]

另一路径是 on-request：物理语音点击触发主机 `MIC_OPEN`，主机结束时 `MIC_CLOSE`，必要时用 `MIC_EXTEND` 续期。参考实现对开麦有当前状态限制；Telink 还要求遥控器先处于 active 状态。`MIC_EXTEND` 只刷新已有流的超时，不能保证阻止 HTT 的松键停止。因此不应在每次 STOP 后无限重开来模拟连续录音。[5][6]

PTT 也不自动等于“第二次同键停止”：Realtek 的按下处理在驱动已录音时会直接返回失败。第二次点击能否单独送达主机仍须实测；若收不到任何可区分信号，主机无法按该点击停止，只能退为另一普通遥控器按键停止或改走 on-request 路径。[6]

## 与三个输入法的配合

遥控器音频持续后，有两种应用层方案，需按用户实际安装版本验证。

| 方案 | RcHarness 行为 | 输入法要求 |
| --- | --- | --- |
| 输入法原生点按 | 开始发一次完整快捷键，第二次遥控器点击后等尾音排空，再发同一快捷键 | 该版本确实支持同键切换开始/结束，且选中 RcHarness 虚拟麦克风 |
| RcHarness 锁存长按 | 第一次遥控器点击后保持输入法长按快捷键，第二次点击关闭遥控器收音、尾音排空后释放 | 该版本支持可合成的长按快捷键；不依赖输入法原生点按功能 |

微信输入法已有本仓库 Fn／右 Command 按住、RcHarness 虚拟麦克风的实测记录；该记录不能替代其点按功能验收。豆包、讯飞以及三者各版本的点按默认键、静音自动结束、最长时限、是否跟随系统默认麦克风，本轮均未在用户机器验证，不预设为一致。优先采用用户实际可用的快捷键和输入源设置。[7]

## 最小验证与实施顺序

1. 在原有成功的按住配置下，记录能力回复模型、AUDIO_START/STOP 原因与点击相关事件；只保存元数据，不保存音频或转写。
2. 独立实验 PTT 与 on-request，逐次验证短按松手后连续新增音频包、停止命令有效、第二次同键点击可观测；失败立即恢复既有配置。
3. 将物理按钮状态、BLE 音频流与目标输入法状态拆开；补齐启动失败、静默、断连、睡眠、换型号和退出时的成对清理，再开放 G9N9N 点按配置。
4. 分别用微信、豆包、讯飞验证开始、松手后继续说话、再次点击停止、尾字完整，以及重复两段；先确认持续音频，再判断识别结果。

本轮未改变用户可见行为；现有按住模式与其验证边界继续以 [G9N9N 适配文档](google-g9n9n.md) 为准。

## 来源

- [1] [本项目 G9N9N 适配与实机记录](google-g9n9n.md#验证边界)。本轮复核既有记录，没有重新现场验收。
- [2] [RcHarnessApp.swift](../Sources/RcHarness/RcHarnessApp.swift)：`handle(input:pressed:)` 与语音回调接线。
- [3] [RemoteVoiceSessionController.swift](../Sources/RcHarness/RemoteVoiceSessionController.swift)：`release`、`finishToggle`、BLE 生命周期；[XiaomiRemoteVoice.swift](../Sources/RcHarness/XiaomiRemoteVoice.swift)：`updateVoiceButton`、`startStream`、`receiveControl`。
- [4] [Google 托管 Telink gl_audio.h，固定提交 86f5010](https://android.googlesource.com/platform/hardware/telink/atv/refDesignRcu/+/86f501098fb4ba60954cb046201ffe43ca360c3e/application/audio/gl_audio.h)：模型定义与命令枚举。
- [5] [同提交 gl_audio.c](https://android.googlesource.com/platform/hardware/telink/atv/refDesignRcu/+/86f501098fb4ba60954cb046201ffe43ca360c3e/application/audio/gl_audio.c)：`app_auido_google_callback`、`google_voice_start/stop`、`google_voice_v1p0`。
- [6] [Google 托管 Realtek voice.c](https://android.googlesource.com/platform/hardware/google/atv/refDesignRcu/realtek/+/refs/heads/main/src/app/google_rcu/voice_module/voice.c)：`voice_handle_mic_key_pressed/released`、能力协商、MIC_OPEN/CLOSE/EXTEND。查阅时 blob 为 `c9bcc5b97cdeaf4bbd2adf64d7e1aa6b303bf87f`，参考设计不等同于 G9N9N 量产固件。
- [7] [本项目输入法实测配置](behavior.md)：语音唤起与 Codex／微信输入法使用边界。
