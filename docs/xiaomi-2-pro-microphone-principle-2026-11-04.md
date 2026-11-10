# 小米蓝牙遥控器 2 Pro 的收音控制原理 · 2026-11-04

调查对象是本项目支持的小米蓝牙遥控器 2 Pro（RC003-MS / RC003），不泛指所有小米电视遥控器。本轮仅阅读代码和公开一手实现资料，未对用户遥控器主动开麦或采集音频。

## 结论

**正常语音键路径需要按住收音，松开就停止。** 这是遥控器固件控制的 Hold-to-Talk 会话生命周期，不是 RcHarness 简单地在松手时停止播放。切换 Fn 点按模式只改变给听写软件的快捷键，不会让遥控器松手后继续传音频。[1][2][3]

不能把上述结论扩大成“电路决定只有按住才能通电”或“任何软件命令都绝对无法开启”。ATVV v1.0 有主机主动 `MIC_OPEN` 和续期 `MIC_EXTEND` 的协议路径，但参考固件具备该路径不证明小米当前固件能有效产出音频。[4]

## 本项目的实际链路

1. 语音键走 HID 按下/释放事件；物理按下调用 `voice.prepareForPress(requestMicrophone: false)`，随后由语音会话控制器触发听写快捷键。物理释放调用 `voiceSession.release()`，本身没有调用 BLE `MIC_CLOSE`。[2]
2. 音频是独立的 ATVV BLE GATT 流。服务 `AB5E0001`，主机命令 TX `AB5E0002`，音频通知 `AB5E0003`，控制通知 `AB5E0004`。RcHarness 接收 `AUDIO_START`（`0x04`）、音频与 `AUDIO_STOP`（`0x00`）；源码明确兼容 RC003 按语音键直接发 START、无需等待主机 MIC_OPEN 的情况。[3]
3. 音频按 120 字节帧累积，以 IMA ADPCM 解码成 16 kHz 单声道 PCM，再通过虚拟麦克风送入听写软件。松手后仍可能短暂排空已收到的尾音；这不代表遥控器继续采音。[3][5]
4. `RemoteVoiceSessionController` 的 Fn 点按模式是在会话开始/结束各模拟一次 Fn，适配“按一下开始、再按一下结束”的听写软件。它仍依赖遥控器提供的同一段音频。[5]

独立的 RC003 固件 2671 实机实现也记录了按住时 START/连续音频、松手时 STOP，并确认 ATVV v1.0、16 kHz ADPCM、120 字节帧。[6]

## 主机主动开启是否可以绕过长按

截至查阅时，SayAll 的 TODO 将持续录音实验保留为阻塞项。该项目记录的真机对照是：通过 Power 触发主机 MIC_OPEN，收到 session=0 的 START，却没有音频通知；同一连接下再用普通语音键立即出现连续 120 字节包。因此 START 应答不能单独证明真实收音成功。它还记录了“普通语音 STOP 后再发 MIC_OPEN”的独立实验仍待确认。[7]

同一 TODO 另有较宽泛的“主动开麦和续期尚未真机验证”表述，与上述具体失败对照存在口径差异。这里以具体记录为准，只得出“目前没有已验证的免按键持续收音成功证据”，不推导全部固件或全部控制序列永久不可能。

若后续要研究绕过路径，成功标准必须是无按键状态下持续收到并解码真实音频、松手后仍有新音频，并能可靠关闭；只观察 UI 进入录音或收到 START 不够。本次任务不修改现有行为。

## 来源

- [1] [SayAll README：Fn 点按兼容及小米固件松手停发音频](https://github.com/HD838A/remote-mic-app/blob/main/README.md#使用语音输入)，查阅于 2026-11-04。
- [2] [RcHarnessApp.swift](../Sources/RcHarness/RcHarnessApp.swift)：`handle(input:pressed:)`，当前物理语音键按下与释放接线。
- [3] [XiaomiRemoteVoice.swift](../Sources/RcHarness/XiaomiRemoteVoice.swift)：GATT UUID、`receiveControl`、`peripheral(_:didUpdateValueFor:error:)`；[RemoteVoiceProtocol.swift](../Sources/RcHarness/RemoteVoiceProtocol.swift)：格式协商和 ADPCM 解码。
- [4] [Google 托管的 Telink ATVV 参考固件 gl_audio.c，固定提交 86f5010](https://android.googlesource.com/platform/hardware/telink/atv/refDesignRcu/+/86f501098fb4ba60954cb046201ffe43ca360c3e/application/audio/gl_audio.c)：`app_audio_key_stop_by_htt` 处理松键停止；`google_voice_v1p0` 处理 MIC_OPEN、MIC_CLOSE、MIC_EXTEND。它是协议原理证据，不是小米固件源码。
- [5] [RemoteVoiceSessionController.swift](../Sources/RcHarness/RemoteVoiceSessionController.swift)：按住/点按快捷键、流结束与尾音排空。
- [6] [mi-ao 的 ATVV 协议与固件 2671 实机记录](https://github.com/fanxeon/mi-ao/blob/main/docs/PROTOCOL.md#真机证据要求)。
- [7] [SayAll TODO：普通语音一分钟限制及开关键开关式长录音实验](https://github.com/HD838A/remote-mic-app/blob/main/TODO.md)，查阅于 2026-11-04。该文件是项目维护者实验记录，未在本轮独立重现实验。
