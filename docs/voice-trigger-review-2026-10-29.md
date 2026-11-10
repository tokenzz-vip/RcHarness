# 微信输入法语音触发复查 · 2026-10-29

## 现象与结论

在 Codex 输入框内使用微信输入法语音输入时，遥控器能够完成 BLE 收音和 HAL 播放，但地球键（Fn）没有唤起语音浮窗。验收同时要求浮窗出现、读取遥控器音频，以及识别文本进入输入框；音频计数正常不能代替这项验收。

**最终实测通过。** 已确认的冲突是另一款映射程序 Joy Harness 同时处理同一遥控器并注入右 Command。退出该程序后，还需在 RcHarness 关闭再开启按键映射，恢复包含原始 F5 在内的设备级按键抑制。完成这两步后，Fn 唤起浮窗和识别文字均通过验证。

本文保留故障机制、对照结果和验证范围，省略个人操作时间、进程号、安装备份路径及反馈原话。

## 排查方法

1. 确认 RcHarness 的输入监控与辅助功能权限就绪；目标输入法另需麦克风权限。BLE 型号与能力握手成功不能证明 HID 读取和按键注入可用。
2. 在微信输入法中明确选择「RcHarness 遥控器麦克风」，使其与 RcHarness 的回环输出一致；无需因此更改系统默认输入设备。
3. 将目标输入法与 RcHarness 的触发键设为相同值，并关闭 Fn 点按。先用真实键盘验证目标快捷键，再对照遥控器。右 Command 已独立验证可用，但不能代替 Fn 的验收。
4. 同时观察 HID、Quartz 修饰键事件与语音浮窗，检查所有事件来源。只过滤 Fn/F5 会漏掉其他程序先行注入的 Command。观察不保存普通文字键、窗口标题、听写内容或音频。
5. 保证同一遥控器只由一款映射程序接管。其他程序退出可能恢复设备映射，需重新建立 RcHarness 的原生按键抑制，再复测完整收音与输入流程。

## 已修复的事件格式缺陷

`SystemEventSender` 原来仅给右 Command 设置设备侧标志。左 Command、左 Option、右 Option 只有通用标志；采用 `NX_DEVICE*` 掩码识别左右键的监听器可能将按下误判为释放。

四种 Command/Option 映射现在都同时带有通用与对应侧的设备标志。标志值依据 macOS SDK 的 `IOKit/hidsystem/IOLLEvent.h`：左 Command `0x08`、右 Command `0x10`、左 Option `0x20`、右 Option `0x40`。

```bash
swift test --filter VoiceSessionTests.testVoiceModifiersIdentifyTheSelectedSideForShortcutListeners
```

修复前该测试在左 Command、左 Option、右 Option 三项失败；修复后会话测试 17 项、完整 Swift 测试 104 项通过。测试从真实 `SystemEventSender` 获取事件，通过注入出口截获，不发送到桌面会话。此项修复针对备用修饰键，不是已证实的 Fn 故障原因。

## Fn 对照与被排除的假设

| 对照 | 结果与解释 |
| --- | --- |
| 内置键盘 Fn | 原始 HID page `0xFF`、usage `3` 成对上报；Quartz 为键码 `63` 的 `flagsChanged`，来源状态为 HID。重新录制快捷键后可唤起浮窗，未发现硬件 Fn 上报故障 |
| 合成 Fn 改为 HID 来源 | 使用同一个 `CGEventSource(stateID: .hidSystemState)` 创建按下与释放，来源状态与真实 Fn 对齐；单独应用此改动后仍无浮窗，不能将它视为充分修复条件 |
| 设备级 F5 → Fn 映射 | 可产生原生 Fn 事件，但仍未唤起浮窗。完成对照后已恢复设备映射，此实验不替代语音尾音排空设计 |
| 添加 `maskNonCoalesced` | 事件标志变化后仍无浮窗；临时过滤器已撤销 |
| 扩展到全部相关修饰键 | 发现另一映射程序先注入右 Command，约 74 ms 后 RcHarness 才发送 Fn；确认存在双重接管冲突 |

参考实现的差异仍可用于理解事件路径：[Fn 设备映射](https://github.com/HD838A/remote-mic-app/blob/main/Sources/RemoteMic/RemoteVoiceFunctionMapper.swift)、[软件注入的 HID 来源](https://github.com/HD838A/remote-mic-app/blob/main/Sources/RemoteMic/KeyboardInjector.swift)。设备映射会影响排空后释放的时序，不能仅因它产生原生事件就替换现有实现。

## 修复与验证范围

Fn 的按下和释放改为共用明确的 HID 事件来源，保持键码和会话时序。来源状态回归 `VoiceSessionTests.testFnUsesHIDSourceStateWithoutChangingCommandEvents` 修改前有 4 个预期失败；修改后会话测试 18 项及完整 Swift 测试 105 项通过。事件格式回归不等同于输入法端到端验收。

安装候选版本后曾出现输入监控与辅助功能权限未就绪；重新授权并重启后恢复。这说明历史 ad-hoc 构建身份变化可能要求重新授权，构建和签名校验通过仍不足以证明按键可用。当前本机编译和安装的固定证书要求以 [仓库说明](../README.md) 为准。

退出冲突程序并重建 RcHarness 按键抑制后，实测观察到 Fn 按下约 0.25 秒出现语音浮窗，随后多次操作均完成按下、浮窗出现、释放与浮窗消失，并能输入识别文本。配置为两端都使用 Fn、关闭点按，微信输入法麦克风明确选择 RcHarness；未再观察到另一程序注入的 Command 或原始 F5。临时观察器和过滤器均已停止。

收尾 `scripts/test_all.sh` 通过：105 项 Swift 测试、HAL ASan/UBSan、Objective-C 异常边界和 12 段音频输出探针。已核对构建产物与安装版本的主程序 SHA-256 一致。验收覆盖带 HID 来源调整的版本，未重新安装旧版本单独验证该调整的必要性，因此最终结论仅将并行映射冲突及抑制恢复作为已证实原因。
