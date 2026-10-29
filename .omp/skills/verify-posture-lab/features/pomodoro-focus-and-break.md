# 番茄钟专注与休息

番茄钟会话是用户侧唯一主流程：主页冷启动即启动输入源（设置页/主页可见时相机运行，开始专注前就有摄像头预览与 3D 人形点云；统计页仍会停相机），大倒计时居中，孩子点击「开始专注」进入专注阶段，阶段结束后按设置进入短休息或长休息；孩子可以暂停、继续或点「离开」提前结束本轮（记为 `abandoned`），主页左上角显示今日目标进度，阶段自然结束时播放提示音。

## Sub-features

- `focus-main`：`pomodoro_main` 展示倒计时、阶段名与第几个番茄。
- `focus-start`：点击「开始专注」启动专注阶段；停驻时即已显示摄像头预览与 3D 点云（截图 `AC-parked-before-start`）。
- `focus-pause-resume`：专注中点击「暂停」停表，再次点击「继续」恢复。
- `focus-leave`：已开始（运行或暂停中）时显示「离开」按钮；点「离开」提前结束本轮、倒计时重置、历史记为 `abandoned`（`focusedSeconds = elapsed − pausedSeconds`），不进入休息阶段；停驻或点「离开」重置后不再显示。文案唯一来源 `PomodoroCopy.endFocusEarly`，UI 不出现「放弃」；「离开」只指这个按钮，人不在镜头前叫「无人」（`paused`/`resumed`，见 `docs/qa-log-schema.md`）。
- `focus-phases`：专注结束进入短休息；累计达到 `focusPerLongBreak` 后进入长休息。
- `focus-daily-goal`：主页显示「今天 x/目标」，目标来自 `dailyGoal`。
- `focus-cues`：结束提示音 `soft`/`chime` 写入 `cue_played`；设置页的试听不写。

## How to get to it (user POV)

- 应用无参启动即进入主页 `pomodoro_main`（Q1 已确认，已由 ADR-0006 落地）。
- 主页中央大按钮「开始专注」（整块胶囊热区可点，最小 44pt 高；次级按钮同样整块可点）；运行中出现「暂停」与「离开」，暂停后出现「开始专注」（继续）与「离开」；停表后「继续」。
- 阶段结束后按钮变为「开始」（休息）或「跳过休息」。
- 右上角 `chart.bar` 进入统计页，`gearshape` 进入设置页。

## Driving it with XCUITest & simctl/devicectl

Preconditions：

- `verify.py up --run <run-id>` 已成功，`doctor` 全绿。
- 场景使用 `-focusMinutes 1 -shortBreakMinutes 1`，把一轮压缩到 2 分钟。

- **启动番茄钟场景。** `
  .omp/skills/verify-posture-lab/scripts/verify.py drive --run <run-id>
  ` 的 `pomodoro-focus` 场景执行 `-scenario pomodoroDay -focusMinutes 1 -shortBreakMinutes 1 -voice 1 -debug 1 -endSound chime`；35 秒、70 秒与 130 秒各一张截图。
- **读倒计时。** 打开 `tmp/verify/<run-id>/scenarios/pomodoro-focus/Documents/debug/session-*.jsonl`，确认 `pomodoro_tick` 每秒一行，`remaining_seconds` 随 `ts` 间隔下降，`phase` 在 `focus` / `shortBreak` / `longBreak` 之间流转。
- **读完成与休息。** 70 秒时第一个专注完成；130 秒时休息结束，`pomodoro-history.json` 至少 1 条 `completed` 记录；70 秒日志快照 `session-at-70.jsonl` 用于历史对账。
- **读提示音。** `cue_played` 的 `message` 为 `end_soft` / `end_chime`；`endSound=none` 时没有任何 `cue_played`。
- **手动暂停与恢复。** 运行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PostureLab.xcodeproj -scheme PostureLab -destination "platform=iOS Simulator,id=C12DA589-2444-4F2E-A943-4D6BAFB02BF1" -only-testing:PostureLabUITests/ManualPauseUITests test`；测试会点击真实「暂停」并检查倒计时冻结与时间轴灰带。
- **今日目标。** 主页截图 `mid-focus.png` 应显示「今天 x/目标」；`pomodoro_tick` 与 `pomodoro-history.json` 的完成数应与之对账。
- **「离开」按钮与提前结束。** 运行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PostureLab.xcodeproj -scheme PostureLab -destination "platform=iOS Simulator,id=C12DA589-2444-4F2E-A943-4D6BAFB02BF1" -only-testing:PostureLabUITests/PomodoroControlsUITests test`：停驻时不显示「离开」、开始后显示「离开」，点「离开」后倒计时重置为整轮且没有「跳过休息」（截图 `AC-ended-early-reset`）；点「开始专注」胶囊的边缘也能开始（截图 `AC-start-whole-capsule`）。文案唯一来源是 `PomodoroCopy.endFocusEarly`，归档状态仍是 `abandoned`。
- **停驻前证据。** DEBUG 构建可用 `-scenario headDown -holdStart 1 -focusMinutes 5 -debug 0` 让脚本场景保持第一个专注停驻（`-holdStart 1` 为 DEBUG 专用启动参数）：开始专注前就有摄像头预览（真机）与 3D 点云（模拟器 BodyRig 场景），且没有「离开」按钮；截图 `AC-parked-before-start`。
- **Stage 证据。** 每个场景目录保留 `launch-args.txt`、`provenance.json`、截图、`Documents/`；`verify.py evidence --run <run-id>` 会重跑 `verify-acceptance.py --ac1`。

## Gotchas

- 旧阅读流程已退役（ADR-0006）：只有 `pomodoro_main`、`pomodoro_settings` 与三个统计页是可达界面；日志里出现 `home`/`calibration`/`monitoring`/`summary` 说明跑的是旧构建。
- `-pomodoro` 启动参数已删除；如果脚本仍传入它，应用会忽略它并照常进入主页，但该参数不应再出现在任何命令里。
- 模拟器不能点击，`verify.py` 用启动参数与截图；真实暂停/恢复/点「离开」用 XCUITest（`PomodoroControlsUITests`）。
- `pomodoroDay` 的 `-focusMinutes 1` 是启动参数覆盖，不会写回用户设置。
- 70 秒刚好跨过第一个 60 秒专注；太早截图只能看到专注中，太晚会进入休息。不要把休息截图当作专注证据。
- `cue_played` 只证明播放器启动了片段，不证明房间听见；不要声称“听到了”。
