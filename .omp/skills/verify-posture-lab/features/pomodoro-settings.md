# 番茄钟设置

设置页让家长配置 11 项番茄钟参数，以及「监测」分区（灵敏度 segmented 低/中/高 + 形象模式开关，副标题：显示坐姿点云；关闭后点云隐藏，画面只在本机显示、不保存不上传）与「调试」分区（调试模式 + 实验性体态，副标题：头前伸和驼背只做记录与调试高亮，不发出声音）；所有修改写入本机，杀进程重启后仍然保留。设置页本身不启动、不暂停计时器：试听提示音只发声，不写 `cue_played`。

## Sub-features

- `settings-open`：主页右上角 `gearshape` 进入 `pomodoro_settings`。
- `settings-rhythm`：专注时长（5–60，步长 5）、短休息（1–15）、长休息（5–30）、几个专注后长休息（2–8）。
- `settings-manual-entry`：每个数值设置都可用数字键盘直接输入；点按即全选当前值，输入即替换；越界输入夹到最近合法值，专注时长再吸附到 5 分钟步长，不输入就离开（或把选中值删空后提交）保留原值，任何路径都不会存入 0。
- `settings-stepper`：`+/-` 步进器保留，范围与夹取同源于 `PomodoroSettings.ranges`。
- `settings-auto`：自动开始休息、自动开始下一个专注。
- `settings-goal`：每日目标番茄数（1–12）。
- `settings-cues`：结束提示音 `soft` / `chime` / `none`；「试听提示音」按钮播放当前选择，静音时按钮不可用。
- `settings-voice`：姿态语音开关与音量（同一行；关闭时音量滑杆变灰）。
- `settings-break-monitor`：休息时是否监测姿态。
- `settings-screen`：屏幕常亮。
- `settings-monitor`：「监测」分区——灵敏度 segmented（低/中/高，对应 `Sensitivity` 25/30/35 cm 与 25/20/15°）+ 形象模式开关（开时主页显示点云，关时点云隐藏、只剩黑底与调试叠加层）。
- `settings-experimental`：「调试」分区——调试模式开关（DEBUG 构建默认开，Release 默认关）+ 实验性体态开关（头前伸和驼背只做记录与调试高亮，不发出声音）。
- `settings-persist`：杀进程重启后逐项读回原值；「恢复默认设置」只重置 11 项番茄钟设置，不动灵敏度/形象模式/调试开关。

已删除：`结束前提醒`（以及它的一分钟提示音与 `warn_before_end` 事件来源）。设置项由 12 项变为 11 项。

## How to get to it (user POV)

- `pomodoro_main` 右上角齿轮图标（accessibility label「设置页」）。
- 或启动参数 `-settings 1` 直接打开。
- 左上角「主页」返回。

## Driving it with XCUITest & simctl/devicectl

Preconditions：

- `verify.py up --run <run-id>` 完成，应用已安装。
- 设置页的每行都有稳定标题；数值行带一个可编辑数字框（accessibility label「<标题>数值」）、单位文本与步进器；语音开关与音量在「姿态提醒」区块。

- **打开设置页。** 运行 `verify.py drive --run <run-id>` 的 `settings` 场景，启动 `-settings 1`，5 秒后截图 `scenarios/settings/settings.png`。
- **真实控件修改与持久化。** 运行：
  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project PostureLab.xcodeproj -scheme PostureLab \
    -destination "platform=iOS Simulator,id=C12DA589-2444-4F2E-A943-4D6BAFB02BF1" \
    -only-testing:PostureLabUITests/SettingsPersistenceUITests test
  ```
  该测试逐行读取当前值、用真实 Stepper/Toggle/Slider 修改、截图前/后、杀进程重启、逐行读回。整数行读的是数字框里的值。
- **分区结构。** 运行 `-only-testing:PostureLabUITests/SettingsSectionsUITests`：「监测」分区含灵敏度 segmented（低/中/高）与形象模式开关（截图 `AC-settings-sensitivity`、`AC-settings-avatar`）；「调试」分区含调试模式与实验性体态开关（截图 `AC-settings-experimental`）。
- **手动输入与夹取。** 运行 `-only-testing:PostureLabUITests/SettingsInputUITests`：点按数字框（当前值全选）、输入数字、点键盘上的「完成」提交；断言 `0 → 5`、`999 → 60`、`12 → 10`（专注）与 `99 → 15`（短休息），以及空输入保留原值与全选替换。证据截图名 `AC-input-select-all`、`AC-input-empty-keeps-value`。
- **提示音试听。** 同一测试的 `testPreviewIsAudibleWithoutStartingTheTimer`：点「试听提示音」后仍停留在设置页，返回主页后倒计时仍停驻（「开始专注」在、「暂停」不在）。试听不启动番茄钟、不写 `cue_played`。
- **提示音选择。** 设置页 `结束提示音` Picker 选择 `柔和铃声` / `铃声` / `静音`；对应 `EndSound.soft` / `.chime` / `.none`。阶段结束时是否真的播放由 `cue_played` 验证。
- **证据。** 保留设置页截图、XCUITest 的 `AC2-*` / `AC-input-*` 附件与重启后的截图；`verify.py evidence` 会确认 `settings.png` 存在。

## Gotchas

- Q4 已确认设置页包含 11 项番茄钟设置；0.3 轮起「监测」分区（灵敏度 segmented 低/中/高 + 形象模式）与「调试」分区（调试模式 + 实验性体态）已落在 `PomodoroSettingsView`，灵敏度/形象模式/实验性体态的控件以 `SettingsSectionsUITests` 截图为准。
- 语音开关与音量在界面上是一行，但底层是两个属性；XCUITest 必须成对修改。
- 数值行点按时全选当前值、输入即替换，提交发生在键盘「完成」或焦点移走时；不要假设输入框里预先清空，也不要假设离开时旧数字仍在——不输入就离开（或删空后提交）保留原值。
- 启动参数（`-focusMinutes`、`-presetSettings` 等）只在本轮覆盖，不写回用户设置；不要用它们证明持久化。
- `-settings 1` 是调试入口，不等于用户点击齿轮；真实入口仍要由 XCUITest 或截图验证。
- 「恢复默认设置」只持久化重置 11 项番茄钟设置，不动灵敏度/形象模式/调试开关；测试结束不要留下被改坏的设置，可用「恢复默认设置」或重装。
- 旧阅读设置页（提醒方式）已删除，`ReminderMode` 一并移除；但灵敏度/形象模式/实验性体态三个控件在 0.3 轮已回到设置页的「监测」与「调试」分区，不要按更旧的文档认为它们不存在。
