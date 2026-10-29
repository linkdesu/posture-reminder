# 体态监测与语音提醒

主页冷启动即启动输入源：设置页/主页可见时相机运行，开始专注前就有摄像头预览（真机 `CameraPreview` 共享 `ARSession`，画面仅上屏、不落盘、不上传）与 3D 人形点云（模拟器用 BodyRig 场景）；统计页仍会停相机。专注阶段中前 3 秒有效人脸样本静默建立校准基线，之后系统识别 8 种不良体态。坐姿越阈不会暂停番茄钟或弹窗，只有可发声体态连续越阈满 15 秒才播放本机预录 WAV 语音；无人暂停连续 3 秒触发，单次超过 300 秒记为 `interrupted`。

## Sub-features

- `posture-cloud`：`pomodoro_main` 常驻 3D 人形点云，背景干净；冷启动即显示（开始专注前就有）；真机另有摄像头预览，画面仅在本机屏幕上显示、不落盘、不上传（没有 RGB 落盘通路）；设置页「形象模式」关闭时预览与点云一起隐藏。
- `posture-baseline`：专注启动后前 3 秒有效人脸样本中位数建立距离/俯仰基线。
- `posture-kinds`：识别 `desk_lean`、`near`、`head_forward`、`slouch`、`head_down`、`head_tilt`、`shoulder_tilt`、`chin_rest`。
- `posture-tiers`：稳定级、 中度级可发声；实验级只记录与调试高亮，永不触发任何提醒。
- `posture-voice`：可发声体态连续越阈 15 秒后播放预录 WAV；多体态按 `priority` 1..8 串行。
- `posture-absence`：连续 3 秒无人自动停表（中文文档与验收统一写作「无人」，不叫「离开」；统计页/历史图例文案写「不在画面」）；日志写 `state: "no_person"` 与 `paused`/`resumed`，单次超过 300 秒转 `interrupted`。它与「离开」按钮是两件事：按钮只写历史 `abandoned`。
- `posture-overlay`：`debugEnabled` 开启时主页随时显示骨架（中文关节名：头/左眼/右眼/左耳/右耳/颈/躯干/左肩/右肩/左肘/右肘/左腕/右腕/左髋/右髋，只画到髋因为 JointID 没有膝/踝）与特征读数，每个指标带一行算法来源（距离=脸到相机距离；低头角度=基线俯仰−当前脸俯仰；歪头=|当前脸滚转−基线滚转|；肩线=左肩-右肩连线与水平夹角−基线；头高=鼻尖 y−基线头高；手到脸=min(左腕、右腕到鼻尖的距离)；头前伸=基线鼻深−当前鼻深；驼背=max(肩宽缩短比, 颈-躯干缩短比)），未开始专注时数值列显示 `—`，不遮挡操作按钮。

## How to get to it (user POV)

- 启动后进入 `pomodoro_main`，冷启动即有摄像头预览（真机）与 3D 点云，点击「开始专注」进入监测。
- 调试模式开启时（DEBUG 构建默认开；`-debug 0` 或设置页关闭「调试模式」后关闭）主页随时显示骨架/特征叠加；未开始专注时数值列显示 `—`；关闭后不显示。
- 体态越阈不改变布局；只有 15 秒后的预录语音，以及点云上对应部位的着色。
- 无人时倒计时冻结、界面安静；回来后继续。

## Driving it with XCUITest & simctl/devicectl

Preconditions：

- `verify.py up` 与 `doctor` 已通过。
- 使用脚本化 `-scenario deskLean`，模拟器无摄像头也能产生关节点与深度帧。

- **跨体态语音。** `verify.py drive --run <run-id>` 的 `posture-voice` 场景启动 `-scenario deskLean -focusMinutes 1 -shortBreakMinutes 1 -voice 1 -debug 1`，30 秒截图。
- **校验语音。** `verify.py evidence --run <run-id>` 运行 `scripts/verify-acceptance.py <log> --ac4 --quiet`：同一时刻多条 `speech_played` 不得重叠，播放顺序按 `PostureKind.priority`；同时检查 `desk_lean` 二级语音至少出现一次。
- **校验无人暂停。** `verify.py drive` 的 `pause` 场景启动 `pauseWhileBreach`，30 秒截图；`verify.py evidence` 运行 `scripts/verify-acceptance.py <log> --history <pomodoro-history.json> --ac5 --quiet`，要求存在暂停记录且 `focusedSeconds` 不包含暂停。
- **校验 300 秒中断。** 单元测试覆盖 299/301 秒边界：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild ... -only-testing:PostureLabTests/PomodoroEngineTests test`；模拟器长跑不适合作为唯一证据。
- **调试叠加层。** `-debug 1` 的截图必须能看到带中文关节名的骨架/特征表（每个指标有算法来源行），且「暂停」「离开」仍可见；`-debug 0` 的截图必须没有关节数据与实验级文字。停驻（`-holdStart 1`）时的截图必须能看到摄像头预览/点云且没有「离开」按钮（截图 `AC-parked-before-start`）。
- **证据。** 每个场景保留截图、`session-*.jsonl`、`Documents/` 与 `sandbox-audit.json`；实验级体态只应在日志/历史中出现，不应有 `reminder` 或 `speech_played`。

## Gotchas

- Q3 已确认专注启动后静默采集前 3 秒有效样本；当前代码尚未实现该路径，仍沿用持久化 `PostureBaseline` 或直立参考。验证时按实际日志记录 `baseline_*`，不要伪造“已静默校准”。
- Q4 已确认点云由 TrueDepth 深度图与人像分割遮罩合成；当前代码由关节点几何生成，真机 `ARFaceSampleSource` 只产出距离/俯仰，点云可能为空态。截图为空态时如实记录。
- Q4 已确认实验级 `head_forward` / `slouch` 永不触发任何提醒；当前代码在旧 `experimentalPostures` 开关打开时仍可能发一级事件。若日志出现 `reminder`/`speech_played`，按失败报告。
- Q2 已确认手动与无人暂停都计入 `pausedSeconds`；当前记录只累加手动暂停。用 `pomodoro-history.json` 对账时按实际值报告差异。
- 语音是预录 WAV，不是系统 TTS；`speech_played` 只证明片段开始，不证明房间听见。
- 模拟器没有真实摄像头；`deskLean` 等场景的 joints/depth 来自 `BodyRig`，不能把它们当作真机 TrueDepth 证据。
- 隐私边界（0.3 轮修订，ADR-0005）：真机主页/设置页冷启动即有摄像头预览，画面仅在本机屏幕上显示，不落盘、不上传，没有任何 RGB 落盘通路——「不显示 RGB 画面」的旧口径作废；截图/日志里出现摄像头画面属于预期，但容器审计（`audit-sandbox.py`）仍必须没有任何 RGB 文件落盘。
