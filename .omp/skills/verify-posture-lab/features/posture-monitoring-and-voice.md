# 体态监测与语音提醒

专注阶段中，主页用 3D 人形点云映出孩子的姿态；前 3 秒有效人脸样本静默建立校准基线，之后系统识别 8 种不良体态。坐姿越阈不会暂停番茄钟或弹窗，只有可发声体态连续越阈满 15 秒才播放本机预录 WAV 语音；无人暂停连续 3 秒触发，单次超过 300 秒记为 `interrupted`。调试模式开启时叠加关节点与特征读数。

## Sub-features

- `posture-cloud`：`pomodoro_main` 常驻 3D 人形点云，背景干净，不显示 RGB 画面。
- `posture-baseline`：专注启动后前 3 秒有效人脸样本中位数建立距离/俯仰基线。
- `posture-kinds`：识别 `desk_lean`、`near`、`head_forward`、`slouch`、`head_down`、`head_tilt`、`shoulder_tilt`、`chin_rest`。
- `posture-tiers`：稳定级、 中度级可发声；实验级只记录与调试高亮，永不触发任何提醒。
- `posture-voice`：可发声体态连续越阈 15 秒后播放预录 WAV；多体态按 `priority` 1..8 串行。
- `posture-absence`：连续 3 秒无人自动停表；单次超过 300 秒转 `interrupted`。
- `posture-overlay`：`debugEnabled` 开启时专注中显示关节与特征读数，不遮挡操作按钮。

## How to get to it (user POV)

- 启动后进入 `pomodoro_main`，点击「开始专注」。
- 勾选 ` -debug 1` 或设置页「调试模式」后，专注中可见骨架/特征叠加。
- 体态越阈不改变布局；只有 15 秒后的预录语音，以及点云上对应部位的着色。
- 无人时倒计时冻结、界面安静；回来后继续。

## Driving it with XCUITest & simctl/devicectl

Preconditions：

- `verify.py up` 与 `doctor` 已通过。
- 使用脚本化 `-scenario deskLean`，模拟器无摄像头也能产生关节点与深度帧。

- **跨体态语音。** `verify.py drive --run <run-id>` 的 `posture-voice` 场景启动 `-pomodoro 1 -scenario deskLean -focusMinutes 1 -shortBreakMinutes 1 -voice 1 -debug 1`，30 秒截图。
- **校验语音。** `verify.py evidence --run <run-id>` 运行 `scripts/verify-acceptance.py <log> --ac4 --quiet`：同一时刻多条 `speech_played` 不得重叠，播放顺序按 `PostureKind.priority`；同时检查 `desk_lean` 二级语音至少出现一次。
- **校验无人暂停。** `verify.py drive` 的 `pause` 场景启动 `pauseWhileBreach`，30 秒截图；`verify.py evidence` 运行 `scripts/verify-acceptance.py <log> --history <pomodoro-history.json> --ac5 --quiet`，要求存在暂停记录且 `focusedSeconds` 不包含暂停。
- **校验 300 秒中断。** 单元测试覆盖 299/301 秒边界：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild ... -only-testing:PostureLabTests/PomodoroEngineTests test`；模拟器长跑不适合作为唯一证据。
- **调试叠加层。** `-debug 1` 的截图必须能看到关节点/特征表，且「暂停」「放弃」仍可见；`-debug 0` 的截图必须没有关节数据与实验级文字。
- **证据。** 每个场景保留截图、`session-*.jsonl`、`Documents/` 与 `sandbox-audit.json`；实验级体态只应在日志/历史中出现，不应有 `reminder` 或 `speech_played`。

## Gotchas

- Q3 已确认专注启动后静默采集前 3 秒有效样本；当前代码尚未实现该路径，仍沿用持久化 `PostureBaseline` 或直立参考。验证时按实际日志记录 `baseline_*`，不要伪造“已静默校准”。
- Q4 已确认点云由 TrueDepth 深度图与人像分割遮罩合成；当前代码由关节点几何生成，真机 `ARFaceSampleSource` 只产出距离/俯仰，点云可能为空态。截图为空态时如实记录。
- Q4 已确认实验级 `head_forward` / `slouch` 永不触发任何提醒；当前代码在旧 `experimentalPostures` 开关打开时仍可能发一级事件。若日志出现 `reminder`/`speech_played`，按失败报告。
- Q2 已确认手动与无人暂停都计入 `pausedSeconds`；当前记录只累加手动暂停。用 `pomodoro-history.json` 对账时按实际值报告差异。
- 语音是预录 WAV，不是系统 TTS；`speech_played` 只证明片段开始，不证明房间听见。
- 模拟器没有真实摄像头；`deskLean` 等场景的 joints/depth 来自 `BodyRig`，不能把它们当作真机 TrueDepth 证据。
