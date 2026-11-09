# 遥控器图片

## Google Chromecast Voice Remote（G9N9N）

- 文件：`controller-dashboard-google-g9n9n.png`（392 × 1333，透明 PNG）。
- 来源：[Google Store 官方产品页](https://store.google.com/jp/product/chromecast_google_tv_voice_remote?hl=ja)，Snow 白色款产品图。
- [原图](https://lh3.googleusercontent.com/HIzPTW6KFfDfjiR_m9VKx1NFsDJS5EIPSkpK2yV1UmNgU0HSAZ1Au7MmWHEU3qwKnw=s2000)下载于 2026-11-06；从 2000 × 2000 透明图裁剪 alpha 非零边界 `(795, 261, 1187, 1594)`，未重绘或改变比例。裁剪图自第 1270 行起，将 alpha 乘以 `min(1, max(R, G, B) / 40)`，去除原图以黑色半透明像素表示的底部地面投影，保留机身明暗及抗锯齿边缘；画布尺寸和按键位置不变。
- 图片及商标权利归 Google 所有；本仓库未将其重新授权为开源素材。
- 高亮和点击区域按该裁剪版本校准；更换图片时需同步 `RemoteArtworkView` 中的几何数据与宽高比。

## 小米蓝牙遥控器 2（RC001-MS）

- 文件：`controller-dashboard-xiaomi-rc001.png`（249 × 984，透明 PNG）。
- 来源：[小米有品官方普通版产品页](https://www.xiaomiyoupin.com/detail?gid=183741)，下载于 2026-11-06。
- 原图为连续的详情切片 [上半部](https://img.youpin.mi-img.com/shopmain/3722bf52_e596_4e6d_800d_cf720dfda972.jpeg) 与 [下半部](https://img.youpin.mi-img.com/shopmain/b4ebb7d5_f1e2_4b6e_bb29_5720279cba7d.jpeg)，各 1080 × 800。上下拼接后裁剪 `(420, 44, 669, 1028)`；圆角 alpha 蒙版去掉背景，两侧被手指遮挡的窄金属边缘使用同图未遮挡边缘修补，按键、符号和正面机身保留。
- 普通版顶部为黑色按键、橙色电源符号，独立校准按键位置、宽高比和顶部按键高亮半径；2 Pro 继续使用 `controller-dashboard-xiaomi-remote.png` 的银色顶部按键配图。
- 图片及商标权利归小米所有；本仓库未将其重新授权为开源素材。
