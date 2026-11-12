# 应用内更新

RcHarness 使用 SwiftPM 固定的 Sparkle 2.10.1，沿用标准原生更新窗口，支持检查、显示更新、下载、签名校验和重启安装。`AppUpdateModel` 只观察更新器状态及偏好；启动入口在截图模式返回之后，测试使用注入驱动，不联网、不替换真实应用。

更新配置、启动和检查失败的原因写入统一日志，不写入设置页版本信息区，也不追加主面板错误浮层；版本区始终保留上次检查时间。其他功能的操作通知保持不变。

更新候选按 `CFBundleShortVersionString`（appcast 的 `sparkle:shortVersionString`）的数字版本比较，仅线上展示版本高于本地时才允许进入 Sparkle 的更新流程；本地相同或更高时返回空候选，由 Sparkle 原生窗口统一提示已是最新版本。同一线上展示版本的多个候选再按内部构建号选择最新构建。此规则避免本地语义版本构建号与 CI 递增数字构建号混用时误报更新；不会将网络、解析或签名失败视为无更新，也不改变 Sparkle 的系统兼容性及安装校验。

## 更新源与签名

`Info.plist` 定义固定 HTTPS 更新源：

`https://github.com/tokenzz-vip/RcHarness/releases/latest/download/appcast.xml`

更新 ZIP 和 appcast 都使用 Ed25519 签名，应用在解包前验证更新包，并要求更新源签名。公钥提交在 `SUPublicEDKey` 中；私钥保存在本机登录钥匙串，Sparkle account 为 `vip.tokenzz.rcharness`。不要更换或删除此钥匙串项目；丢失私钥会影响后续更新。Apple Developer ID 签名、公证和 stapling 仍由原发布流程完成。

SwiftPM 二进制制品同时包含框架与签名工具，构建脚本将框架及帮助程序嵌入应用，并使用本次构建身份由内到外签名。无需单独安装 Sparkle。SwiftPM 的 `Package.resolved` 应一并提交。

## 首次配置发布

GitHub 仓库需要新增 `SPARKLE_PRIVATE_KEY` Actions secret。本次开发已在上述 account 中生成密钥，导出时不要将密钥打印到终端或写入仓库。可在准备好上传时运行：

```bash
swift package resolve
keyfile="$(mktemp -t rcharness-sparkle-key)"
chmod 600 "$keyfile"
trap 'rm -f "$keyfile"' EXIT
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account vip.tokenzz.rcharness -x "$keyfile"
gh secret set SPARKLE_PRIVATE_KEY --repo tokenzz-vip/RcHarness < "$keyfile"
```

使用安全方式备份此密钥。新机器上可用同一工具的 `-f` 选项导入。用 `generate_keys --account vip.tokenzz.rcharness -p` 查看公钥，并确认与应用内公钥一致。

## 每次发布

发布 workflow 在创建正式 Release 前要求所有签名 secret 就绪。构建和公证完成、staple 后压缩最终 ZIP，再运行 `scripts/generate_update_feed.sh`，从最终包读取构建号、展示版本和最低系统版本，生成签名更新源。脚本校验下载地址、ZIP 长度、版本及签名；任一步失败不会发布 Release。ZIP、SHA256SUMS 和 appcast 作为同一 Release 的附件一起发布。

`CFBundleVersion` 使用现有 workflow 的 `github.run_number`，必须保持递增，避免重建 workflow 后重置。展示版本遵循 `vMAJOR.MINOR.PATCH` 标签。每次正式发布都必须附带 appcast，否则 latest 更新入口会失效。当前仅发布正式版和 arm64 全量更新，不生成增量包。

本地可对专用发布目录运行：

```bash
bash scripts/generate_update_feed.sh /path/to/release-assets v0.4.0
```

本地默认从上述钥匙串 account 读私钥；CI 从 `SPARKLE_PRIVATE_KEY` 通过标准输入传递，私钥不出现在命令参数中。

## 虚拟麦克风同步更新

HAL 组件仍随应用放在 `Contents/PlugIns/RcHarnessMicrophone.driver`。新应用启动时，若系统已安装组件且其 `CFBundleVersion` 小于随包版本，则自动进入现有管理员授权安装流程。相同版本不重复安装，系统组件版本较新时不降级，未安装时不自动安装。修改驱动代码或共享协议时，必须提高 `Drivers/RcHarnessMicrophone/Info.plist` 的 `CFBundleVersion`，展示版本按需要同步提高。

安装前释放语音会话与输出，暂时禁用重复组件操作；授权后将随包驱动复制到系统临时目录，核对精确代码签名后替换旧组件，并重启 coreaudiod。应用更新和系统组件更新是两次独立操作；取消授权或安装失败时，新应用保留组件待更新提示及连接页重试入口，下次启动再次检查。

## 验证边界

单元测试覆盖检查门禁、偏好同步、失败重试，以及驱动版本比较。发布脚本校验真实最终 ZIP 和签名更新源；设置页通过 `--render-settings` 检查布局。正式启用前，应使用两个递增构建完成一次真实升级验收：旧版检查到新版、下载、重启后版本变更、配置保留，以及驱动版本递增时的授权和重试。未发布的新版本无法通过线上 latest 地址完成这一验收。
