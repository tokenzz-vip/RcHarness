# RcHarness：AI 应用遥控器

第二版围绕产品实际用途设计：把实体遥控器变成 GPT、Claude Desktop、Cursor 等 AI 应用的操作入口。

- 遥控器：实体按键操作，保留方向环与三个功能键。
- 对话气泡：AI 应用与对话交互。
- `>_` 提示符：向 AI 发出指令，同时联系编程助手场景。
- 两道信号弧线：遥控器与应用之间的无线控制关系。
- 深靛色底、淡紫对话框、薄荷绿方向环：形成独立品牌识别。

## 交付文件

- `rcharness-icon-v2.svg`：1024 × 1024 可编辑源稿。
- `rcharness-icon-v2.png`：1024 × 1024 透明边缘应用图标。
- `RcHarness-v2.icns`：16–1024 px 共十档 macOS 图标资源。
- `rcharness-mark-v2.svg`：单色矢量标志。
- `rcharness-mark-v2.png`：512 × 512 单色透明标志。
- `preview-v2.png`：主图标、单色标志、小尺寸应用效果。

通过手工 SVG 绘制，使用 macOS Quick Look 渲染，ImageMagick 处理透明通道与缩放，sips / iconutil 输出 macOS 图标。已检查导出图与 ICNS 各档尺寸。

第二版已接入 `scripts/build_app.sh`，打包为 `Contents/Resources/RcHarness.icns`，由 `Info.plist` 的 `CFBundleIconFile` 引用，用于 Finder 和 Dock。第一版作为历史方案保留在 `archive/v1/`。

设置页的应用介绍直接使用 AppKit 提供的当前应用图标，与 Finder、Dock 共用同一份品牌资源。

菜单栏使用 `Sources/RcHarness/MenuBarIcon.swift` 中绘制的 18 pt 单色简化版本，保留遥控器、对话提示符和一道信号弧线，由 macOS 模板图像机制自动适配浅色、深色和选中状态。连接、语音就绪和映射模式显示在悬停提示中。
