# RcHarness

## ❤️ 赞助商


| 赞助商 | 介绍 |
|---|---|
| <a href="https://tokenzz.vip/"><img src="assets/sponsors/tokenzz.png" alt="TokenZZ 标志" width="96" height="96"><br></a> | 我们只是 token 的搬运工，官方纯净 token 转发。 |

---

## 简介

用蓝牙遥控器操作 Mac 上的 Codex、Claude、Cursor 等 AI 对话与编程应用。

RcHarness 是原生 macOS 菜单栏应用，支持按键映射、应用切换和按住说话，无需额外转接硬件。

[下载应用](https://github.com/tokenzz-vip/RcHarness/releases) · [反馈问题](https://github.com/tokenzz-vip/RcHarness/issues)

## 功能

- **自定义按键**：为单击、双击和长按设置快捷键、鼠标操作、系统动作或常用语。
- **应用与方案**：为不同应用绑定键位方案，通过遥控器切换运行中的应用。
- **语音输入**：将遥控器麦克风作为虚拟输入设备，配合语音应用按住说话；Chromecast 遥控器另可选择点按模式（固件兼容性需实机确认）。语音快捷键通过按键面板选择：长按支持 Fn 和左右 Command／Option／Control 七个单键，点按另支持其中任意两个不同键的组合；小米点按保持禁用。
- **组合动作**：将多个操作和等待时间串成一个动作。
- **本地管理**：配置导入导出、连接诊断与使用统计；统计不记录音频或听写内容。

## 系统与设备

需要 **Apple Silicon Mac、macOS 14 或更高版本**，界面为简体中文。

| 遥控器 | 型号 | 支持能力 |
|---|---|---|
| 小米蓝牙遥控器 2 | RC001-MS | 按键映射、按住说话 |
| 小米蓝牙遥控器 2 Pro | RC003-MS | 按键映射、按住说话 |
| Google Chromecast 遥控器 | G9N9N | 按键映射、按住说话 |

> **兼容性提示**：Google 遥控器仅验证了拼多多店铺「金利达数码科技大全」销售的 G9N9N。其他店铺、批次或同型号产品尚未验证，兼容性不作保证。

## 安装与开始使用

1. 从 [发布页面](https://github.com/tokenzz-vip/RcHarness/releases) 下载应用压缩包，解压后将 `RcHarness.app` 移入“应用程序”。
2. 在 macOS 蓝牙设置中配对遥控器，在 RcHarness 的“连接与语音”页选择对应型号。
3. 在“设置”页按提示授予蓝牙、输入监控和辅助功能权限。
4. 在“Harness”页添加或选择应用并绑定键位方案，在“按键”页点击卡片配置动作。
5. 需要语音输入时，在“连接与语音”页安装虚拟麦克风组件，在语音应用中选择相同的接收设备，并分别授予 RcHarness 和语音应用麦克风权限。

虚拟麦克风组件随应用提供，首次安装需要管理员授权。RcHarness 负责传递音频，语音识别由目标语音应用处理。

默认全局按键为电源键：**单击**打开运行中的 Harness 列表，**双击**系统区域截图，**长按**切换到原生模式。进入原生模式后，从主面板或菜单栏恢复映射。全局按键和各型号配置均可单独调整。

## 常见问题

- **按键无反应或重复触发**：检查“输入监控”“辅助功能”权限和“启用遥控器映射”开关；退出其他遥控器映射软件，再关闭并重新开启映射。
- **语音没有声音**：检查“连接与语音”页的语音连接、接收设备和测试音，确认语音应用选择了同一输入设备，并已获得麦克风权限。
- **需要反馈问题**：附上应用版本、macOS 版本、遥控器型号和复现步骤；通过“设置 → 诊断与支持 → 复制诊断信息”获取状态。音频诊断日志位于 `~/Library/Logs/RcHarness/audio.log`，只记录计数和时延。
- **窗口和菜单无响应**：强制退出前，在源码仓库运行 `scripts/capture_hang.sh` 采集线程与日志，结果位于 `.build/diagnostics/`。

## 开发

项目使用 Swift、SwiftUI 和 Swift Package Manager，无第三方依赖。当前 CI 与发布使用 **Xcode 27.1 / Swift 6.4**，最低运行系统为 macOS 14。

本机构建前，将 `RC_HARNESS_LOCAL_SIGNING_IDENTITY` 设置为 `security find-identity -v -p codesigning` 列出的有效 Apple 签名身份，值不能是 `-`。若配置在 `~/.zshrc` 中，非交互构建时通过 `zsh -ic` 加载。

```bash
scripts/test_all.sh
scripts/build_app.sh .build/RcHarness.app
open .build/RcHarness.app
```

`test_all.sh` 包含单元测试、HAL 驱动 ASan/UBSan 测试和音频探针；缺少权限或回环设备时跳过音频探针。仅运行单元测试可用 `swift test`。构建后，应用及随包 HAL 驱动应使用同一签名身份，并通过 `codesign --verify --deep --strict` 校验。

音频主线程时延测量：`scripts/test_audio_output.sh --latency` 输出健康查询、调度、flush、停止及设备枚举的耗时分布；`scripts/capture_audio_latency.sh 30` 采集 Instruments 时间区间和等待线程。基线结果与尚待验证的异常场景见[专项测量记录](docs/audio-main-thread-latency.md)。

界面改动后导出截图检查布局；此模式使用临时配置，不连接遥控器：

```bash
.build/RcHarness.app/Contents/MacOS/RcHarness --render-settings /tmp/rcharness-pages
.build/RcHarness.app/Contents/MacOS/RcHarness --render-settings /tmp/rcharness-pages-dark --dark --narrow
```

详细说明：[界面与运行时行为](docs/behavior.md) · [小米 RC001-MS 适配](docs/xiaomi-rc001.md) · [Google G9N9N 适配](docs/google-g9n9n.md)

## 致谢

感谢 [JoyHarness](https://github.com/nixihz/JoyHarness) 与 [无线麦 SayAll](https://github.com/HD838A/remote-mic-app) 提供的遥控器按键、蓝牙语音及虚拟麦克风实现参考。

## 许可证

Copyright (c) 2026 tokenzz-vip。以 [GNU 通用公共许可证 v3.0（GPL-3.0-only）](LICENSE) 发布。
