# RcHarness

RcHarness 是面向 Apple Silicon Mac、macOS 15 及以上版本的纯软件遥控器适配层。它直接读取 macOS 的 HID/Bluetooth 设备，把遥控器按键转换为鼠标、系统按键、应用快捷键和语音输入。

> [!IMPORTANT]
> **谷歌遥控器仅验证了拼多多（PDD）店铺「金利达数码科技大全」销售的谷歌 G9N9N 遥控器。其他店铺、批次或同型号产品尚未验证，兼容性不作保证。**

支持 Xiaomi Bluetooth Remote 2（`RC001-MS`）、Xiaomi Bluetooth Remote 2 Pro（`RC003-MS`）与 Google Chromecast Voice Remote（`G9N9N`）。在「连接与语音 → 更换遥控器…」中选择型号，切换后保留键位方案与 Harness 绑定。小米 2 与 2 Pro 共用 HID usage 映射和 ATVV BLE 语音链路，并依据 Device Information 型号严格区分；两款遥控器均支持按住说话，可同时连接，并按各物理 HID 设备的型号区分，当前仅控制所选型号。G9N9N 的适配依据、按键表和真机验收边界见 [适配说明](docs/google-g9n9n.md)。

## 当前范围

- 目标平台：Apple Silicon（arm64），macOS 15.0 及以上。
- 设备接入：遥控器通过系统 Bluetooth/HID 配对；不增加 RP2040、USB 转接板、串口桥或其他外部硬件。
- 支持方式：`RC001-MS` 与 `RC003-MS` 的按键和内置麦克风均由 Mac 软件链路处理。
- 功能范围：遥控器按键映射、鼠标/系统快捷键、应用快捷键、模式切换、截图，以及 RC001-MS/RC003-MS 的 BLE 麦克风输入。

## 明确不纳入

依赖 JoyHarness 的 RP2040 Vendor HID/CDC 链路的 Codex Micro 槽位切换、审批/拒绝、原生 `ACT10` 按住说话和硬件触觉反馈不属于 RcHarness 的首期范围。它们需要额外开发板和数据线，与本项目的纯软件目标冲突。

## 小米蓝牙遥控器 2 / 2 Pro 参考映射

普通版的接入依据、共用 HID 身份的限制与真机验证记录见 [RC001-MS 适配说明](docs/xiaomi-rc001.md)。

| 遥控器输入 | 软件动作 |
|---|---|
| 方向键 | macOS 方向键 |
| OK | Enter |
| Back | Backspace |
| Home | Escape |
| Power（默认全局按键） | 单击：打开运行 Harness 列表；双击：系统区域截图；长按：切换到原生模式 |
| Menu | 切换到原生模式（在主面板或菜单栏恢复映射） |
| Voice | 固定用于语音触发，可配置触发修饰键；默认为 Fn／地球键 |
| Custom | 可配置应用快捷键；参考实现为截图 |
| 音量 −/+ | 普通软件快捷键或应用动作；不实现依赖 RP2040 的 Codex 槽位切换 |

RC001-MS 与 RC003-MS 麦克风通过 ATVV BLE 解码为 PCM，再输出到随应用提供的 CoreAudio 虚拟输入设备。首次启用该设备需要管理员授权安装 HAL 组件；这属于软件安装权限，不是外部硬件依赖。

## 系统权限

- Bluetooth：发现并连接遥控器及其语音服务。
- Input Monitoring：应用在后台接收遥控器 HID 输入。
- Accessibility：发送鼠标移动、系统按键和应用快捷键。
- Microphone：使用遥控器语音输入时，RcHarness 和实际语音应用分别需要相应权限。

## 参考项目

- [nixihz/JoyHarness](https://github.com/nixihz/JoyHarness)：参考 RC003-MS 的 HID 按键映射、BLE 语音和虚拟麦克风链路。详细的依赖审计见 [docs/joyharness-remote-audit.md](docs/joyharness-remote-audit.md)。
- [HD838A/remote-mic-app（无线麦 SayAll）](https://github.com/HD838A/remote-mic-app)：补充参考小米蓝牙遥控器 2 / 2 Pro 的 Mac 语音输入体验与按键自定义；重点关注 ATVV BLE 连接与重连、ADPCM 解码、CoreAudio 回环音频输出，以及按住说话与 Fn 点按模式的会话处理。实现说明见其 [技术文档](https://github.com/HD838A/remote-mic-app/blob/main/TECHNICAL.md)。

## 功能

| 页面 | 当前可用内容 |
|---|---|
| 按键映射 | 遥控器图片与实时反馈、按型号展示 13／15 项输入、电源键单击、普通按键单击/双击/长按、快捷键录制、App 选择、长按／点按语音快捷键（当前三款遥控器仅可启用长按） |
| Harness | 应用绑定按键方案、多个 Harness 共享方案、当前应用切换、内置应用、启用与停用和应用运行状态 |
| 组合动作 | 编辑本机动作步骤和等待时间，并绑定到遥控器 |
| 键位方案 | 新建、复制、重命名和编辑整套按键方案，显示 Harness 绑定状态 |
| 常用语 | 从按键页进入，编辑、复制和绑定本地常用语 |
| 连接与语音 | 设备状态、回环设备选择、0–24 dB 增益、测试音、麦克风组件安装 |
| 设置 | 权限入口、配置导入导出、Dock 显示、登录时启动、主面板启动行为与诊断信息 |
| 使用统计 | 本机按键次数、语音时长、日/周/全部汇总、最近七天图表与排行 |

当前提供简体中文界面，本地构建尚未配置自动更新源。统计只保存次数、日期和时长，不记录音频或听写内容；配置只保存在当前 Mac。硬件语音链路和第三方 App 兼容性仍需实机验收。

## 代码结构

- 设备层：`XiaomiRemoteHID.swift`（IOHID 发现与 usage 解析）、`RemoteVolumeSuppression.swift`（映射模式下抑制原生键值，退出或崩溃时由辅助进程恢复）、`XiaomiRemoteVoice.swift` + `RemoteVoiceProtocol.swift`（ATVV BLE 握手、ADPCM 解码）、`RemoteVoiceConnectionController.swift`（可注入时钟的连接、候选排除和重试）。设备身份集中在 `Core.swift` 的 `RemoteProfile`，Google 型号使用独立的 Consumer usage 映射，语音键从 ATVV START/STOP 通知接入；完整原生按键抑制只作用于当前选中的型号；映射模式下，其他已连接的小米仅抑制语音键，避免触发系统听写或提示音。
- 音频层：`RemoteVoiceSessionController.swift`（语音键与 BLE 会话配对）、`RemoteMicrophoneOutput.swift`（输出状态机）、`CoreAudioRemoteMicrophonePlayback.swift`（AVAudioEngine 播放）、`AudioDeviceCatalog.swift`（带缓存的设备枚举）、`PCMBacklog.swift`（有界缓冲），以及 `Drivers/RcHarnessMicrophone` 中的 HAL 虚拟麦克风。
- 输入输出：`RemoteGestureController.swift`（单击、双击、长按）、`SystemEventSender.swift`（合成键盘、鼠标和媒体键事件）、`MacroExecutionPlan.swift`（组合动作展开）。
- 设置与界面：`RemoteDashboard.swift`（设置模型与持久化）、`SettingsKeys.swift`（所有偏好设置键）、`DashboardView.swift`（窗口框架），每个页面一个文件（`MappingPage.swift`、`ConnectionPage.swift` 等）。

界面与运行时的详细行为见 [行为说明](docs/behavior.md)。历史审计、修复与验收边界见 [审计记录](docs/remote-audit-2026-11-06.md)。RC001-MS、RC003-MS 与 G9N9N 均已完成真机验证；RC001-MS 于 2026-11-08 由用户确认，记录见 [RC001-MS 适配说明](docs/xiaomi-rc001.md)；G9N9N 的 15 项实体输入已于 2026-11-07 逐键验证，记录见 [适配说明](docs/google-g9n9n.md)。已实测状态保留在诊断和文档中，连接页及型号菜单不再显示验收提示。

## 构建与测试

在 Apple Silicon Mac 上：

当前版本使用 Xcode 27.1 / Swift 6.4 验证；CI 和 Release 工作流固定使用同一工具链。应用的最低运行系统仍为 macOS 15。`v0.1.1` 的隐式成员初始化器依赖 Swift 6.4 的访问控制规则，不能使用 runner 默认的 Xcode 16.4 构建。

```bash
scripts/test_all.sh
```

```bash
scripts/build_app.sh .build/RcHarness.app
```

```bash
open .build/RcHarness.app
```

`test_all.sh` 依次运行 `swift test`、HAL 驱动测试（ASan/UBSan）和音频输出探针；没有麦克风权限或未安装回环设备时，探针自动跳过。CI（`.github/workflows/ci.yml`）在每次推送和 PR 时运行同一脚本并打包。

运行列表的真实窗口焦点测试需要至少一块亮屏的显示器；无显示器或全部熄屏时，该项会明确标记为跳过，其余测试继续执行。亮屏后可用 `swift test --filter HarnessSwitcherTests.testControllerRepeatedlyPresentsAVisiblePanelFromTheBackground` 单独复验，仍会检查普通应用和菜单栏模式下反复打开浮层的可见性及键盘焦点。

无需启动设备监听即可导出所有页面截图，用于布局检查；此模式使用临时偏好设置，不改写日常配置：

```bash
.build/RcHarness.app/Contents/MacOS/RcHarness --render-settings /tmp/rcharness-pages
```

```bash
.build/RcHarness.app/Contents/MacOS/RcHarness --render-settings /tmp/rcharness-pages-dark --dark --narrow
```

### 打包与签名

- `build_app.sh` 默认生成 Release、arm64、最低 macOS 15 的 `.app`，并把虚拟麦克风组件放入 `Contents/PlugIns`。`RC_HARNESS_CONFIGURATION=debug` 生成调试版本。脚本完成打包和签名校验后才替换旧包；输出必须是 `.app`，已存在的包必须属于 RcHarness，且不能是符号链接。
- 版本号以 `Sources/RcHarness/Info.plist` 为唯一来源，界面从应用包读取。发布时可用 `RC_HARNESS_VERSION` 和 `RC_HARNESS_BUILD` 覆盖。
- 应用图标为 `assets/brand/RcHarness-v2.icns`；第一版图标归档在 `assets/brand/archive/v1/`。遥控器示意图位于 `assets/app/`。
- 本地构建默认 ad-hoc 签名；`RC_HARNESS_LOCAL_SIGNING_IDENTITY` 可指定本机证书，应用和随包驱动共用该身份。ad-hoc 模式的 designated requirement 是二进制 cdhash，改代码后重新签名会使已有的输入监控和辅助功能授权失效，需要在系统设置中重新授权当前安装包并重新打开应用；不要把 BLE 已连接或进程已启动当作权限已生效。
- 分发签名：设置 `RC_HARNESS_SIGNING_IDENTITY`，并传入第二个参数 `distribution`。该模式启用 hardened runtime 和安全时间戳，并附带 `scripts/RcHarness.entitlements`（录音输入），满足公证的签名要求；脚本本身不执行公证或发布。
- 首次从界面安装麦克风组件需要管理员授权。

### 自动发布 GitHub Release

仓库提供 [Release 工作流](.github/workflows/release.yml)：推送 `v主版本.次版本.修订号` 标签后，在 Apple Silicon macOS runner 上运行完整测试，以 Developer ID Application 证书签名应用和随包 HAL 驱动，提交 Apple 公证，确认 `Accepted` 后附加公证票据并验证 Gatekeeper，最后自动发布 Release。普通推送和 PR 仍只运行 CI。

首次配置，在仓库 **Settings → Secrets and variables → Actions → New repository secret** 添加以下六项 Secrets：

| Secret | 内容 |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | 包含私钥的 Developer ID Application `.p12` 证书的 Base64 内容 |
| `MACOS_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的非空密码 |
| `RC_HARNESS_SIGNING_IDENTITY` | `security find-identity -v -p codesigning` 列出的完整身份名称，例如 `Developer ID Application: Your Name (TEAMID)`；不包含两侧引号 |
| `APPLE_ID` | Apple 开发者账号邮箱 |
| `APPLE_TEAM_ID` | 该证书所属的开发者团队 ID |
| `APPLE_APP_PASSWORD` | 在 [Apple 账户](https://account.apple.com/)「登录和安全 → App 专用密码」生成的密码，用于公证；[生成步骤](https://support.apple.com/zh-cn/102654)，不是 Apple 账户登录密码 |

在「钥匙串访问」的「我的证书」中找到 Developer ID Application 证书，确认展开后包含私钥，再将该身份导出为带密码的 `.p12`。例如导出到桌面后，执行以下命令将 Base64 内容复制到剪贴板，粘贴至 `MACOS_CERTIFICATE_P12_BASE64`：

```bash
base64 -i ~/Desktop/DeveloperIDApplication.p12 | pbcopy
```

`.p12` 和密码只通过 GitHub Secrets 提供，不放进仓库。工作流生成临时钥匙串密码，结束后清理证书和钥匙串。它使用内置 `GITHUB_TOKEN` 的 `contents: write` 权限创建 Release，无需另外配置 GitHub PAT。证书导入方式见 [GitHub 官方说明](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)，公证过程见 [Apple 官方说明](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

先提交并推送工作流及要发布的项目代码，再在目标提交上创建并推送版本标签，例如：

```bash
git tag -a v0.1.1 -m "Release v0.1.1"
git push origin v0.1.1
```

发布已存在的标签时，在 **Actions → Release → Run workflow** 中选择 `main` 分支，并将 `tag` 填为 `v0.1.1`；也可以在 GitHub CLI 登录后执行：

```bash
gh workflow run release.yml --ref main -f tag=v0.1.1
```

手动发布使用 `main` 上的工作流，构建和测试均来自指定标签的提交，因此无需移动已有标签。

当前仅支持 `v0.1.1` 这样的正式版本标签，不支持 `-beta` 等后缀。应用版本号取标签去掉 `v` 的部分，构建号取工作流运行序号；HAL 驱动保留自身独立版本号。工作流仅上传已公证的 `RcHarness-v0.1.1-macos-arm64.zip` 和对应的 `SHA256SUMS`；源码可通过 GitHub 自动提供的 Source code 下载，许可证保留在仓库及应用包的 `Contents/Resources/LICENSE` 中。

缺少 Secrets、测试失败、签名身份不符或公证未通过时，工作流停止发布。Apple 公证等待上限为 45 分钟，超时后可在 Actions 页面重跑；提交的处理可能仍在 Apple 侧继续。上传中断留下的同标签草稿可通过重跑补齐并发布；已发布版本不会被覆盖，应使用新版本标签。

### 排查

- 同一遥控器只运行一款按键映射程序。Joy Harness 与 RcHarness 同时运行时，可能分别发送右 Command 和地球键，干扰微信输入法的语音快捷键；退出其他映射程序后，在 RcHarness 关闭再开启「按键映射」，重新应用原始按键抑制。原始 F5 和模拟语音键同时出现也会干扰快捷键匹配。
- 音频诊断：`~/Library/Logs/RcHarness/audio.log`，单文件约 512 KiB，另保留一份轮转日志；只记录计数和时延，不保存音频或听写内容。
- 其他日志：系统日志 subsystem `vip.tokenzz.rcharness`。逐按键和原始 HID 日志默认关闭，排查时设置 `RC_HARNESS_REMOTE_TRACE=1`。
- 窗口和菜单均无响应时，先保持进程运行，在仓库中执行 `scripts/capture_hang.sh`，采集完成后再强制退出。脚本将主应用的 3 秒线程采样、最近 5 分钟应用日志、音频元数据与版本签名信息保存到 `.build/diagnostics/hang-*`；不采集音频内容或其他应用日志。普通连接日志无法替代卡死现场的线程栈。
- 配置读取失败时，原始数据保存在同一偏好设置域的 `RcHarness.recovery.*` 键中。

## 许可证

Copyright (c) 2026 tokenzz-vip

本项目按 [GNU 通用公共许可证 v3.0（GPL-3.0-only）](LICENSE) 发布。
