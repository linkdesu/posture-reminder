# 番茄钟专注与休息

番茄钟会话是用户侧唯一主流程：主页冷启动即启动输入源（设置页/主页可见时深度输入运行，开始专注前就有 3D 人形点云；任何构建都不显示摄像头画面；统计页会停输入），大倒计时居中，孩子点击「开始专注」进入专注阶段，阶段结束后按设置进入短休息或长休息；孩子可以暂停、继续或点「离开」提前结束本轮（记为 `abandoned`），主页左上角显示今日目标进度，阶段自然结束时播放提示音。

## Sub-features

- `focus-main`：`pomodoro_main` 展示倒计时、阶段名与第几个番茄。
- `focus-start`：点击「开始专注」启动专注阶段；停驻时即已显示 3D 点云或无人体时的矢量轮廓（截图 `AC-parked-before-start`）。
- `focus-pause-resume`：专注中点击「暂停」停表，再次点击「继续」恢复。
- `focus-leave`：已开始（运行或暂停中）时显示「离开」按钮；点「离开」提前结束本轮、倒计时重置、历史记为 `abandoned`（`focusedSeconds = elapsed − pausedSeconds`），不进入休息阶段；停驻或点「离开」重置后不再显示。文案唯一来源 `PomodoroCopy.endFocusEarly`，UI 不出现「放弃」；「离开」只指这个按钮，人不在镜头前叫「无人」（`paused`/`resumed`，见 `docs/qa-log-schema.md`）。
- `focus-phases`：专注结束进入短休息；累计达到 `focusPerLongBreak` 后进入长休息。
- `focus-daily-goal`：主页显示「今天 x/目标」，目标来自 `dailyGoal`。**0.6.7 起专注倒计时归零那一刻就加一**（休息中已是新值），不等休息结束；「离开」/被打断的专注不加；下一阶段开始（记录落盘）时不重复加。
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
- **读提示音（专注结束与休息结束各一条）。** `cue_played` 的 `message` 为 `end_soft` / `end_chime`；`endSound=none` 时没有任何 `cue_played`。0.6.8 (21) 起**休息自然结束也响**（`GLOSSARY.md`「阶段提示音」）：`-scenario pomodoroDay -focusMinutes 1 -shortBreakMinutes 1 -endSound chime` 跑到 130 秒，`cue_played` 至少两条（第一个专注归零、第一段休息归零）；孩子点「离开」或「跳过休息」不产生 `cue_played`。判断规则的单元测试是 `PostureLabTests/PhaseEndCueTests`。
- **从桌面图标回到主页。** `-only-testing:PostureLabUITests/LaunchDestinationUITests`：设置页/统计页开着时按 Home、再切回 App，必须落在 `pomodoro_main`（`AC4-main-after-reopen` 截图）。启动参数 `-settings 1` / `-report day` 的首屏不受影响。
- **手动暂停与恢复。** 运行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PostureLab.xcodeproj -scheme PostureLab -destination "platform=iOS Simulator,name=pl-verify" -only-testing:PostureLabUITests/ManualPauseUITests test`；测试会点击真实「暂停」并检查倒计时冻结与时间轴灰带。
- **今日目标（归零即加一）。** `verify.py drive --run <run-id> break-count`：20 s 专注中「今天 0/N」、75 s 休息中「今天 **1**/N」、135 s 下一段专注仍「今天 1/N」，判据见 `scenarios/break-count/break-count.json`。
- **今日目标（离开不计）。** `verify.py drive --run <run-id> abandon-count`：XCUITest 真点「开始专注」再真点「离开」提前结束，主页「今天 x/N」前后相等，历史里是 `abandoned` 而不是 `completed`，判据见 `scenarios/abandon-count/abandon-count.json`。不手写 plist、不靠启动参数伪造结果。
- **今日目标（对账）。** 主页截图 `mid-focus.png` 应显示「今天 x/目标」；`pomodoro_tick` 与 `pomodoro-history.json` 的完成数应与之对账。
- **「离开」按钮与提前结束。** 运行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PostureLab.xcodeproj -scheme PostureLab -destination "platform=iOS Simulator,name=pl-verify" -only-testing:PostureLabUITests/PomodoroControlsUITests test`：停驻时不显示「离开」、开始后显示「离开」，点「离开」后倒计时重置为整轮且没有「跳过休息」（截图 `AC-ended-early-reset`）；点「开始专注」胶囊的边缘也能开始（截图 `AC-start-whole-capsule`）。文案唯一来源是 `PomodoroCopy.endFocusEarly`，归档状态仍是 `abandoned`。
- **停驻前证据。** DEBUG 构建可用 `-scenario headDown -holdStart 1 -focusMinutes 5 -debug 0` 让脚本场景保持第一个专注停驻（`-holdStart 1` 为 DEBUG 专用启动参数）：开始专注前就有 3D 点云（模拟器 BodyRig 场景；无人体时为矢量轮廓），且没有「离开」按钮；截图 `AC-parked-before-start`。
- **Stage 证据。** 每个场景目录保留 `launch-args.txt`、`provenance.json`、截图、`Documents/`；`verify.py evidence --run <run-id>` 会重跑 `verify-acceptance.py --ac1`。

## Gotchas

- 旧阅读流程已退役（ADR-0006）：只有 `pomodoro_main`、`pomodoro_settings` 与三个统计页是可达界面；日志里出现 `home`/`calibration`/`monitoring`/`summary` 说明跑的是旧构建。
- `-pomodoro` 启动参数已删除；如果脚本仍传入它，应用会忽略它并照常进入主页，但该参数不应再出现在任何命令里。
- 模拟器不能点击，`verify.py` 用启动参数与截图；真实暂停/恢复/点「离开」用 XCUITest（`PomodoroControlsUITests`）。
- `pomodoroDay` 的 `-focusMinutes 1` 是启动参数覆盖，不会写回用户设置。
- 70 秒刚好跨过第一个 60 秒专注；太早截图只能看到专注中，太晚会进入休息。不要把休息截图当作专注证据。
- `cue_played` 只证明播放器启动了片段，不证明房间听见；不要声称“听到了”。

## 屏幕常亮取证（v0.6.5 起，v0.6.6 补 resume / foreground）

- 常亮不再用 lldb 读（r15 读不出值）。DEBUG 构建在 `Documents/debug/idle-*.jsonl` 里每个时刻写一行：`{"t":<墙钟毫秒>,"trigger":"focus_start|pause|resume|focus_end|background|foreground","idle_timer_disabled":<bool>}`。
- 六个时刻：
  - `focus_start`：点「开始」；
  - `pause`：手动暂停或无人自动暂停，各写一次；
  - `resume`（v0.6.6）：暂停后点「继续」，或无人自动暂停后人回到画面、计时自动恢复；
  - `focus_end`：专注结束（完成或放弃；暂停中直接结束只记这一行，不记 `resume`）；
  - `background`：scene 不再 active（切到后台；启动瞬间 scene 先报一次非 active，也会写 `false`）；
  - `foreground`（v0.6.6）：scene 重新变为 active，任何状态下都写。
- 值是**状态真正生效、写完常亮之后**应用上**实际的** `isIdleTimerDisabled`，不是策略的期望值；`foreground` 在 scene 变为 active 之后才写。
- **每次启动是一个独立文件** `idle-<启动时刻>.jsonl`。同一容器里启动几次就有几个文件，合并读时会看到多行启动时的 `background false`（r16 dry-run 的「两行」就是 preflight 先无参启动、再跑短用例的两次启动，各一行，不是重复写入）。按文件分开判。
- 启动判据：**启动时至少有一行 `false`**（`background false`，之后通常紧跟 `foreground false`）；不要求恰好一行。
- 判据：`focus_start`、`resume` 为 `true`；专注计时中的 `foreground` 为 `true`；`pause`、`focus_end`、`background` 为 `false`；休息中或首页（未开始专注）回到前台的 `foreground` 为 `false`。
- 这是独立文件、独立键名，`docs/qa-log-schema.md` 的 43 键契约不变，`session-*.jsonl` 的逐行契约检查不受影响。

### 常亮验收场景

| 场景 | 操作 | `idle-*.jsonl` 应出现（按顺序） |
| --- | --- | --- |
| 手动暂停与继续 | 开始专注 → 点「暂停」→ 点「继续」 | `focus_start true` → `pause false` → `resume true` |
| 无人自动暂停与恢复 | `-scenario pauseWhileBreach -focusMinutes 1`（脚本 10–14 s 无人，超过 3 s 自动暂停，之后人回来；真机：离开画面 ≥3 s 再回来） | `pause false` → `resume true` |
| 专注中切后台再回来 | 专注计时中按 Home（`simctl launch` 其他 App 或真机上滑）→ 再切回 PostureLab | `background false` → `foreground true` |
| 休息中切后台再回来 | 休息计时中切后台 → 切回 | `background false` → `foreground false` |
| 首页切后台再回来 | 未点「开始」时切后台 → 切回 | `background false` → `foreground false` |

## 扩展用例（`verify.py case`，r16 沉淀）

| 用例 | 覆盖 |
|---|---|
| `ac12-manual-pause` → `ac12-manual-report` | `-autopause 10:10` 走孩子点「暂停/继续」同一路径；AC5 对账、`paused` 段、统计页「暂停」灰段；常亮 `pause`/`resume` |
| `no-person-occlusion` → `no-person-occlusion-report` | 无人自动暂停记 `no_person`，统计页「不在画面」 |
| `pause-clean` | `pauseWhileBreach` 跑满 35 s 再取证，AC5 PASS |
| `ac14-end-chime` / `ac14-end-none` | 结束音开 1 条 `cue_played end_chime` / 关 0 条 |
| `ac14-goal` / `ac14-goal-report` | `dailyGoal=6` 驱动主页分母与统计页「未达成」 |
| `idle-focus` | 专注中后台→`false`、前台→`true`，专注结束→`false`，休息中前台→`false` |
| `full-day-detecting` | 三番茄一天（含 `-firstSampleDelay 1.4` 识别中段）：AC1/AC5/AC7 |

`*-report` 用例沿用前一个用例的沙盒，要一起跑：`verify.py case --run <run-id> ac12-manual-pause ac12-manual-report`。
