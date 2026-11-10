# 项目审查与测试补全 · 2026-11-10

审查对象为当前工作区（含未提交、未跟踪的源码和测试），依据 `AGENTS.md`、`docs/behavior.md` 和实际调用链检查。沿规范与行为两条轴分别审查；重点覆盖配置导入／恢复／删除撤销、常用语、嵌套宏、HID 身份与手势、事件注入及音频状态机。本次确认并修复 1 项行为缺陷，新增 20 项测试，另将 13 项现有音频测试改为可控时钟。

工作区原有改动保留。产品代码只在 `RemoteDashboardModel.selectRemoteProfile` 增加清理预览的调用；未调整音频实现、UI 布局、签名配置或依赖，未安装应用或驱动。

## Standards · 规范审查

本轮检查未确认新的规范违规。检查的 HID、手势和常用语控制器保持主线程隔离；设备身份复用 `RemoteProfile`，合成事件使用注入出口，新增连删定时使用 Scheduler，日志沿用 `Log`／`AudioDiagnostics`，驱动共享常量和签名配置未变更。规范轴不将命名、重复代码等主观风格意见列作缺陷。

现有音频测试中的 `Task.sleep` 依赖机器调度速度，不能精确断言超时边界。本轮将 `InputAndAudioTests` 的 12 项测试及 `VoiceSessionTests` 的 1 项集成测试改为注入 `TestClock`；播放完成仍通过主队列回调，测试只等待已提交的回调完成，不等待墙上时钟。新增截止时间前后的断言，验证不能提前释放按键或启动播放器。真实后台构造与 OS 进程／HAL 集成测试仍使用各自的同步机制。

## Spec · 行为审查

### F1 · P2：往返切换遥控器后，旧导入／恢复预览仍可确认（已修复）

文档要求：“更换遥控器后需重新选择文件。”

修复前，`selectRemoteProfile` 保留 `pendingConfigurationImport`；确认时只比较当前型号与预览记录的型号。操作“型号 A 打开预览 → 切换到 B 并编辑 → 切回 A → 确认旧预览”会重新满足型号检查，覆盖切换期间的新配置，并替换恢复备份。普通导入和恢复预览均受影响。既有测试只验证停留在 B 时不能确认，遗漏了往返路径。

新增回归测试在修复前出现 10 个失败断言（1 个测试方法分别遍历导入与恢复路径），确认旧预览可以提交、配置和备份被更换。修复在成功切换型号时立即调用 `cancelConfigurationImport()`；同型号重选和无效型号请求仍保持有效预览。行为文档同步明确：切回原型号也不能复用旧预览。

回归测试：`ConfigurationImportTests.testRemoteRoundTripInvalidatesImportAndRecoveryPreviewsPermanently`、`testSelectingCurrentOrUnknownRemoteKeepsAValidPreview`。断言覆盖预览立即关闭、旧 ID 返回 `.stalePreview`、当前配置／恢复备份保持不变、拒绝确认不产生存储写入。

其余检查的行为未发现另一项证据充分且已复现的缺陷；这不代表已穷尽所有运行路径。

## 测试补全

| 范围 | 新增测试方法 | 覆盖行为 |
|---|---:|---|
| 配置导入／恢复 | 2 | 往返切换永久作废预览；重选当前或未知型号保留有效预览 |
| 音频输出状态机 | 7 | 健康设备通知保留播放器与音频；不健康通知按序重播；迟到健康回调隔离；空闲播放器失效与按需重建；排空超时只释放一次；准备及热复用时 flush 失败；重复完成回调不重复消费样本 |
| PCM／ADPCM 边界 | 7 | 重播插入与样本预算；超大包及非正预算；不同包长保留相同尾音；饱和与非法步长索引；360 字节流的全部 359 个通知拆分位置；同步丢弃半帧并应用预测值；重启清除半帧、预测器及统计 |
| 多键连删 | 2 | 取消一个输入不影响另一个；强制调用取消的连删／长按回调不污染新手势 |
| HID 身份 | 2 | 空白及控制字符型号只在唯一实体时使用 BLE 确认；多个实体中的未知设备不能借用另一台型号 |
| **合计** | **20** | 测试事件使用注入出口，配置使用独立 UserDefaults suite |

新增文件：`tests/RcHarnessTests/AudioBufferBoundaryTests.swift`。其余测试沿用各自现有测试文件及模拟播放器，测试辅助函数集中在 `TestSupport.swift`。

## 验证与范围

- 基线 `scripts/test_all.sh`：388 项 Swift 测试，0 失败，1 项跳过；HAL ASan/UBSan、Objective-C 异常保护、12/12 次音频输出探针均成功。
- 修复及补测后的完整 `scripts/test_all.sh`：408 项 Swift 测试，0 失败，1 项跳过；HAL ASan/UBSan、Objective-C 异常保护、12/12 次音频输出探针均成功。
- 跳过项为显式启用的 `SettingsAutosaveTests.testLargeConfigurationEditingBenchmark`，需要设置 `RC_HARNESS_AUTOSAVE_BENCHMARK`；本轮未运行性能基准，未将测试耗时变化作为性能结论。
- `git diff --check` 通过。未修改 UI 布局，因此本轮未构建签名应用或导出设置页截图。
- 未重新执行各款实体遥控器的无线重连及第三方语音应用端到端验收；音频探针的成功范围为本机输出链路。

本机证据保存在被 Git 忽略的审计目录：[基线](audits/2026-11-10/baseline.log)、[修复前复现](audits/2026-11-10/import-reproduction.log)、[修复后全套检查](audits/2026-11-10/test-all.log)。[本轮补丁](audits/2026-11-10/changes.patch) 相对修改前工作区快照生成，仅包含本轮源码、测试与行为文档修改，便于从原有未提交内容中独立核对；不含本审查记录文件。

规范轴：0 项已确认的新违规；行为轴：1 项 P2，已修复并保留回归测试。
