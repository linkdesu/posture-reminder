# PostureLab 验证特性地图

本目录是 PostureLab 用户侧行为的维护型验证来源。驱动应用前先读本索引，再打开对应特性文件；每次验证的证据统一写入 `tmp/verify/<run-id>/`，并更新 `tmp/verify/latest` 软链接。

## 基线前置条件

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`；本机默认的 `xcode-select` 可能指向 CommandLineTools。
- 模拟器 UDID：`C12DA589-2444-4F2E-A943-4D6BAFB02BF1`（iPhone 17）。真机：`00008110-001271181AD3801E`（iPhone 13，需解锁）。
- Bundle id：`me.xieal.posturelab`。
- 每次运行从一个干净沙盒开始：`verify.py up` 会卸载/安装应用；`drive` 的每个场景都会重装。
- 证据目录：`tmp/verify/<run-id>/`；运行器自动维护 `tmp/verify/latest`。不要在 `artifacts/` 下写新证据。
- 应用启动后先跑 `verify.py doctor --run <run-id>`，全绿再驱动。

## 驱动约定

- 所有命令都在仓库根目录执行，路径写绝对或仓库相对路径。
- 用 `verify.py up|doctor|drive|evidence|down --run <run-id>` 完成生命周期；不要手工拼接另一套状态目录。
- 应用无参启动即进入 `pomodoro_main`；`-pomodoro` 参数已删除，不要传入。
- 模拟器没有可脚本化点击，能用启动参数表达的状态用启动参数；必须真实点击的设置页修改、手动输入数字、提示音试听与手动暂停用 XCUITest。
- 优先使用稳定标识：`pomodoro_main`、`pomodoro_settings`、`report_day`、`report_week`、`report_month`、accessibility label、日志事件名。
- 每个场景重装应用，避免设置、历史与日志在场景之间泄漏。
- 清理只终止本次启动的 App；只有 `state.json.bootedByUs` 为真时才关闭模拟器。

## 取证与失败报告准则

- 同时保留动作和结果：截图、`session-*.jsonl`、`pomodoro-history.json`、`sandbox-audit.json`、校验器输出。
- 逐行检查 JSONL 的 38-key 契约；用 `scripts/verify-session.py`、`scripts/verify-pomodoro.py`、`scripts/verify-acceptance.py` 复算，不信任应用自报。
- 隐私同时做源码审计（`scripts/audit-offline.py`）与运行时容器审计（`scripts/audit-sandbox.py`）。
- 当前实现与 `GLOSSARY.md` / ADR-0001..0005 的已确认规则存在已知偏差时，按用户可见行为如实报失败，并在对应特性的 `Gotchas` 中写明；不得弱化断言或改走另一条路径来掩盖。
- 未到达的入口报告为失败，并附上尝试的命令与未满足的前置条件；不要把“跳过”写成“通过”。

## 特性列表

- [番茄钟专注与休息](./pomodoro-focus-and-break.md)：冷启动即有摄像头预览与点云、主页倒计时、阶段流转、开始/暂停/恢复/「休息」（`abandoned`）、`-holdStart` 停驻证据、整块胶囊热区、今日目标、阶段提示音。
- [体态监测与语音提醒](./posture-monitoring-and-voice.md)：3D 人形点云（冷启动即显示）、静默基线、8 种体态、15 秒预录语音、无人暂停、调试叠加层（随时显示、中文关节名、算法来源行）。
- [番茄钟设置](./pomodoro-settings.md)：11 项参数（含手动输入、点按全选与夹取）、「监测」与「调试」分区（灵敏度/形象模式/调试模式/实验性体态）、提示音试听、真实控件交互与重启持久化。
- [统计页与历史](./posture-report-and-history.md)：日/周/月视图、姿态时间轴、`focusedSeconds`/`pausedSeconds` 对账、历史持久化与清空。
- [离线与沙盒隐私](./offline-and-sandbox-privacy.md)：零网络、无 RGB 落盘、38-key JSONL 契约。
