# remote-mic-app 音频输出与恢复对照 · 2026-10-28

研究快照：HD838A/remote-mic-app `main` 的 `2ce3ec65b02b2746109da267bc9a6eee04ec516b`。对照 RcHarness 当前工作区，包含本次已经安装的 100 ms 延迟启动和每会话最多两次重建修复。仅研究源码与已有本机证据；未运行上游应用、上游测试或安装其驱动。本文件不修改业务实现。

## 直接结论

双方的小米语音主链都把 16 kHz、单声道 Int16 PCM 转成 Float32，交给 `AVAudioEngine + AVAudioPlayerNode`，通过明确选定的回环设备供听写软件读取。上游并没有绕开 AVAudioEngine；其优势主要是独立音频队列、就绪门禁、完整健康检查、异常隔离和诊断，而不是不同的输出原理。证据：[源格式](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L846-L851)、[创建与绑定播放图](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L988-L1055)、[转换与调度](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L1109-L1180)；本地 `Sources/RcHarness/RemoteMicrophoneOutput.swift:511–575`。

上游也曾遇到“设备绑定正确、引擎停止、不断重新绑定”的配置变化循环，并保存对应状态回放测试。不能仅凭代码规模或项目宣传就断言它在本机更稳定。证据：[上游故障记录](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Tests/RemoteMicTests/AudioConfigurationChangeRecoveryTests.swift#L8-L27)、[状态回放测试及未驱动真实 HAL 的边界](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Tests/RemoteMicTests/AudioConfigurationChangeRecoveryTests.swift#L94-L118)。

## 机制差异

| 方面 | remote-mic-app 固定快照 | RcHarness 当前实现 | 判断 |
|---|---|---|---|
| 初始化线程 | `configureAsync` 在独立串行 `engineQueue` 进行枚举、HAL 绑定、prepare/start | BLE 回调与创建/绑定仍在主队列；只把 start 延后 100 ms | 应借鉴独立队列；固定延时不能防止 HAL 调用本身阻塞主线程 |
| 开始就绪 | 检查 engine running、player playing、实际输出绑定、支持驱动的 mute/volume；配置 completion 回来后发送缓存 | `begin` 提前发布 streaming；延时期间缓存，`schedule`主要检查 engine running | 应把 preparing 与 ready 分开，并验证实际设备及 player |
| 首包等待 | 配置门禁缓存最多 8000 个样本，超出丢旧；成功 completion 后再 route | 总待播上限 8000，最多同时调度4个buffer；新图等待100ms再start | 两者均有约0.5秒容量，但边界不同：上游是配置/命令激活缓存；我方包含已调度未确认播放的音频 |
| 配置恢复 | 系统设备/默认路由 + engine 通知，1秒合并去抖，再按绑定、健康、活跃源、pending判断是否重配 | engine 停止通知或失败写入触发，50ms后新建图，再100ms启动，每会话最多两次 | 上游侧重状态判断及防空闲恢复循环；我方侧重本次首包竞态与有限次续传 |
| 播放图重建 | configure先stop旧图，重新实例化engine/player | 同样销毁旧图，使用全新engine/player | 我方本次修复方向与其重配方式一致 |
| Objective-C异常 | `player.play` 经 `.m` 的 `@try/@catch` 转为Bool | 仍直接 `player.play()`；Swift `throws`无法捕获NSException | 新图降低旧节点重启风险，但不等于建立异常边界；值得补上 |
| 配置重建中的旧音频 | stop把pending计为interrupted并清零；VirtualAudioOutput层未保存原PCM重放 | 以buffer为单位重放未确认播完PCM，旧回调由generation隔离 | 我方在此并非落后；需明确中断在buffer中段时可能重复少量已播片段 |
| 尾音结束 | `.dataPlayedBack`记账，normal/forced结果；默认0.75秒期限；stop/flush也恰好完成一次等待者 | 同样以播放回调记账，排空后额外50ms；1秒超时；取消释放语音键 | 双方都不是收到BLE STOP就直接丢尾音；上游结果类型和诊断更细 |
| 睡眠/设备变动 | NSWorkspace睡眠/唤醒/会话事件 + CoreAudio设备与路由监听 | 没有对应系统生命周期/路由监听；主要依赖BLE/HID和engine通知 | 是独立于本次首包修复的恢复缺口 |
| 测试音 | 完成回调报告实际播放完成/取消 | Dashboard定时分块，1.2秒后stop，缺少与主输出一致的状态回传 | 应让测试音反馈覆盖写入与实际播放失败 |
| 诊断 | 持久AppLogger、配置阶段耗时、实际/选择设备、排队时间、逐会话scheduled/played/interrupted/dropped | 基本依赖print与样本总数，应用从Finder启动时stdout可能不可见 | 优先补诊断，才能分清未收到BLE、未解码、未就绪和播放中断 |

对应源码：

- 独立队列与配置分步：[engineQueue与configureAsync](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L860-L919)、[完整配置阶段](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L924-L1055)。
- 就绪健康定义与读取：[健康策略](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L706-L725)、[engine/player/actualDevice检查](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L1717-L1753)。
- 配置首包缓冲：[8000样本缓冲](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/BridgeAppModel.swift#L328-L359)、[未就绪时建立缓存](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/BridgeAppModel.swift#L5950-L5956)、[ready后route并处理早到STOP](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/BridgeAppModel.swift#L6134-L6170)、[门禁期间收包及溢出记账](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/BridgeAppModel.swift#L6359-L6372)。
- 配置恢复：[避免自激恢复循环的策略](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L677-L703)、[CoreAudio硬件监听](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/BridgeAppModel.swift#L2940-L2969)、[1秒合并及恢复决策](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/BridgeAppModel.swift#L2987-L3105)。
- 新图和异常：[先停止旧图](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L936-L938)、[新建engine/player与安全play](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L988-L1042)、[Objective-C异常隔离](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/AudioExceptionGuard/AudioExceptionGuard.m#L1-L10)。
- 中断不等于播放完成：[stop记interrupted并清零](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L1378-L1425)；本地 `RemoteMicrophoneOutput.swift:264–303`保存并重放pending。
- 尾音/测试音：[测试音播放回调](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L1076-L1100)、[排空等待与期限](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L1188-L1265)、[播放记账及normal完成](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L1428-L1499)、[forced期限结果](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L1502-L1524)。
- 睡眠事件：[安装NSWorkspace监听](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/RemoteMicApp.swift#L448-L469)、[睡眠/会话恢复](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/BridgeAppModel.swift#L2778-L2847)。
- 诊断：[输出快照及延时](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L1620-L1687)、[端到端计数与归因](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/ATVVAudioDiagnostics.swift#L431-L519)、[持久日志分段及清理](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AppLogger.swift#L365-L475)。

## 虚拟麦克风驱动：具体兼容缺口

上游发行驱动名为 `MiRemoteV2ch`，品牌名称可为 `SayAll`，底层固定为 BlackHole `v0.7.1` / `e2b22aaaba4e507a097131704bf96dabc004d9cf`，2通道。不是项目自己重新实现的简化48k专用HAL。证据：[版本/提交/构建参数](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/scripts/build-doubao-driver.sh#L6-L15)、[拉取校验及品牌命名](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/scripts/build-doubao-driver.sh#L96-L115)。

其补丁把设备的transport从Virtual改为USB；这是回环驱动呈现策略，不能据transport=USB就推断为物理声卡。RcHarness 当前候选条件为双向且“自有UID或Virtual transport”，所以会拒绝/隐藏这个USB呈现的回环设备。建议若需要兼容对方驱动，增加精确UID或可靠驱动特征白名单，例如保留 `MiRemoteV2ch_UID` 身份识别；不要放开全部USB输入输出设备。证据：[transport补丁](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/third_party/blackhole/blackhole-device-usb.patch#L1-L12)、[上游按UID分类](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L85-L96)；本地 `RemoteMicrophoneOutput.swift:10–11,494–507`。

另外，上游当前音频输出列表并未限制为双向虚拟设备：枚举条件是输出通道>0，去掉进程私有aggregate与重复UID，`publishAudioDevices`直接发布。这点比RcHarness的限制更宽，不能整体照搬其设备筛选。证据：[输出设备枚举](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/AudioOutput.swift#L214-L271)、[发布输出列表](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Sources/RemoteMic/BridgeAppModel.swift#L2638-L2660)。

上游驱动默认48k，但BlackHole固定源码还支持8k、16k、24k、44.1k、48k等13种采样率；构建脚本未覆盖采样率宏。RcHarness的HAL只提供48k双声道Float32，16k单声道由AVAudioEngine转换。不能将“默认48k”说成双方都“固定48k”。来源：[BlackHole固定源码](https://github.com/ExistentialAudio/BlackHole/blob/e2b22aaaba4e507a097131704bf96dabc004d9cf/BlackHole/BlackHole.c#L267)、[可用采样率](https://github.com/ExistentialAudio/BlackHole/blob/e2b22aaaba4e507a097131704bf96dabc004d9cf/BlackHole/BlackHole.c#L324-L328)；本地 `Drivers/RcHarnessMicrophone/Driver.c:18,56–64,285–294`。

RcHarness的驱动另有自身有价值的约束：逐帧时间戳、epoch清空、250ms新鲜度、连续时钟防休眠旧数据复活、原子读写；不能仅因上游用BlackHole就判定应该立即换驱动。已读源码事实是实现不同，延迟、兼容性、音质孰优仍需同设备同音频的真实读回测试。本地证据 `Drivers/RcHarnessMicrophone/Driver.c:46–51,238–241,296–322,343–372`。

## 对本次修复的评价与建议顺序

1. 本次100ms延后和有限次全新图恢复已用本机HAL对照获得“旧时序8/12失败，修复0/12”的证据；该结果来自本项目已有诊断记录，不是本研究新测。它验证本机首包启动窗口，不能替代实际听写首字/尾音、长会话、唤醒的验证。上游没有同样固定100ms策略。
2. 优先增加可持久读取的逐会话诊断，以及独立串行音频执行队列和明确ready门禁。采集/解码、配置缓存、调度、播放回调必须能对上样本数。
3. 增加ObjC异常桥接及engine/player/actual-device联合健康检查；保留当前“不直接复活旧播放器”的策略。
4. 按状态合并配置变化和系统唤醒事件，避免空闲自激重建；保留恢复次数/期限，避免无限重试占住Fn。
5. 如要引入MiRemoteV作可选对照，先修精确UID兼容，再分别实测自有HAL、BlackHole和MiRemoteV；当前没有足够证据要求替换自有HAL。

上述是基于源码的改进建议，本轮未实施。上游自带的真实验收手册也明确区分状态测试与真实遥控器/第三方App验收：[上游验收边界与用例](https://github.com/HD838A/remote-mic-app/blob/2ce3ec65b02b2746109da267bc9a6eee04ec516b/Testing/MiRemoteVAudioStaleRecovery.md#L1)。
