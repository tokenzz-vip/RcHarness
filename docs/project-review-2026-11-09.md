# RcHarness 项目审查 · 2026-11-09

审查对象是整个当前工作区，包含未跟踪的实现、测试、驱动及构建脚本；不是相对 HEAD 的增量审查。规范依据为 AGENTS.md 和 docs/behavior.md，参考了 11 月 6 日审计的修复记录。审查阶段没有修改产品代码、签名配置或系统 HID 映射，没有安装应用或驱动。下文 F1–F4 与 O1 保留修复前证据；后续修复见文末记录。

结论：现有状态机、事件注入、音频恢复和回归测试已经提供了较好的基础。本次确认 4 个边界缺陷，另用计数验证了配置重复写入。建议先处理键位恢复和快捷键冲突，再做配置保存优化；现有证据不支持为了性能全面改写音频算法或 UI。

## 已确认的问题

### F1 · P2：扩大按键接管范围后，会恢复过期的第三方键位

位置：[RemoteVolumeSuppression.swift](../Sources/RcHarness/RemoteVolumeSuppression.swift#L376)，尤其已有 snapshot 的 sources 扩展逻辑。

当两只同 VID/PID 的小米设备尚未取得型号时，worker 可以先只抑制语音键。若其他工具此时把普通方向键从映射 A 改为 B，随后型号确认使同一 service 升级为全量抑制，代码会正确以 B 为当前 baseline，却只扩大 snapshot.sources，没有更新新接管 usage 的 snapshot.original。退出恢复时因此恢复成 A，覆盖了本工具接管普通按键之前已经生效的 B。

隔离复现包含两只不同 LocationID 的模拟服务、型号从未知变为已确认、接管前的外部改键、正常 EOF 恢复。worker 返回成功，但最终 up 的 destination 是 `0x700000004`，应保留的值是 `0x700000005`。未调用真实 hidutil。

建议：按 usage 保存取得所有权时的基线。扩大范围时，旧范围继续保留旧基线，新增加的 sources 从当时 baseline 合并进入恢复日志；日志必须先于系统写入提交。补充“语音保护 → 全量保护 → 恢复”以及中途写入失败的测试。

### F2 · P2：按住普通键时，同键码的不同快捷键会被静默吞掉

位置：[SystemEventSender.swift](../Sources/RcHarness/SystemEventSender.swift#L220)。

HeldKey 虽然包含修饰键和事件来源，真正决定是否发送 down 的 wasHeld 却只比较 keyCode。先按住 Enter，再触发独立的 ⌘Enter 录制快捷键，第二次调用只修改持有计数，没有发出任何带 Command 的 keyDown；这次动作完全消失。遥控器多键并用、普通按键和组合动作重叠，或者语音触发与其他快捷键共用键码时均可进入此分支。

隔离测试通过 postEvent 收集事件，确认没有 ⌘Enter 的 down；测试没有向桌面会话发送按键。

建议：区分“持续持有的输出所有权”和“要执行一次的快捷键动作”。明确相同键码、不同修饰键发生冲突时的执行策略，并保留最后一个持有者才释放的约束。单纯删除 wasHeld 判断会破坏已有共享按键保护，不能直接这样修。

### F3 · P2：旧 Harness 迁移遗漏初始化标记，会重新绑定用户已解绑的方案

位置：[HarnessConfiguration.swift](../Sources/RcHarness/HarnessConfiguration.swift#L61)，以及 normalizeProfiles 中默认方案初始化逻辑。

migratingRetiredBuiltIn 把 Antigravity 替换为 DeepSeek 时复制了启用状态、profileID 和旧映射，但没有复制 didInitializeDefaultProfile。对于带有“已初始化、主动解绑”状态的旧配置，替换后的标记变为 false；normalizeProfiles 随即重新创建并绑定 DeepSeek 默认方案。

隔离测试导入合法的 v3 结构，使用 `didInitializeDefaultProfile = true`、`profileID = nil` 的旧 Harness，导入后 DeepSeek 的 profileID 变为非空。该问题仅涉及包含这一状态的旧配置；未声称所有历史版本都产生过这组数据。

建议：迁移保留初始化意图，覆盖已绑定、主动解绑、停用三种状态。v4 中初始化标记还存于各型号的 initializedHarnessIDs；应同时检查旧 Harness ID 在该结构中的迁移，避免仅修单一入口。

### F4 · P2：配置导入绕过方案名称唯一性约束

位置：[RemoteDashboard.swift](../Sources/RcHarness/RemoteDashboard.swift#L516)，[RemoteDashboardModel+Configuration.swift](../Sources/RcHarness/RemoteDashboardModel+Configuration.swift#L30)。

新建、重命名会校验名称，但导入后的 normalizeProfiles 只按 UUID 去重，不处理空名称或忽略首尾空格、大小写后的重名。导入两个不同 UUID 的 `Work` 和 ` work ` 会被接受，造成同一遥控器内出现难以区分的选择项。macros 已有 normalizingNames，profiles 缺少对应处理。

隔离测试导入 v3 配置后，归一化名称数量为 7，方案数量为 8，重复项仍存在。

建议：在初始化和导入的共同入口对每个型号的名称做归一化；保留 UUID、映射与绑定，重名时添加序号，并向用户说明修复结果。保留内置方案名称保护规则。

## 优化建议

### O1 · 优先：让配置变更一次提交，避免前台切换时重复编码全部配置

位置：[RemoteDashboard.swift](../Sources/RcHarness/RemoteDashboard.swift#L408)，以及 selectedHarnessID / selectedProfileID 的 didSet 和 persistRemoteKeyConfiguration。

即使已经处于默认方案，matchApplication 对每次未匹配应用的激活仍再次赋值相同的两个 selected ID。两个 didSet 各自重新构造、JSON 编码并写入所有型号的配置。

计数复现：在完全相同的默认选择下调用 100 次 matchApplication，记录到 **200 次 remoteKeyConfigurations 的 UserDefaults.set**。这是编码及偏好设置调用次数，不等于 200 次物理磁盘写入，也不是实际用户使用频率的性能基准。

建议先做成本很低的改动：值不变时不赋值；一次方案切换统一提交当前选择。随后把配置持久化收进一个拥有事务边界的 store，减少 profiles、harnesses 与每型号配置之间的重复保存。保留旧键的迁移兼容，避免一次性更换备份格式。

### O2 · 优先：缩小主线程对音频队列同步等待的范围

位置：[CoreAudioRemoteMicrophonePlayback.swift](../Sources/RcHarness/CoreAudioRemoteMicrophonePlayback.swift#L33)、schedule、stop、flush；[AudioDeviceCatalog.swift](../Sources/RcHarness/AudioDeviceCatalog.swift#L47)。

引擎创建已经移到专用队列，但运行中的 health 查询、PCM 转换与 scheduleBuffer、stop 和 HAL flush 仍由主线程通过 engineQueue.sync 等待。catalog 也在持锁期间枚举 HAL，主线程读取缓存时可能等候正在进行的枚举。底层调用变慢时，UI、HID/BLE 回调和放在主队列的超时任务会一起延迟。

这是源码确认的阻塞路径；本次音频探针全部成功，未复现真实设备导致的卡顿，不能据此宣称已有可量化性能故障。

建议：播放队列异步接收 PCM，完成后回主队列确认；用线程安全快照读取就绪/中断状态，保留配置变化后的真实健康检查。teardown 与 flush 的完成语义需要与现有 generation、尾音排空和后续会话隔离一起设计，避免把同步等待移除后引入跨会话清空。catalog 的 HAL 枚举与快照发布也宜分开。

### O3 · 中期：将宏执行调度从 App delegate 抽成可测试组件

位置：[RcHarnessApp.swift](../Sources/RcHarness/RcHarnessApp.swift#L435)。

MacroExecutionPlan 的展开、循环检测和步骤上限有单测，但实际执行器仍在 App delegate 中直接创建 DispatchWorkItem、使用 DispatchTime.now 和 asyncAfter。现有 Scheduler/TestClock 没有覆盖执行过程。

建议新增很小的 @MainActor 执行组件，注入现有 Scheduler 和事件出口；App delegate 只接线。重点验证执行新宏会取消旧宏、原生模式/断连取消待执行步骤、同一时刻步骤顺序、取消后的旧回调。这也是仓库定时注入约定目前尚未覆盖的生产路径。

### O4 · 中期：常用语编辑合并保存，补齐长期数据增长策略

位置：[RemoteDashboard.swift](../Sources/RcHarness/RemoteDashboard.swift#L44)、[PhrasesPage.swift](../Sources/RcHarness/PhrasesPage.swift#L21)、[SettingsState.swift](../Sources/RcHarness/SettingsState.swift#L189)。

TextField / TextEditor 直接绑定 phrases，每次文字更新都会在主线程编码并保存全部常用语。UsageStore 已合并写入，但历史天数和每日最长语音记录会持续增长，每次保存依然编码完整历史。

建议常用语沿用合并保存思路，页面关闭、导出、休眠和退出时 flush；统计先增加较长历史的大小/耗时基准，再决定是否按月归档。当前无数据证明需要引入数据库或第三方依赖。

### O5 · 交付检查：项目实现尚未纳入 Git 跟踪

本次 `git ls-files` 仅列出 LICENSE 和 README.md；Package.swift、Sources、Drivers、tests、scripts、.github 等均未跟踪。只提交 README 或只审 git diff 会遗漏整个可运行项目，CI 配置也不会进入远端。发布前应明确加入项目文件，并检查构建产物及审计资料的提交范围。本次未替用户暂存或提交。

## 验证与复现方法

- 基线验证：scripts/test_all.sh 通过，Swift **267/267**、HAL ASan/UBSan、Objective-C 异常保护、音频输出 **12/12** 会话均成功，无跳过。
- 隔离复现：包含 F1–F4 的 4 个行为断言，以及 O1 的写入计数断言。
- F1–F4 复现结果：4 个测试各触发 1 个失败断言，展示当前缺口。
- O1 计数结果：100 次无状态变化的匹配产生 200 次全量配置写入调用。

修复前隔离复现得到上述 5 个失败断言。公开仓库以 [正式回归测试](../tests/RcHarnessTests/ProjectAuditBoundaryTests.swift) 为复现入口，运行 `swift test --filter ProjectAudit` 可验证修复。复现中的 UserDefaults 使用独立随机 suite，HID 使用内存模拟，事件通过注入出口收集；没有真实等待，也没有向用户桌面发送按键。

审查阶段未修改 UI，因此未构建签名应用或导出新截图；未执行会激活 GUI fixture 的可选 Harness 激活探针，也未逐款实物验证无线重连、按键抑制和第三方语音应用识别。现有音频探针的通过范围是输出链路，不能替代端到端收音验收。

建议实施顺序：F1 → F2 → F3/F4 → O1 → O3 → O2；O4 依据实际数据规模推进，O5 在交付前完成。

## 修复记录 · 2026-11-09

已修复 F1–F4 和 O1，保持音频状态机及宏调度架构不变，未新增依赖、修改签名配置或安装应用/驱动。

- F1：范围扩大时，仅将新接管 usage 的当前映射合并入恢复基线；先提交日志，再写 HID。覆盖原映射被改写、被删除以及系统写入前/后失败的恢复。
- F2：同键码的不同普通按键组合分别发送按下；一次性快捷键及截图在重叠时仍执行，但不抢占已有输出的释放。保留共享修饰键引用计数和首次事件来源，最后一个持有者才松键。
- F3：迁移保留已初始化标记；版本 4 所有遥控器的旧 Harness ID、绑定、主动解绑及选择同步迁移。先迁移应用元数据再读取每型号绑定，已有替换应用的明确绑定/解绑优先。
- F4：所有型号的方案名称在加载和导入时归一化，保留 ID、映射、绑定和顺序，避开已有序号。先完成旧内置方案改名，再处理重名；自动改名的内置方案保存可选的来源标记，保留解绑后的删除保护和默认映射恢复，普通自建序号名称不受影响。备份保持版本 4，旧文件无需此可选字段；导入按实际结果提示改名数量。
- O1：方案选择统一提交；100 次相同默认匹配由 200 次全量保存调用降为 0 次，相同 Harness 匹配也为 0 次，实际切换一次保存 1 次。这里仍指 UserDefaults 调用次数，并非物理磁盘写入或耗时基准。

新增 19 项正式回归测试，原有测试保持原断言。完整 `scripts/test_all.sh`：Swift **286 项、零失败、无跳过**（含原有 GUI 焦点集成测试），HAL 驱动 **ASan/UBSan 通过**，Objective-C 异常保护通过，音频输出 **12/12** 会话成功。专项覆盖方案切换后的持久化/重启、所有型号的备份迁移、内置方案保护、共享按键释放、Fn 事件来源及故障恢复；测试使用隔离偏好设置和事件注入。

发布版构建产物为 `.build/ProjectAuditFix/RcHarness.app`。构建前确认本机配置的固定证书为有效身份；构建后分别提取应用与随包 HAL 驱动的叶证书，SHA-1 均与该固定身份一致，并分别通过 `codesign --verify --deep --strict`。只生成工作区构建产物，未安装或替换正在使用的应用/驱动。没有修改 UI 布局文件，本轮未导出页面截图。

原始构建日志、故障注入归档与工作区补丁仅作本地审计材料，不随公开文档发布；验证结论和正式回归入口已列于本文。

回归源码：[边界与恢复](../tests/RcHarnessTests/ProjectAuditBoundaryTests.swift)、[快捷键与配置兼容](../tests/RcHarnessTests/ProjectAuditRegressionTests.swift)。行为文档已同步。O2/O3 属于需要单独设计及实机验收的结构调整，O4 尚缺耗时证据，本轮保留为后续建议；O5 的 Git 跟踪状态未替用户修改。真实遥控器的无线连接及第三方语音应用端到端输入未重新进行现场验收。
