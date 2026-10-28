# 番茄钟设置

设置页让家长配置 12 项番茄钟参数、灵敏度档位与调试模式开关；所有修改写入本机，杀进程重启后仍然保留。设置页本身不启动或暂停计时器。

## Sub-features

- `settings-open`：主页右上角 `gearshape` 进入 `pomodoro_settings`。
- `settings-rhythm`：专注时长（5–60，步长 5）、短休息（1–15）、长休息（5–30）、几个专注后长休息（2–8）。
- `settings-auto`：自动开始休息、自动开始下一个专注。
- `settings-goal`：每日目标番茄数（1–12）。
- `settings-cues`：结束提示音 `soft` / `chime` / `none`，结束前 1 分钟提醒。
- `settings-voice`：姿态语音开关与音量（同一行；关闭时音量滑杆变灰）。
- `settings-break-monitor`：休息时是否监测姿态。
- `settings-screen`：屏幕常亮。
- `settings-sensitivity`：低 25 cm/25°、中 30 cm/20°、高 35 cm/15°。
- `settings-debug`：调试模式开关。
- `settings-persist`：杀进程重启后逐项读回原值；「恢复默认设置」回到默认。

## How to get to it (user POV)

- `pomodoro_main` 右上角齿轮图标（accessibility label「设置页」）。
- 或启动参数 `-pomodoro 1 -settings 1` 直接打开。
- 左上角「主页」返回。

## Driving it with XCUITest & simctl/devicectl

Preconditions：

- `verify.py up --run <run-id>` 完成，应用已安装。
- 设置页的每行都有稳定标题与数值文本；语音开关与音量在「姿态提醒」区块。

- **打开设置页。** 运行 `verify.py drive --run <run-id>` 的 `settings` 场景，启动 `-pomodoro 1 -settings 1`，5 秒后截图 `scenarios/settings/settings.png`。
- **真实控件修改与持久化。** 运行：
  ```sh
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project PostureLab.xcodeproj -scheme PostureLab \
    -destination "platform=iOS Simulator,id=C12DA589-2444-4F2E-A943-4D6BAFB02BF1" \
    -only-testing:PostureLabUITests/SettingsPersistenceUITests test
  ```
  该测试逐行读取当前值、用真实 Stepper/Toggle/Slider 修改、截图前/后、杀进程重启、逐行读回。
- **提示音选择。** 设置页 `结束提示音` Picker 选择 `柔和铃声` / `铃声` / `静音`；对应 `EndSound.soft` / `.chime` / `.none`。声音是否真的播放由 `cue_played` 验证。
- **灵敏度。** 设置页灵敏度控件选择低/中/高；新会话的 `config` 行应显示对应 `sensitivity` 与阈值（25/25、30/20、35/15）。
- **证据。** 保留设置页截图、XCUITest 的 `AC2-*` 附件与重启后的截图；`verify.py evidence` 会确认 `settings.png` 存在。

## Gotchas

- Q4 已确认设置页包含 12 项番茄钟设置 + 灵敏度 + 调试模式；当前 `PomodoroSettingsView` 只有 12 行 + 调试，灵敏度控件仍在旧 `SettingsView`。按实际界面报告，不要声称番茄钟设置页有灵敏度。
- 语音开关与音量在界面上是一行，但底层是两个属性；XCUITest 必须成对修改。
- 启动参数（`-focusMinutes`、`-presetSettings` 等）只在本轮覆盖，不写回用户设置；不要用它们证明持久化。
- `-settings 1` 是调试入口，不等于用户点击齿轮；真实入口仍要由 XCUITest 或截图验证。
- 恢复默认会持久化覆盖全部 12 项；测试结束不要留下被改坏的设置，可用「恢复默认设置」或重装。
