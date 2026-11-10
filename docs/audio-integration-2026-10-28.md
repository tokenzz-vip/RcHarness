# 音频融合记录 · 2026-10-28

参考 [HD838A/remote-mic-app 固定版本](https://github.com/HD838A/remote-mic-app/tree/2ce3ec65b02b2746109da267bc9a6eee04ec516b) 的设计，按 RcHarness 的输出、BLE 和按键生命周期实现以下改进。对照依据见同目录的收音与输出比较文档，它们记录的是改动前的快照。

- HAL 选设备、引擎连接和启动移到独立串行队列；保留绑定后 100 ms 稳定窗口。准备完成后同时检查 engine running、player playing 和实际输出设备，再发送最多 8000 个待播样本。主队列仍管理会话；写入、停止和清空通过串行队列同步，尚非完全异步的输出 API。
- 新增“正在准备音频设备”状态；START 后先缓冲 PCM，早到 STOP 等待准备及排空。播放图 generation 会丢弃已取消的配置回调，防止旧失败覆盖新会话。
- Objective-C 小桥捕获 `AVAudioPlayerNode.play()` 的 NSException，转成可显示的失败。保留全新播放图、每段最多两次恢复及未确认 buffer 重放；中断在 buffer 中间时，重放仍可能重复该 buffer 已播放的片段。
- 协议就绪后允许首音频隐式开启流，迟到 START 只补会话编号，不清空首包的解码状态或半帧。STOP 后 300 ms 内拒绝隐式开启；取消后 1 秒拒绝旧 START/音频。新的 HID 语音键或遥控器 SEARCH 请求重置保护。这些窗口不能从无会话编号的音频中完美区分新旧流。
- 监听 CoreAudio 设备列表变化：活跃且健康时保留当前图，失效时走有限恢复，空闲时丢弃缓存图；不在配置期间递归恢复。睡眠停止语音、宏和按键，唤醒重新发现 BLE/HID。
- 精确兼容 USB transport 呈现的 `MiRemoteV2ch_UID`，不扩大到普通 USB 声卡。保留自带 HAL。
- 测试音接收实际准备、失败与播放完成状态，移除固定 1.2 秒强制停止。选择设备或开始真实语音会取消测试音。
- 有界元数据日志记录 capture session/implicit origin、收包、字节、帧、解码样本、峰值、SYNC 丢弃半帧、首 PCM 延迟、准备耗时和输出失败计数。日志位于 `~/Library/Logs/RcHarness/audio.log`，轮转后最多两份约 512 KiB 文件，不保存 PCM 或转写。

## 验证

`swift test` 新增异步准备时首包和早到 STOP、取消后旧配置回调、无健康播放器时释放按键、隐式流补 START 后 PCM/半帧连续性、STOP/取消时间窗口及精确驱动 UID 的回归。

`scripts/test_audio_output.sh` 先注入 Objective-C 播放异常验证异常边界，再通过本机已安装 HAL 连续运行 12 段静音，断言每段确认播放 1600 样本并正常排空。需要已有麦克风授权；未满足时退出码 2 跳过。`scripts/test_microphone_driver.sh` 覆盖已有驱动时钟、格式、多读者、清空和生产者退出。

本轮结果：76 项 Swift 测试通过；Objective-C 注入异常边界通过；真实 HAL 12/12 段完成；驱动测试通过。

自动化验证不能替代遥控器连续按键、轻声句首/尾音、系统真实睡眠唤醒、第三方听写应用和 MiRemoteV 驱动的实机验收；本轮不宣称识别率或音质提升。
