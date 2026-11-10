# 语音唤起链路审查 · 2026-10-28

审查范围是遥控器 HID 语音键 → Fn/修饰键触发 → BLE START/PCM/STOP → 音频准备与排空 → 按键结束，以及断连、切换方案、权限失败、睡眠和退出。问题描述为“短按语音键，听写窗口不出现”。前次安装后并没有真实目标应用窗口成功出现的验收证据；收音和 HAL 播放成功不能证明唤起成功。

本轮按“按住说话、松开后自动结束听写”的目标，采用持续按住触发键、尾音排空后释放的模式；Fn 点按作为当时其他目标应用的可选兼容模式保留，设置不自动改写为点按模式。本文记录历史实现，当前支持范围以 [行为说明](behavior.md) 为准。

## 已确认的问题

1. **P1：开始、结束点按没有配对。** 上次 `releaseWhenFinished` 分支在 `voiceTapSent` 为真时清空标记，却没有发送结束点按。目标若按 Fn 切换录音状态，第一次残留录音状态，下一次开始就可能变成结束。现在每个会话拥有开始与结束两次独立点按，结束等待播放排空。
2. **P1：BLE START 早于 HID 按下时漏触发。** `sendPendingVoiceTap` 只从 START 回调取待发按键；START 先到时待发值为空。HID 后到只保存待发值，可能拖到排空后才打开窗口。现在 HID 负责触发，BLE 的先到音频绑定同一会话并缓冲；BLE 单独到达不会打开目标。
3. **P1：连续按键复用共享状态。** 排空完成前 `pressedMappings` 仍占用 `.options`，新按下可能被去重；无会话身份的旧完成回调又会清空共享的 pending/sent/mapping。现在每次按键捕获映射并拥有回调身份；上一段结束前，最多排队两段新会话，旧完成回调不能释放新按键。
4. **P1：取消可能制造新的点按。** 原清理分支只要处于 tap 模式就先发 down，再发 up，无法区分未开始、开始中、已经开始或正在结束。可能在断连或退出时意外唤起目标。现在只有已经开始的目标会得到匹配的结束；没有 HID 的 BLE 流取消不会发键。正常退出等待最后的 key-up 完成。
5. **P2：点按没有时长，首包没有目标启动门禁。** 原 down/up 在同一调用栈发送，随后直接路由 PCM。现在 Fn 每次按下持续 120 ms，开始点按抬起后缓冲 150 ms，再发送有界首包；这是启动宽限期，不是目标已经录音的确认。等待期间最多保存 8000 样本，超出丢最旧数据并记账。
6. **P2：测试覆盖在错误层次。** 原有音频测试验证播放器和尾音，未驱动 App 的 HID、BLE 与按键回调组合。本轮让 App 使用可注入输出和调度器的 `RemoteVoiceSessionController`，同一控制器用于测试和生产接线；不再用多个 App 布尔变量拼接生命周期。

## 被排除或仍未证实的解释

- 本机无注入探针确认 `CGEvent(keyboardEventSource:virtualKey:keyDown:)` 对 Fn、Command、Option 自动生成 `flagsChanged`（type 12），普通 Enter 是 keyDown/keyUp（10/11）。因此“Fn 被发成普通字母键事件”不是本次确认的原因。回归检查实际事件类型和 Fn flags，通过注入 postEvent 拦截，不向系统发测试按键。
- 现场日志有多个 BLE 会话成功解码并确认播放；这排除了这些会话中“完全没有音频”的解释，不能排除窗口没有接受快捷键或输入监听缺失。
- 当前目标是否接受 Fn 点按、需要按住、是否全局监听，以及窗口真正开始录音的时间，不能从 HAL 计数判断。本轮未自动启动第三方听写或采集用户语音，也不声称已通过目标窗口和真实睡眠唤醒验收。

## 现场权限发现

历史修订版启动后曾报告 `input=false accessibility=false`，同时 BLE 型号与能力握手成功。这是实际阻断项：蓝牙收音可用，不代表 HID 可读或 Fn 可以注入。当时构建采用 ad-hoc 签名，二进制身份变化与权限未生效并存，说明构建、签名校验和连接成功不能作为完整验收。

应用明确显示语音按键权限未就绪，阻止无权限时静默尝试唤起；从系统设置返回且权限恢复后，重新启动 HID 监听。当前本机编译和安装须按 [仓库说明](../README.md) 配置 `RC_HARNESS_LOCAL_SIGNING_IDENTITY`，不沿用历史 ad-hoc 构建方式。macOS 的实际授权仍需在系统设置操作，代码不能代替授权。

## 实现与验证

- `Sources/RcHarness/RemoteVoiceSessionController.swift`：每会话持有映射、HID/BLE 生命周期、Fn 按下、缓冲与排空身份；准备失败不触发目标，重复事件幂等，取消保持最后 key-up。
- `Sources/RcHarness/RcHarnessApp.swift`：HID/BLE/PCM 统一交给控制器；切换映射、触发模式、输出设备及音频失败取消当前会话；正常退出异步等清理结束。
- `Sources/RcHarness/Core.swift`：键盘事件使用已有注入的 postEvent，生产默认仍发送到 HID event tap，测试可验证真实 flagsChanged 事件而无系统副作用。
- `tests/RcHarnessTests/VoiceSessionTests.swift`：短按、BLE 先到、重复事件、连续会话、旧回调、取消、缺 START、按住模式、退出、准备失败、缓冲上限、真实输出排空，以及全部 10 种合法 HID/BLE 次序各跑 3 种时间间隔、固定种子的 2000 次事件压力。

诊断新增 `voice button`、`voice trigger session=<id>` 的 press、BLE start/stop、start/stop tap、drain、cancel、closed 日志，以及 Input Monitoring/Accessibility 状态。日志仍只记录元数据，位于 `~/Library/Logs/RcHarness/audio.log`。

合法顺序测试对按住、Fn 点按两种模式分别执行 10 种次序 × 3 种时间间隔，共 60 组，另有固定种子 2000 次事件压力；真实 HAL 12/12 段各确认播放 1600 样本，Objective-C 注入播放异常边界通过。测试不使用用户录音。

Swift 完整测试共 92 项通过，其中新增会话测试 16 项。日志新增进程名和 PID，便于区分测试注入的失败与日常应用故障。
