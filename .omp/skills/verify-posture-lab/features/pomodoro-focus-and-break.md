# 番茄钟专注与休息

番茄钟会话是用户侧唯一主流程：主页展示 3D 人形点云与大倒计时，孩子点击「开始专注」进入专注阶段，阶段结束后按设置进入短休息或长休息；孩子可以暂停、继续或放弃，主页左上角显示今日目标进度，阶段自然结束与结束前一分钟会播放提示音。

## Sub-features

- `focus-main`：`pomodoro_main` 展示倒计时、阶段名与第几个番茄。
- `focus-start`：点击「开始专注」启动专注阶段；停驻状态不显示运行中的关节叠加。
- `focus-pause-resume`：专注中点击「暂停」停表，再次点击「继续」恢复。
- `focus-abandon`：专注中点击「放弃」，当前番茄记为 `abandoned`，不进入休息。
- `focus-phases`：专注结束进入短休息；累计达到 `focusPerLongBreak` 后进入长休息。
- `focus-daily-goal`：主页显示「今天 x/目标」，目标来自 `dailyGoal`。
- `focus-cues`：结束提示音 `soft`/`chime` 与结束前 1 分钟提醒写入 `cue_played`。

## How to get to it (user POV)

- 应用启动即进入主页 `pomodoro_main`（Q1 已确认；当前代码可能仍停在旧 `.home`，见 Gotchas）。
- 主页中央大按钮「开始专注」；运行中出现「暂停」与「放弃」；停表后「继续」。
- 阶段结束后按钮变为「开始」（休息）或「跳过休息」。
- 右上角 `chart.bar` 进入统计页，`gearshape` 进入设置页。

## Driving it with XCUITest & simctl/devicectl

Preconditions：

- `verify.py up --run <run-id>` 已成功，`doctor` 全绿。
- 场景使用 `-focusMinutes 1 -shortBreakMinutes 1`，把一轮压缩到 2 分钟。

- **启动番茄钟场景。** `
  .omp/skills/verify-posture-lab/scripts/verify.py drive --run <run-id>
  ` 的 `pomodoro-focus` 场景执行 `-pomodoro 1 -scenario pomodoroDay -focusMinutes 1 -shortBreakMinutes 1 -voice 1 -debug 1 -endSound chime`；35 秒、70 秒与 130 秒各一张截图。
- **读倒计时。** 打开 `tmp/verify/<run-id>/scenarios/pomodoro-focus/Documents/debug/session-*.jsonl`，确认 `pomodoro_tick` 每秒一行，`remaining_seconds` 随 `ts` 间隔下降，`phase` 在 `focus` / `shortBreak` / `longBreak` 之间流转。
- **读完成与休息。** 70 秒时第一个专注完成；130 秒时休息结束，`pomodoro-history.json` 至少 1 条 `completed` 记录；70 秒日志快照 `session-at-70.jsonl` 用于历史对账。
- **读提示音。** `cue_played` 的 `message` 为 `warn_before_end` / `end_soft` / `end_chime`；`endSound=none` 时没有任何 `cue_played`。
- **手动暂停与恢复。** 运行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PostureLab.xcodeproj -scheme PostureLab -destination "platform=iOS Simulator,id=C12DA589-2444-4F2E-A943-4D6BAFB02BF1" -only-testing:PostureLabUITests/ManualPauseUITests test`；测试会点击真实「暂停」并检查倒计时冻结与时间轴灰带。
- **今日目标。** 主页截图 `mid-focus.png` 应显示「今天 x/目标」；`pomodoro_tick` 与 `pomodoro-history.json` 的完成数应与之对账。
- **Stage 证据。** 每个场景目录保留 `launch-args.txt`、`provenance.json`、截图、`Documents/`；`verify.py evidence --run <run-id>` 会重跑 `verify-acceptance.py --ac1`。

## Gotchas

- Q1 已确认启动即主页 `pomodoro_main`；当前代码的 `SessionController.phase` 仍从 `.home` 开始，无参启动会进旧阅读流程，必须用 `-pomodoro 1` 才能到达番茄钟。这是待修偏差，不是验证失败的理由；按实际入口驱动并如实记录。
- 模拟器不能点击，`verify.py` 用启动参数与截图；真实暂停/恢复/放弃用 XCUITest。
- `pomodoroDay` 的 `-focusMinutes 1` 是启动参数覆盖，不会写回用户设置。
- 70 秒刚好跨过第一个 60 秒专注；太早截图只能看到专注中，太晚会进入休息。不要把休息截图当作专注证据。
- `cue_played` 只证明播放器启动了片段，不证明房间听见；不要声称“听到了”。
