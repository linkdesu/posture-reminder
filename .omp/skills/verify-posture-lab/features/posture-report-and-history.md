# 统计页与历史

统计页给家长看日、周、月三重视角：日视图是一条睡眠图式的彩色姿态时间轴（良好、各不良体态、灰色暂停段），周/月视图是完成番茄数、专注总时长与良好占比；历史来自本机 `Documents/pomodoro-history.json`，杀进程重启后仍在，家长可以清空。

## Sub-features

- `report-entry`：主页右上角 `chart.bar` 进入统计页；默认日视图。
- `report-scopes`：`report_day` / `report_week` / `report_month` 切换；三个界面名各自独立。
- `report-timeline`：日视图按 `postureSegments` 画彩色时间轴；`good`、8 种体态与 `paused` 都有颜色与图例。
- `report-accounting`：`focusedSeconds` + `pausedSeconds` 与记录墙钟时间对账；记录里的 `pausedSeconds` 与时间轴上 `paused` + `no_person` 段之和相等（0.6.8 (21) 起；单元测试 `PostureLabTests/PomodoroPauseAccountingTests`）。`no_person` 段只覆盖真正停表的那一段：无人前 3 秒仍算专注（`GLOSSARY.md`「无人暂停」），人回来后体态引擎 1 秒的恢复去抖也不会把这一段拉长。
- `report-persistence`：`Documents/pomodoro-history.json` 杀进程/重开仍在。
- `report-clear`：清空历史前弹确认；确认后本机历史与时间轴全部删除。

## How to get to it (user POV)

- `pomodoro_main` 右上角柱状图图标（accessibility label「统计页」）。
- 顶部「日 / 周 / 月」分段控件切换。
- 底部「清空历史」按钮，弹窗「清空全部历史？」。
- 左上角「主页」返回。

## Driving it with XCUITest & simctl/devicectl

Preconditions：

- `verify.py up` 完成。
- 用 `-seedHistory 30` 生成可画的日视图；真实历史由完成的番茄写入。

- **日/周/月截图。** 启动 `-seedHistory 30 -report day`，6 秒后截图；再以 `-report week`、`-report month` 重开并截图，证据分别命名。
- **重启持久化。** `verify.py drive` 的 `report` 场景先 seed 后截图，杀进程但**不重装**，再以 `-report day` 重开；`report-persistence.json` 记录重启前/后的记录数，二者必须相等且大于 0。
- **对账。** 用 `scripts/verify-pomodoro.py <log> --history <pomodoro-history.json> --expect-records <n> --quiet` 重算记录、时间轴覆盖、提醒计数与会话配对。
- **暂停段。** 用 `scripts/verify-acceptance.py <log> --history <history> --ac5 --quiet` 检查 `focusedSeconds + pausedSeconds` 与墙钟时间；日视图截图应能看到灰色 `paused` 段。
- **清空历史。** 用 XCUITest 打开统计页、点「清空历史」、确认；随后 `Documents/pomodoro-history.json` 应为空数组，重启后日视图显示空态。不要为了通过而跳过确认弹窗。
- **证据。** 保留三个范围截图、重启前后截图、`pomodoro-history.json`、`verification/*.txt`。

## Gotchas

- Q2 已确认手动暂停与无人暂停都计入 `pausedSeconds`，且与所有灰色 `paused` 段时长严格相等；v0.5 起无人暂停的整段也累加，`verify-acceptance.py --ac5` 应通过。仍按实际差异报告，不要修改断言。
- 0.6.8 (21) 起无人必须**连续 3 秒**才停表，前 3 秒仍计入专注；`pauseWhileBreach` 场景（10–14 s 无人）因此只该给 `pausedSeconds` 约 1 秒，`no_person` 段同样约 1 秒。两者不相等即 FAIL。
- `goodRatio` 的分母是“有体态数据的秒数”，不含 `no_person`；空日不画空时间轴，显示「这一天还没有姿态记录」。
- `-seedHistory 30` 会先清空再写入固定种子；它只用于截图，不是持久化证明。持久化必须用“杀进程、不重装、重开”。
- 统计页三个 scope 是三个 `screen` 名；截图文件名不要互相覆盖。
- 清空历史不可恢复；验证时先备份 `pomodoro-history.json` 到证据目录，再执行。

## 扩展用例（`verify.py case`）

- `ac6-week` / `ac6-month`：`-seedHistory 30 -report week|month`，与 seed 输入逐项复算（日视图与重启持久化由 `drive` 的 `report` 场景覆盖）。
