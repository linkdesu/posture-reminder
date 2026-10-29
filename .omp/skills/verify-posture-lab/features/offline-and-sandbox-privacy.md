# 离线与沙盒隐私

应用从构造上离线：没有网络权限、没有 HTTP 客户端、没有分析端点；番茄钟历史、日志与设置只留在本机沙盒。页面截图只在内存里渲染，容器内没有任何图像文件。主页的 3D 人形点云不展示也不落盘原始 RGB 画面；JSONL 日志每行必须携带完整的 42 个键（v0.6 起比 v0.5 多 `segment_kind`、`segment_start`、`segment_end`、`segment_seconds`）。

## Sub-features

- `privacy-offline-source`：源码中没有 `URLSession`、`Network`、`WKWebView`、socket 等联网 API，也没有 URL 字面量。
- `privacy-offline-runtime`：运行中的 App 不持有 internet socket。
- `privacy-sandbox-files`：沙盒只允许 JSONL/JSON/TXT 与系统自有缓存；**任何图像后缀（png/jpg/heic/mp4/dng/raw 等）都是失败**，包括应用自绘的调试图。
- `privacy-rgb`：不展示、不落盘原始 RGB；点云是渲染几何，不是相机照片。页面截图只在内存（`FileDebugLogger.latestScreenshot`）。
- `privacy-log-contract`：每行 JSONL 恰好 42 个键，`ts` 为 epoch 毫秒，缺失值为 `null`；事件词表含 `segment`（识别中段：从点击「开始」到该专注首个姿态样本，段关闭时写一行），该行只有 `segment_kind`、`segment_start`、`segment_end`、`segment_seconds` 这四个键非 `null`，其余行为 `null`。

## How to get to it (user POV)

- 无用户界面入口；这些是运行时属性。
- 用户能观察到的是：飞行模式下所有功能仍可用；统计页与设置页重启后仍在；没有任何登录/账号页面。

## Driving it with XCUITest & simctl/devicectl

Preconditions：

- `verify.py up` 与 `doctor` 已通过，至少完成一个 `drive` 场景。
- 运行时容器路径在 `state.json.appContainerDataPath`。

- **源码离线审计。** 运行 `python3 scripts/audit-offline.py`；退出码 0 且输出结尾为 `AC8 PASS`。`verify.py evidence` 会把结果写到 `audits/offline.txt`。
- **运行时 socket 审计。** 在应用运行时执行 `lsof -nP -p <pid> -i`；不得有 internet socket。真机上用 `nettop` 或 `lsof` 对同一 pid 检查。
- **沙盒审计。** 运行 `python3 scripts/audit-sandbox.py <appContainerDataPath> --json <run>/scenarios/<scenario>/sandbox-audit.json`；退出码 0，manifest 中不得出现禁止后缀或 raw/frame/depth/rgb 等命中。`verify.py drive` 已在每个场景自动执行。
- **42-key 契约。** `verify.py evidence` 对每个 `session-*.jsonl` 逐行检查键集合恰好为 42 个（v0.6 起含事件 `segment` 的四个键），并运行 `scripts/verify-session.py`（其中 P2 检查 `Documents/` 下没有任何图像文件）。也可手工：
  ```sh
  python3 scripts/verify-session.py <log> --quiet
  ```
- **无图像证据。** 检查沙盒 manifest：只有 `Documents/debug/session-*.jsonl`、`Documents/pomodoro-history.json` 与偏好文件；没有 PNG/JPG/HEIC/MOV/MP4，也没有相机帧、深度帧或原始传感器数据。留档截图是设备侧 `simctl io screenshot` 拍的，位于证据目录，不属于应用容器。
- **证据。** 保留 `audits/offline.txt`、每个场景的 `sandbox-audit.json`、`verification/contract.txt`；失败时保留原始 JSONL。

## Gotchas

- 模拟器的 `Library/` 由 iOS 写入 Saved State、Metal cache、SplashBoard 快照；`audit-sandbox.py` 把它们标为 system-owned，但仍会检查禁止后缀与名称提示。
- `battery_level` 在模拟器常为 `null`；这是设备不报告，不是 schema 缺键。
- 容器内出现任何 PNG（包括应用自绘的调试图）现在都判失败；v0.5 起截图只在内存。设备侧 `simctl io screenshot` 的留档图不属于容器，不受此限。
- Q4 已确认点云由 TrueDepth 深度图 + 人像分割遮罩合成；当前代码由关节点几何生成，真机源也没有深度。隐私审计能证明“没有 RGB 落盘”，不能证明“已实现 TrueDepth 合成”。
- `audit-offline.py` 会先剥离注释；文档链接不算联网 API。
- 不要把 `artifacts/` 下的旧证据当作本轮证据；一切新证据只写 `tmp/verify/<run-id>/`。
