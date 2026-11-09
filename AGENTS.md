# AGENTS.md

本仓库是 **Swift / SwiftPM 原生 macOS 应用**（菜单栏 + SwiftUI + IOHID + CoreBluetooth + CoreAudio HAL 驱动），不是 Wails 项目。上层目录中关于 Wails v3 的约定不适用于这里。

## 环境

- Apple Silicon、macOS 15+、Xcode 16+（Swift 6 工具链，语言模式 v5）。
- 无第三方依赖。新增依赖前先说明理由并征得同意。

## 常用命令

```bash
scripts/test_all.sh            # swift test + HAL 驱动 ASan/UBSan 测试 + 音频探针（无权限时跳过）
swift test                     # 仅单元测试
scripts/build_app.sh .build/RcHarness.app
.build/RcHarness.app/Contents/MacOS/RcHarness --render-settings /tmp/pages   # 导出所有页面截图
```

改动 UI 后，用 `--render-settings`（可加 `--dark --narrow`）导出截图检查布局。

## 本机编译与安装

- 用户要求编译或安装时，使用 `RC_HARNESS_LOCAL_SIGNING_IDENTITY` 指定的固定 Apple 证书；本机配置保存在 `~/.zshrc`。非交互命令未继承该变量时，通过 `zsh -ic` 加载后再构建。
- 构建前确认变量非空、值不是 `-`，并与 `security find-identity -v -p codesigning` 中的有效身份匹配；不可用时停止并说明原因，不回退到 ad-hoc 签名。
- 构建后验证应用及随包 HAL 驱动均使用该身份签名，并通过 `codesign --verify --deep --strict` 校验。

## 约定

- 主线程类型标注 `@MainActor`；HID、CoreBluetooth、音频输出状态机都只在主队列运行。`AudioDeviceCatalog` 和 `CoreAudioRemoteMicrophonePlayback` 是仅有的跨线程类型。
- 偏好设置键只在 `SettingsKeys.swift` 定义；JSON 值通过 `SettingsStorage` 读写。
- 设备身份（VID/PID、BLE 型号与名称）只在 `RemoteProfile` 定义，不在其他文件写死。
- 合成事件统一走 `SystemEventSender` 的注入点，测试不得向真实会话发送事件。
- 定时逻辑通过 `RemoteVoiceSessionController.Scheduler` 注入，测试使用 `TestClock`，不要用真实等待。
- 日志用 `Log`（os.Logger），语音元数据用 `AudioDiagnostics`；不要用 `print`。
- 驱动与应用共享的常量（如 flush 属性 `'jhfl'`）修改时两边同步，`RefactorTests` 会校验。
- 签名和发布配置（`scripts/sign_macos_code.sh`、`scripts/RcHarness.entitlements`）不要在普通功能任务中改动。

## 文档

- `README.md`：概览、构建、签名和排查。
- `docs/behavior.md`：界面与运行时的具体行为；用户可见行为变化时同步更新。
