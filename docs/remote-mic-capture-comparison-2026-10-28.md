# RcHarness 与 remote-mic-app 收音链路对照

2026-10-28；上游固定提交为 [`2ce3ec65b02b2746109da267bc9a6eee04ec516b`](https://github.com/HD838A/remote-mic-app/tree/2ce3ec65b02b2746109da267bc9a6eee04ec516b)。本项目以当前工作区为准，包含本次已安装的音频中断修复。上游源码仅作为研究资料，没有执行其构建、安装或启动脚本。本次未修改业务实现。

## 结论

RC003/RC003-MS 的基础协议和 ADPCM 解码没有发现本质差异。最值得借鉴的是异步音频就绪判定、首包与控制包乱序保护、设备生命周期和逐段诊断。源码对照不能证明对方音质更好或识别率更高。

输出与驱动的独立核查见 [输出对照](remote-mic-output-comparison-2026-10-28.md)。

## 收音对照

| 环节 | RcHarness 当前实现 | 上游源码事实 | 判断 |
| --- | --- | --- | --- |
| 无线采音 | CoreBluetooth 主队列、ATVV 握手、16 kHz 单声道 | 同样使用 CoreBluetooth 主队列和同组 ATVV UUID | 无线收音基础相同，不能把主队列滞后等同于无线丢包。[U1][U2] |
| 协议兼容 | 版本 0x0100、120 字节帧、RC003/RC003-MS | 解析多版本和声明帧长；运行链路仍限制 16 kHz；有 ARN9 低半字节优先分支 | 当前 RC003 不需要换解码；扩型号时应选择明确策略。[U1][U2] |
| 分帧与同步 | 按 120 字节累积；高半字节优先 IMA ADPCM；SYNC 清半帧并重置 decoder | 按声明帧长累积；同一高半字节算法；SYNC 清半帧并在下一完整帧重置 | 核心语义一致，已做差分实验。[U1][U2] |
| 音频早于 START | 需要 microphoneOpen 和活动 session，早到音频不解码 | 协议 ready、未取消、且不在 STOP 后 300 ms 内时，允许首音频包隐式启动 | 本项目存在丢句首的时序缺口；是否为现场原因仍需记录验证。[U2] |
| 取消后迟到 START | 没有独立 cancelled-open 状态 | START/音频都检查取消保护；可对晚到 START 发 MIC_CLOSE | 值得补 session/generation 保护，避免旧流重新开启。[U2][U3] |
| 音频处理 | 跨包状态的 80 Hz 高通、平滑、轻噪声门、增益、软限幅 | 每帧三点加权平滑、增益、Int16 硬限幅 | 都是轻量 DSP；滤波多不等于更清楚。噪声门对轻声的影响应使用同一段原始 PCM 对照。[U1] |
| 输出配置 | 主队列创建 HAL/引擎，延后 100 ms 启动，最多两次新图恢复 | 独立串行输出队列，校验 engine/player/实际设备绑定，ObjC 捕获 play() 异常 | 本次修复解决已复现窗口；异步 ready 与异常桥提供更完整的结构。[U4][U5] |
| Fn 与尾音 | HID 触发 Fn；释放等 BLE STOP/排空；迟到 START 有超时保护 | 独立点按会话状态机，缓存 pre-roll，等目标/开始点按就绪后路由，排空后结束点按 | 双方有尾音保护，上游对目标尚未开始收音的窗口处理更细。[U6] |
| 重连 | 1/2/4/8/16 秒退避，优先保存 UUID，按服务 UUID 扫描 | 分阶段生命周期、generation、坏缓存绕过、扫描窗口、系统挂起/恢复 | 可借鉴策略；不需要扩大到所有未知 ATVV 设备。[U2][U3] |
| 诊断 | PCM 总样本/峰值、输出已播/丢弃，主要 print | 接收/解码/路由/排队/已播/中断计数与时间线、主队列滞后 | 最应先补，才能定位无声究竟发生在哪一段。[U7] |

本项目定位：

- [XiaomiRemoteVoice.swift](../Sources/RcHarness/XiaomiRemoteVoice.swift)：94–179 发现/重连；207–259 控制；358–382 型号/音频。
- [RemoteVoiceProtocol.swift](../Sources/RcHarness/RemoteVoiceProtocol.swift)：5–20 能力；23–59 解码；68–146 DSP；148–183 分帧与流。
- [RemoteMicrophoneOutput.swift](../Sources/RcHarness/RemoteMicrophoneOutput.swift)：192–304 调度/恢复；311 起尾音；510 起 CoreAudio。
- [RcHarnessApp.swift](../Sources/RcHarness/RcHarnessApp.swift)：136–186 HID/BLE/输出协调；198–204 Fn 点按。

## 实际执行的差分实验

同一 Swift 程序编译本项目 RemoteVoiceProtocol.swift 和固定上游 ATVVProtocol.swift，只调用已阅读的纯解码/分帧函数。固定伪随机种子 0x52434841524e4553，每段设置合法随机 predictor/step index，使用 RC003 高半字节优先顺序。

```text
PASS: RC003 high-nibble-first ADPCM matched for 240000 samples across 100 seeded streams and varied synchronization states
PASS: fragmented BLE framing and decoded PCM matched for 20 streams
```

实验保存在 `.build/audio-protocol-comparison/main.swift`，只读上游文件在 `.build/remote-mic-source/`。此结果不包含 DSP、真实 BLE 到达率、驱动回环或听写准确率；没有运行上游完整测试套件。

## 建议顺序

1. **先补链路诊断。** 每会话记录有界元数据：回调字节、完整帧、SYNC 丢弃半帧、解码/路由/排队/已播样本、按键/START/STOP/首 PCM/最后播放时间。默认不存音频，日志应能从 Finder 启动的应用中取出。回调覆盖率不能独立证明无线丢包。[U7]
2. **补首包和取消保护。** 区分协议 ready、用户允许录音、活动流、取消/STOP 保护；有条件地缓存或接纳早到音频，拒绝前次会话晚到数据。先用注入的控制/音频事件序列测试，再由实机日志确定窗口。[U2][U3]
3. **输出移到串行队列。** 以配置完成且设备绑定正确作为 ready；缓存首音，取消能使旧配置结果失效。保留有限恢复和新播放图策略，加 ObjC 小桥保护 play() 异常。[U4][U5]
4. **补 Fn 目标启动和系统生命周期。** 对常用语音应用测量录音启动耗时，明确何时放首包、结束点按；增加睡眠唤醒和缓存设备失效后的回退。[U2][U6]
5. **按需兼容其他驱动。** MiRemoteV 2ch 把 BlackHole transport 改报 USB，会被当前仅允许自有 UID 或 Virtual 的筛选排除。如需共用，应验证明确身份后加入兼容列表，不放开全部 USB 声卡。当前没有证据要求立即替换自带驱动。[U8]

对“无法写入遥控器音频”，直接相关的是第 1、3 项；第 2、4 项主要改善丢句首、取消竞态、首按无声。更换 ADPCM 算法或加强降噪没有证据能解决引擎停止。

## 固定源码来源

- [U1 · ATVV、ADPCM、分帧、PCM 处理](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/ATVVProtocol.swift)
- [U2 · 蓝牙链路与控制/音频时序](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/XiaomiBluetoothBridge.swift#L934-L1133)
- [U3 · 蓝牙生命周期与 session gate](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/BluetoothLifecycle.swift)
- [U4 · 输出配置、调度、健康检查](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L898-L1181)
- [U5 · Objective-C 异常桥](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/AudioExceptionGuard/AudioExceptionGuard.m)
- [U6 · Fn 点按会话/pre-roll/排空](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/VoiceFnTapSessionController.swift)
- [U7 · 逐段诊断](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/ATVVAudioDiagnostics.swift)
- [U8 · transport USB 补丁](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/third_party/blackhole/blackhole-device-usb.patch)
