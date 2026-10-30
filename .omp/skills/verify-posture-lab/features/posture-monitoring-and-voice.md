# 体态监测与语音提醒

主页冷启动即启动输入源：设置页/主页可见时深度与彩色输入运行，开始专注前就有 3D 人形点云（模拟器用 BodyRig 场景）；任何构建都不显示摄像头画面（ADR-0007、ADR-0008），统计页会停输入。关节由前置彩色帧的 Vision 识别给出（0.6.8），点云仍只来自 TrueDepth 深度。专注阶段中前 3 秒有效人脸样本静默建立校准基线，之后系统识别 8 种不良体态。坐姿越阈不会暂停番茄钟或弹窗，只有可发声体态连续越阈满 15 秒才播放本机预录 WAV 语音；无人暂停连续 3 秒触发，单次超过 300 秒记为 `interrupted`。

## Sub-features

- `posture-cloud`：`pomodoro_main` 常驻 3D 人形点云，背景干净；冷启动即显示（开始专注前就有）；未检测到人体时显示矢量轮廓；点云只来自 TrueDepth 深度（每个深度帧约 30 Hz 更新、每帧固定 600 点），彩色帧只进 Vision、不显示相机画面；设置页「形象模式」关闭时点云隐藏，因此只剩黑底与调试叠加层。
- `posture-joints-vision`（0.6.8）：关节来自 `VNDetectHumanBodyPoseRequest`（2D），Vision 在独立串行队列上约 10 Hz 推理、忙时丢帧、复用同一个请求；只交付鼻/双眼/双耳/颈/双肩，置信度门槛 0.5，双肩之一跑在鼻点上方则整帧双肩作废；关节配时间最近的深度帧，差超过 150 ms 整帧作废。日志侧证据是 `Documents/debug/joints-*.jsonl`（每帧一个关节对象，含 `c` 与 `v`）。
- `posture-thermal`（0.6.8）：`serious`/`critical` 时 Vision 降到 5 Hz、点云降到 15 Hz；降级起止各写一行 `thermal`（`thermal_degraded`），每秒的热状态、电量与降级标记在 `Documents/debug/perf-*.jsonl`。
- `posture-tuning`（真机项）：坐直时双肩可用帧占比 ≥ 80%，歪头与低头各 ≥ 50%，「肩点落在头上」的帧数为 0；验收用 `verify.py device-logs` 判定（见 SKILL.md 的「真机日志判定」「数据充分性门槛」与「模拟器测不到的项」）。坐直档的窗口优先取 DEBUG 分段测试模式 `-segmentTest 1` 写入的 `test_segment` 段标记，没有段标记才退回 `status_changed` 的 `good` 窗口。证据不足时 `device-logs` 返回 `INSUFFICIENT_DATA`（退出码 2），不是 PASS：关节全部不可见、点云点数恒为 0（没有一帧有点云）、会话短于 600 秒、有人在画面但可见关节帧过少，这四种情形都不算通过。点云那条判的是「有点云的帧点数固定且 > 0」，点数具体是多少不是判据。
- `posture-figure`（0.6.8 (19)）：人形是**每个关节各自一条时间线**——这一帧置信度 ≥ 0.5 的点画出来并按 0.15 s 平滑；低于门槛的点保持最后位置 300 ms、再用 200 ms 淡出，不影响其它关节（颈与右肩常年不过门槛，整组判定会让人形永远不出现）。只画鼻/双眼/双耳/颈/双肩与嘴轮廓（人脸置信度 ≥ 0.5 才画嘴），连线只有耳–眼、眼–眼、眼–耳、颈–左右肩，没有头部 M 形线。日志证据：`joints-*.jsonl` 的 `figure_points` / `figure_lines`。
- `posture-jitter`（0.6.8 (19)）：关键点抖动 p95 ≤ 1% 屏宽、点云抖动 p95 ≤ 2% 屏宽，口径是「相邻显示帧同一点的位移，只算静止帧（原始输入位移 ≤ 0.5% 屏宽），滚动 10 秒 p95」。读数在 `perf-*.jsonl` 的 `keypoint_jitter_p95` / `cloud_jitter_p95`（样本不足写 `null`），判定是 `verify.py device-logs` 的 `keypoint-jitter` / `cloud-jitter`。
- `posture-cloud-never-blank`（0.6.8 (19)）：检测到脸时点云从不空白。`cloud-*.jsonl` 每帧带 `face_detected` 与 `visible_points`，`device-logs` 的 `cloud-not-blank` 判「有脸的帧 `points > 0`、已上屏的帧 `visible_points > 0`」。任一项（不空白、p95 ≤ 2%）不达标时，按 issue #6 的约定去掉点云、只保留火柴人。
- `posture-right-shoulder-report`（0.6.8 (19)）：右肩可用帧 < 50% 时记录并上报，不改 0.5 置信度门槛。`perf-*.jsonl` 累计 `right_shoulder_frames` / `shoulder_frames`，`device-logs` 打印 `REPORT right-shoulder: 右肩可用 x/y 帧 = z%` 并写进 `verdict.json` 的 `rightShoulder`。
- `posture-frames-log`（0.6.8 (15)）：`Documents/debug/cloud-*.jsonl` 每个深度帧一行（帧呈现时刻、回调到达时刻、取深度/分割/点云耗时、实际点数、遮罩格数、有效深度占比、最近读数、是否降级、是否推给画布、上屏渲染耗时与延迟）；`joints-*.jsonl` 每帧带 `detected` 与模型原始置信度 `raw`，用来区分「没人」与「被 0.5 门槛过滤」；v0.6.8 (18) 起另带在场判定的证据：`presence_path`（`face_eyes` / `neck_shoulder` / `none`）、`face_detected`，以及 `neck`/`left_shoulder`/`right_shoulder` 三个过门槛后的置信度（详见 qa-log-schema.md 的 `joints-*.jsonl` 一节）。
- `posture-baseline`：专注启动后前 3 秒有效人脸样本中位数建立距离/俯仰基线。
- `posture-kinds`：识别 `desk_lean`、`near`、`head_forward`、`slouch`、`head_down`、`head_tilt`、`shoulder_tilt`、`chin_rest`。
- `posture-tiers`：稳定级、 中度级可发声；实验级只记录与调试高亮，永不触发任何提醒。
- `posture-voice`：可发声体态连续越阈 15 秒后播放预录 WAV；多体态按 `priority` 1..8 串行。
- `posture-absence`：连续 3 秒无人自动停表（中文文档与验收统一写作「无人」，不叫「离开」；统计页/历史图例文案写「不在画面」）；「在场」的判据是连续 3 帧有可靠证据（鼻过门槛且【找到人脸或双眼】或【颈/双肩】；只有鼻子不算有人，见 `PresenceGate`），日志写 `state: "no_person"` 与 `paused`/`resumed`，单次超过 300 秒转 `interrupted`。它与「离开」按钮是两件事：按钮只写历史 `abandoned`。
- `posture-overlay`：`debugEnabled` 开启时主页随时显示骨架（中文关节名：头/左眼/右眼/左耳/右耳/颈/躯干/左肩/右肩/左肘/右肘/左腕/右腕/左髋/右髋，只画到髋因为 JointID 没有膝/踝）与特征读数，每个指标带一行算法来源（距离=脸到相机距离；低头角度=基线俯仰−当前脸俯仰；歪头=|当前脸滚转−基线滚转|；肩线=左肩-右肩连线与水平夹角−基线；头高=鼻尖 y−基线头高；手到脸=min(左腕、右腕到鼻尖的距离)；头前伸=基线鼻深−当前鼻深；驼背=max(肩宽缩短比, 颈-躯干缩短比)），未开始专注时数值列显示 `—`，不遮挡操作按钮。

## How to get to it (user POV)

- 启动后进入 `pomodoro_main`，冷启动即有 3D 点云（无人体时为矢量轮廓），点击「开始专注」进入监测。
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
- **校验 300 秒中断（真实时钟）。** 用新增的 `long-absence` 场景跑满 301 秒：前 5 秒有人，之后一直无人，无人从约 5 s 起累加，脚本总长 320 s，足够越过 300 s 上限并留下 `interrupted` 记录。
  ```sh
  xcrun simctl launch "$SIM" me.xieal.posturelab.depth \
    -scenario long-absence -focusMinutes 5 -debug 0
  # 约 310 秒后应用会写 interrupted 到 Documents/pomodoro-history.json；
  # 想要更快复跑时可等脚本自动结束（320 s）后再取容器。
  ```
  `-sim-scenario long-absence` 是同一参数的别名。日志侧应看到无人开始的 `paused`、`status_changed state=no_person`，以及中断那一刻的 `session_ended`（历史 `"outcome": "interrupted"`）。单元测试仍覆盖 299/301 秒边界：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild ... -only-testing:PostureLabTests/PomodoroEngineTests test`。
- **调试叠加层。** `-debug 1` 的截图必须能看到带中文关节名的骨架/特征表（每个指标有算法来源行），且「暂停」「离开」仍可见；`-debug 0` 的截图必须没有关节数据与实验级文字。停驻（`-holdStart 1`）时的截图必须能看到点云且没有「离开」按钮（截图 `AC-parked-before-start`）。
- **证据。** 每个场景保留截图、`session-*.jsonl`、`Documents/` 与 `sandbox-audit.json`；实验级体态只应在日志/历史中出现，不应有 `reminder` 或 `speech_played`。

## Gotchas

- Q3 已确认专注启动后静默采集前 3 秒有效样本；当前代码尚未实现该路径，仍沿用持久化 `PostureBaseline` 或直立参考。验证时按实际日志记录 `baseline_*`，不要伪造“已静默校准”。
- Q4 已确认点云由 TrueDepth 深度图与人像分割遮罩合成；当前代码由关节点几何生成，真机 `ARFaceSampleSource` 只产出距离/俯仰，点云可能为空态。截图为空态时如实记录。
- Q4 已确认实验级 `head_forward` / `slouch` 永不触发任何提醒；当前代码在旧 `experimentalPostures` 开关打开时仍可能发一级事件。若日志出现 `reminder`/`speech_played`，按失败报告。
- Q2 已确认手动与无人暂停都计入 `pausedSeconds`；v0.5 起无人暂停的整段也累加（`PomodoroEngine` 在 `absentSince != nil` 时按样本间隔计入），与灰色 `paused` 段时间轴对账。
- 语音是预录 WAV，不是系统 TTS；`speech_played` 只证明片段开始，不证明房间听见。
- 模拟器没有真实摄像头（也没有前置彩色摄像头）；`deskLean` 等场景的 joints/depth 来自 `BodyRig`，不能把它们当作真机 TrueDepth 或 Vision 关节证据。真机项一律用 `verify.py device-logs`。
- 0.6.8 的关节来源不给出腕关节，`hand_to_face` 永远缺测，托腮（`chin_rest`）在真机上不会触发；脚本 rig 仍摆得出这个姿势，只用于回归。
- 隐私边界（0.4/0.5，ADR-0007 与 ADR-0005 修订）：任何构建都不显示摄像头画面，容器内也不能有任何图像文件（应用自绘调试图改为只留内存）。设备侧 `simctl io screenshot` 拍的证据图不属于容器。

## 扩展用例（`verify.py case`）

- `ac10-debug-on` / `ac10-debug-off`：调试叠加层开/关，「暂停/离开」坐标不变；`ac10-debug-on` 顺带取首页 foreground=false。
- `ac9-parked`：`-holdStart 1` 停驻主页只有两个图标按钮；自动写 `cloud-geometry.json`（点云包围盒占屏比）与 `cloud-ascii.txt`。也可单独 `verify.py png|ascii <png>`。
