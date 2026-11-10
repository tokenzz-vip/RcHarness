# 音频异常条件下的主线程时延专项测量

状态：**风险仍开放，未复现异常 HAL 条件下的主线程长时间阻塞**。2026-11-10 完成正常环境基线、带待播缓冲的停止测试，以及 Instruments 采集链路验证。不能据此排除音频服务重启、设备切换、慢 HAL 或目录锁竞争导致的等待。

本轮只增加测量；generation、尾音排空、已启动图同步停止和 flush 边界保持原有语义。异步健康检查/停止和设备目录快照发布仍需异常场景证据后再设计。

## 测量边界

`AudioPerformance` 使用 `vip.tokenzz.rcharness` 子系统、`PointsOfInterest` 类别：

| 区间 | 包含的工作 |
| --- | --- |
| `Playback.call` | 调用者进入同步操作至返回，包含排队等待 |
| `Playback.work` | 同一 signpost ID 对应的音频队列闭包执行段 |
| `Catalog.devices` | 获取目录锁、缓存读取或完整枚举 |
| `Catalog.enumerate` | 锁内的完整 HAL 枚举 |
| `Catalog.invalidate` | 获取目录锁并使缓存失效 |

播放区间的 `operation` 区分 `isReady`、`isInterrupted`、`schedule`、`flush` 和已启动图的 `stop`；`main` 表示记录区间所在的实际线程。`DispatchQueue.sync` 的闭包可能直接在调用线程执行，因此 `Playback.work` 也可能标记为主线程。`call` 开始至 `work` 开始的间隔帮助定位排队；`work` 很长时结合栈定位具体 AVFoundation/HAL 调用。完整 `call` 时长才是调用方被占用的时长。

完成且耗时至少 50 ms 的区间经 `AudioDiagnostics` 写入有界元数据日志，包含操作、区间、主线程标记和毫秒数，不写 PCM、识别文字或设备名称。未返回的调用没有完成日志，需在退出前抓取线程栈。50 ms 是本次筛查预算，并非 HAL 故障判据；Time Profiler 默认 Hangs 阈值 250 ms 也不能代替这些区间。

## 正常环境基线

命令：`scripts/test_audio_output.sh --latency`。探针要求已有录音授权和已安装回环设备，否则退出 2；仅输出合成静音，不发送按键或改变默认音频设备。它使用真实主线程、生产播放实现和 HAL，探针中的 RunLoop 等待仅用于真实硬件准备和 profiler 附加，不进入单元测试调度器。

本机 macOS 26.6.2、Apple Silicon，12 轮；每轮强制重新枚举并另测缓存，准备播放图后查询健康、flush，投递 4 个各 16,000 样本的缓冲（共 4 秒），在仍有待播音频时 stop。这里压力来自较长待播音频，**没有人为阻塞 engineQueue，也没有模拟慢 HAL 或深队列 teardown**。

最终一次独立运行（未附加 profiler）的结果，单位 ms：

| 主线程操作 | n | p50 | p95 | 最大值 |
| --- | ---: | ---: | ---: | ---: |
| 目录缓存 | 12 | 0.006 | 0.008 | 0.008 |
| 目录重新枚举 | 12 | 4.130 | 4.361 | 4.361 |
| isReady | 12 | 0.030 | 0.043 | 0.043 |
| isInterrupted | 12 | 0.006 | 0.008 | 0.008 |
| flush | 12 | 0.841 | 0.993 | 0.993 |
| schedule | 48 | 3.040 | 3.381 | 3.469 |
| stop（有待播缓冲） | 12 | 32.911 | 34.716 | 34.716 |
| stop（清理时再次调用） | 12 | 0.005 | 0.009 | 0.009 |

所有操作均低于 50 ms。p95 使用 nearest-rank，12 次时即最大值，不作为尾部时延已经充分采样的证据。探针对功能失败或任何操作超过预算返回 1；原始输出保存在本机 `.build/diagnostics/audio-latency-baseline.txt`，该目录不纳入版本控制。

## Instruments 与 hang 采集

应用需先按 README 的固定证书流程构建并运行包含本轮测量代码的版本；旧安装版本仍可抓栈，但不会产生新测量区间。采集脚本不会构建、安装或重启应用。

```bash
# 默认附加 /Applications/RcHarness.app，排除音量守护子进程。
scripts/capture_audio_latency.sh 30
# 另一路径运行的应用可显式指定 PID。
scripts/capture_audio_latency.sh 30 <PID>
# 在另一终端于无响应期间、强制退出前执行；此脚本采集已安装应用。
scripts/capture_hang.sh
```

等 xctrace 提示 recording started 后触发场景。记录包含 Time Profiler 的 waiting threads 和 Points of Interest，保存在 `.build/diagnostics/audio-latency-*/audio.trace`，可在 Instruments 中打开。检查主线程等待栈，同时对齐音频队列和目录枚举区间。记录每个场景的主线程区间数量、p50/p95/max、超过 50 ms 的次数、是否存在未闭合区间及对应线程栈。

也可以独立验证探针采集，无须更换正在运行的应用：

```bash
scripts/test_audio_output.sh --latency
"$PWD/.build/audio-output-probe/probe" --latency --wait-for-profiler > .build/diagnostics/audio-latency-profiled.txt 2>&1 &
LATENCY_PROBE_PID=$!
scripts/capture_audio_latency.sh 20 "$LATENCY_PROBE_PID"
wait "$LATENCY_PROBE_PID"
```

`--wait-for-profiler` 留出 10 秒附加时间。应正常启动后附加：本机实测 Instruments 的 `--launch` 启动方式因授权不同而退出 2，该次记录已排除，不能计为通过。附加方式已成功记录真实 HAL 探针，导出的 signpost 包含成对的调用、执行和目录区间；profiler 结果与独立基线分开解读。

## 异常条件待测矩阵

| 场景 | 操作与关注点 | 当前状态 |
| --- | --- | --- |
| 音频服务重启 | 录制期间在专用测试时段重启音频服务；覆盖播放中与松键排空中，观察健康查询、恢复、stop/flush | 待测；本轮未重启系统音频服务 |
| 设备切换/断开 | 播放和排空期间切换接收设备或断开实际设备，再刷新目录；观察恢复和锁等待 | 待测；本轮未切换或断开设备 |
| 慢 HAL / 深队列 teardown | 在能产生真实积压的环境停止已启动图，关联 call/work 和等待栈 | 待测；4 秒待播静音仅覆盖正常队列的停止 |
| 目录锁竞争 | 后台 HAL 枚举与主线程刷新重叠，关联 Catalog.devices/invalidate 与另一线程的 enumerate | 待测；基线仅强制重新枚举，无竞争注入 |

在这些场景出现明显等待后，再确定异步接口与目录快照改造范围。后续验证仍须覆盖迟到回调的 generation 隔离、尾音排空、旧图停止到新图开始之间的 flush 顺序。

本轮回归：`scripts/test_all.sh` 通过，388 项 Swift 测试中 1 项跳过、0 失败，HAL ASan/UBSan 和常规音频探针 12/12 通过；signpost 类别调整后的相关 Swift 测试 45 项通过。这些结果验证测量接入未破坏现有测试覆盖的行为，不关闭上述异常条件风险。
