# 自动保存性能记录

2026-11-10，本机 Apple Silicon、SwiftPM Debug 构建。使用隔离的 UserDefaults suite，不修改真实用户配置。

数据为 1,000 条常用语，每条正文 8,192 字节（ASCII，总正文约 7.8 MiB），在第一条正文末尾连续追加 40 个字符。计时覆盖实际 `RemoteDashboardModel.phrases[0].text` setter，包括属性观察器、集合编码和 UserDefaults 提交；分别测量旧版分键存储，以及配置导入后的完整快照存储。

| 存储路径 | 修改前编辑中位耗时 | 修改后编辑中位耗时 | 修改后 P95 | 连续 40 次编辑的写入次数（含最后 flush） | 修改后单次 flush |
| --- | ---: | ---: | ---: | ---: | ---: |
| 分键存储 | 25.07 ms | 0.026 ms | 0.042 ms | 40 → 1 | 26.89 ms |
| 导入后快照 | 122.34 ms | 0.023 ms | 0.059 ms | 40 → 1 | 134.76 ms |

这里测量的是主线程编辑回调，不包含完整 SwiftUI 重绘、真实键盘输入到屏幕显示的延迟，也不等同于磁盘同步耗时。单次保存仍在主线程编码整个已变更集合和外层快照；本次只合并重复编码与写入，没有改存储格式或增加后台并发。极大配置的单次保存成本仍存在。

复测命令：

```bash
RC_HARNESS_AUTOSAVE_BENCHMARK=/tmp/rcharness-autosave.json \
  swift test --filter SettingsAutosaveTests.testLargeConfigurationEditingBenchmark
```

此性能测试默认跳过，避免每次单元测试都运行大数据计时。它记录中位数、P95、最大值、编辑期间及 flush 后写入次数，不使用易受机器负载影响的耗时阈值作为功能断言。定时行为使用注入的 `RemoteVoiceSessionController.Scheduler` 与 `TestClock` 验证；另有真实 SwiftUI `TextEditor`／`TextField` 测试验证绑定即时更新以及原生失焦通知触发保存。导入、初始化迁移、切换型号、删除／撤销、切页和窗口关闭均有持久化回归检查。
