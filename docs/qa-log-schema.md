# QA 日志结构——如何阅读 PostureLab 会话日志

这是番茄钟会话日志的参考。它描述 `FileDebugLogger` 写出、`scripts/verify-session.py` 与 `scripts/verify-acceptance.py` 读取的日志格式。它是日志参考，不是 PRD 的复述；日志为何是契约见 `docs/adr/0002-jsonl-log-contract-with-qa.md`，领域词汇见 `GLOSSARY.md`。日志结构是与 QA 的契约：新增、重命名或删除键对脚本的破坏程度与行为变更相同，落地前必须与 QA 协调。

**v0.6 是一次破坏性的契约变更：键集从 38 个增至 42 个（新增 `segment_kind`、`segment_start`、`segment_end`、`segment_seconds`），事件表新增 `segment`。** 按 ADR-0002，schema 变更必须先让 QA 知情；本轮由 TL 负责把这次变更写进 `tmp/handoff/omp-questions.md` 告知 QA，本文档只记录契约本身。倒计时与专注起点同时改用墙钟口径（见「ts 与 t 不是一回事」一节末尾），新增的「识别中」段见「识别中段与时间轴不变量」。

**v0.6.8 (16) 再增两个键：`baseline_roll_deg`、`baseline_head_height`（只在 `calibration_done` 行非 null），键集 43 → 45；新增事件 `calibration_incomplete`（3 秒内有效横滚样本不足时写一行，`message` 说明原因），`calibration_done` 保留并携带个人横滚基线。`features` 行的 `feature_values` 里，未测量的读数 `value` 为 `null`（不再写「门槛的一半」），`over` 为 false。**

**v0.6.8 是一次契约变更：键集从 42 个增至 43 个（新增 `thermal_degraded`，布尔），事件表新增 `thermal`（发热降级起止各一行）。** 已经按 42 键读取日志的读者必须接受第 43 个键；不关心发热的读者可以忽略它。按 ADR-0002，这次变更同样由 TL 在报告里告知 QA。

**v0.6.1 不改变键数，也不新增事件：** 只给 `segment_kind` 增加取值 `no_data`（「无数据」段——首样本之后样本流中断的那段墙钟时间）。按取值穷举 `segment_kind` 的读者需要接受这个新值。详见「样本中断与「无数据」段」。

**v0.6.3 同样不改变键数，也不新增事件：** 时间轴段种类（`segment_kind` 词表，以及记录里 `postureSegments[].kind`）增加取值 `no_person`——**无人自动暂停**的那段墙钟时间，图例与统计页写「不在画面」。只有孩子自己点的「暂停」仍写 `paused`。停表行为、`pausedSeconds` 累计与「单次无人超过 300 秒记 `interrupted`」的口径一律不变；`no_person` 段与 `paused` 段一样不产生 `reminder`、不进坏姿势统计、不进良好占比分母，也**不写 `segment` 行**（`segment` 事件仍只由 `detecting` 与 `no_data` 关闭时产生）。按取值穷举的读者需要接受这个取值。

## `ts` 与 `t` 不是一回事

请仔细读一遍，因为这是最容易弄错的一点：

- **`ts` 是 Unix 纪元毫秒**——绝对墙上时钟时刻，即自 1970-01-01T00:00:00Z 起的毫秒数。它在**每一行**都填写。
- **`t` 是会话开始后的秒数**——相对偏移，会话开始时为 `0`，只有携带会话时间的事件才填写。

它们是两个不同的量，单位也不同。**二者不可互换，也都不会被重命名。** 不要把两者都叫作“时间戳”：`ts` 是墙上时钟时间戳，`t` 是会话相对时间。如果你把 `ts` 与 `t` 相比，你是在拿“1970 年起的毫秒”与“会话开始后的秒”作比较，算术没有意义。

**v0.6 起，番茄钟倒计时与专注的 `startedAt` 取墙钟口径。** 专注的起点就是孩子点「开始」的那一刻（epoch 秒），倒计时由“当前墙钟 − `startedAt` − 该专注累计暂停时长”推算，不再依赖样本时钟：一个姿态样本都还没到时，倒计时照样在走。样本时钟只提供人脸在场信息——有没有一张可测量的人脸，决定 `paused` / `resumed` 与 `state: "no_person"`，不决定还剩多少秒。`pomodoro_tick` 仍是每秒一行：它是倒计时的观测序列，不是计时的来源；`remaining_seconds` 由墙钟推算，不因样本时钟抖动而累积误差。点「开始」到该专注第一个姿态样本之间的那段墙钟时间单独记成「识别中」段（见「识别中段与时间轴不变量」），不并入第一段，也不丢弃。

## 文件位置

位于应用沙盒的 `Documents/` 下：

- `Documents/debug/session-<ISO8601>.jsonl`——每次启动一个 JSONL 文件。文件名是启动时间的 ISO8601 表示并去掉冒号，例如 `2026-10-17T01:23:45Z` 启动会产出 `session-2026-10-17T012345Z.jsonl`。每次新运行写一个新文件；`run-scenarios.sh` 选取最新的那个。
- 应用容器内**没有任何图像文件**（v0.5 起）：页面截图只在内存里渲染，供调试时查看，不写 PNG。留档截图由验收脚本用 `simctl io screenshot` / 外部命令从设备侧拍摄，它们不在 App 容器里。

同目录（`Documents/debug/`）还有三份 **DEBUG 构建专用**的原始记录，它们与上面那份 43 键契约无关（另一个文件、另一套键名），**不掺进 `session-*.jsonl` 的任何键**：

| 文件 | 频率 | 用途 |
|---|---|---|
| `perf-<ISO8601>.jsonl` | 每秒一行 | 汇总：渲染帧数/帧率/最大帧间隔、六步耗时（采集/分割/点云/Vision/判定/渲染）的均值与最大值、点云间隔 p95 与最大值、点数极值、热状态、电量、是否降级 |
| `cloud-<ISO8601>.jsonl` | **每个深度帧一行**（约 30 Hz） | 逐帧原始事实：帧呈现时刻、回调到达时刻、三步耗时、**实际点数**、遮罩格数、有效深度占比、最近读数、是否降级、是否推给画布、上屏渲染耗时与延迟 |
| `joints-<ISO8601>.jsonl` | **每个 Vision 帧一行**（约 10 Hz） | 每帧关节：`detected`（模型是否看到人）、`raw`（模型原始置信度，0.5 门槛之前）、`joints`（过门槛后的置信度与可见性）、`stale`、`shoulders_available`、`shoulders_invalidated` |

### `cloud-*.jsonl` 的键

一行 = 一个深度帧，`0.6.8 (15)` 起才有：

```json
{"t":1793355411156,"frame_s":12.345,"arrival_s":12.351,"depth_ms":1.87,"segment_ms":8.80,
 "cloud_ms":0.20,"points":600,"mask_cells":1234,"depth_valid":0.970,"depth_nan":0.000,
 "nearest_m":0.42,"degraded":false,"cloud_emitted":true,"render_ms":0.40,
 "render_latency_ms":21.50}
```

- `t`：写行时的 epoch 毫秒（这一帧上屏后写，因此晚于帧自己的时刻）；`frame_s` 是深度帧自己的呈现时刻（会话时钟，秒），**判点云节奏用它**；`arrival_s` 是回调到达时刻，两者之差是排队时间。
- `depth_ms` / `segment_ms` / `cloud_ms`：取深度、分割、点云三步各自的耗时。
- `points`：这一帧实际生成的点数；`mask_cells`：分割遮罩格数（0 = 这一帧没分割出人体）。
- `depth_valid`：有效深度读数占比（0...1）。**它接近 1 而 `mask_cells` 为 0，说明传感器正常、只是画面里没有比背景近 10 cm 的连通块。**
- `depth_nan`：NaN 读数占比（0...1）。TrueDepth 的 Float32 深度图用 NaN 表示「这里没有读数」；`depth_valid` 为 0 且 `depth_nan` 为 1 就是整帧 NaN——0.6.8 (15) 关掉深度滤波时真机每次都是这个样子，分割拿不到输入、点云恒为 0。排查「点云为什么是空的」先看这两列：`depth_valid≈1` = 没人，`depth_nan≈1` = 深度图不可用。
- `nearest_m`：这一帧最近的深度读数，米；没有读数时为 `null`。
- `degraded` / `cloud_emitted`：这一帧是否处于发热降级、点云是否推给了画布（降级时隔帧推）。
- `render_ms` / `render_latency_ms`：画布为这一帧花的重绘时间、从回调到上屏的延迟。
- `visible_points`：画布这一帧**实际画在屏幕上**的点数（投影后落在画面矩形内）；0 表示点被投影/裁剪吃掉了，不是采集层没有点（0.6.8 (16) 排查「凑近点云消失」用）。**没有人体时画布暂停（界面只有矢量轮廓，不重绘），这两个字段是 `null`，不是 0。**

### `joints-*.jsonl` 的键

一行 = 一个 Vision 帧：

```json
{"t":1793355411149,"session_t":0.280,"detected":true,"stale":false,
 "shoulders_available":false,"shoulders_invalidated":false,
 "raw":{"nose":0.71,"leftEye":0.52,…, "rightShoulder":0.44},
 "joints":{"nose":{"c":0.71,"v":true},"leftEye":{"c":0.52,"v":true},…,
           "rightShoulder":{"c":null,"v":false}}}
```

- `detected`：模型这一帧是否报出了人。`false` = 画面里没人；`true` 而某关节 `v=false`、`raw` 有分数 = 模型看到了但**被 0.5 门槛过滤**。
- `raw`：八个关节在门槛之前的原始分数；模型没报这个关节时为 `null`。它只用于看模型表现，不参与判定。
- `joints`：过门槛后的置信度 `c` 与可见性 `v`；不可见关节 `c` 为 `null`。
- `stale`：关节与深度帧的配对超过 150 ms 而过期，这一帧关节全部不可见。
- `shoulders_available` / `shoulders_invalidated`：双肩是否可用、是否因为落在鼻点以上被整帧作废（真机要求作废帧数为 0）。

`0.6.8 (15)` 的 `verify.py device-logs` 按这三份文件判 PASS / FAIL / **INSUFFICIENT_DATA**；数据不充分（关节全部不可见、点数为 0、会话短于 600 秒、有人时段的可见关节帧过少）时如实返回 `INSUFFICIENT_DATA`，不判 PASS。

日志器只在调试模式开启时工作（`FileDebugLogger.isEnabled`）；关闭时不写任何文件。

### 从设备取出文件

`devicectl` 可以复制整个应用数据容器（或其中某个子目录）：

```sh
xcrun devicectl device copy from \
  --device <device-id> \
  --domain-type appDataContainer \
  --domain-identifier me.xieal.posturelab.depth \
  --source Documents \
  --destination <local-round-directory>
```

这会把 `Documents/`——包括 `debug/session-*.jsonl` 与 `pomodoro-history.json`——取到本轮目录（容器内没有截图目录）。模拟器中的等价命令是 `xcrun simctl get_app_container <sim-id> me.xieal.posturelab.depth data`。`scripts/run-scenarios.sh` 两者都会做，然后把最新的 `session-*.jsonl` 交给 `scripts/verify-session.py`。

## 行格式与完整键集

每行一个 JSON 对象，UTF-8，以换行结尾。**每行携带全部 43 个键**（v0.5 以前是 38 个，v0.6 新增四个 `segment_*` 键，v0.6.8 新增 `thermal_degraded`）。写入器在每行编码完整键集，不适用值写成 JSON `null`，因此读者**永远不必检查键是否存在**——对某个事件没有意义的键以 JSON `null` 存在，而不是缺失。每行唯一的变化是哪些键非 `null`。

`scripts/verify-session.py` 仍把其中六个作为 P1 拒绝条件硬校验（`REQUIRED_KEYS`）：`ts`、`event`、`state`、`screen`、`distance_cm`、`pitch_deg`。这六个键在每行都非 `null`。

## 键

| 键 | 类型 | 含义 |
|---|---|---|
| `ts` | Int64 | 产出该行时的 Unix 纪元**毫秒**。每行都存在且非 `null`。 |
| `t` | Double? | **会话开始后的秒数。** 只有携带时间的事件才填写（`sample`、`status_changed`、`features`、`reminder`、`paused`、`resumed`）；其余为 `null`。 |
| `wall_clock` | String? | 与 `ts` 同一时刻的 ISO8601 表示（`withInternetDateTime`）。便于人读；算术请用 `ts`。 |
| `event` | String? | 事件类型。见事件表。 |
| `state` | String? | 该行之后的体态状态。在 `status_changed` 行它是新状态；在其他每一行，写入器盖上它最近看到的状态（初始为 `good`）。永不为 `null`。 |
| `screen` | String? | 该行对应的可见界面。在 `screen_shown` 行它是刚展示的界面；其他行写入器盖上最近看到的界面（初始为 `pomodoro_main`，即应用启动页）。永不为 `null`。 |
| `distance_cm` | Double? | 该 tick 的样本/状态/提醒对应的到书本距离，单位厘米；未检测到人脸或事件不携带样本时为 `null`。 |
| `pitch_deg` | Double? | 同一 tick 的头部俯仰角，单位度；未检测到人脸时为 `null`。 |
| `alert_type` | String? | 提醒对应的体态：八个 `PostureKind` rawValue 之一（见 `alert_type` 词汇）。在 `reminder`、`speech_timeout`、`speech_unavailable` 与 `speech_played` 行填写。 |
| `level` | Int? | 提醒级别：`1`（轻提示）或 `2`（语音）。在 `reminder`、`speech_timeout` 与 `speech_played` 行填写。 |
| `breach_seconds` | Double? | 在 `reminder` 行：该回合在本次提醒时累计的越阈秒数。无人暂停会停止累加器，因此它是墙上时间减去该回合内的任何暂停，可能落后于从回合首个越阈样本起的距离。 |
| `sensitivity` | String? | 在 `config` 行：`low` / `medium` / `high`。 |
| `distance_threshold_cm` | Double? | 在 `config` 行：本次会话的“太近”阈值，单位厘米。 |
| `pitch_threshold_deg` | Double? | 在 `config` 行：本次会话的“低头”阈值，单位度。 |
| `baseline_distance_cm` | Double? | 在 `calibration_done` 行：校准后的基线距离（非空校准样本的中位数）。 |
| `baseline_pitch_deg` | Double? | 在 `calibration_done` 行：校准后的基线俯仰角，即“低头”的参照。 |
| `baseline_roll_deg` | Double? | 在 `calibration_done` 行（v0.6.8 (16)）：校准得到的个人横滚基线（度）。歪头按 `abs(当前横滚 − 这个值) > 15°` 判定。 |
| `baseline_head_height` | Double? | 在 `calibration_done` 行（v0.6.8 (16)）：头部相对肩线高度的基线（归一化），低头规则的第二路信号。 |
| `total_seconds` | Double? | 在 `session_ended` 行：检测到人脸的在座时间。 |
| `good_seconds` | Double? | 在 `session_ended` 行：没有任何体态越阈的时间。 |
| `near_seconds` | Double? | 在 `session_ended` 行：“太近”越阈的累计时间。 |
| `head_down_seconds` | Double? | 在 `session_ended` 行：“低头”越阈的累计时间。 |
| `paused_seconds` | Double? | 在 `session_ended` 行：未检测到人脸的时间（不计入 `total_seconds`）。 |
| `near_count` | Int? | 在 `session_ended` 行：达到一级的“太近”回合数。 |
| `near_remind_count` | Int? | 在 `session_ended` 行：“太近”的提醒**行**数，两个级别都算。 |
| `head_down_count` | Int? | 在 `session_ended` 行：达到一级的“低头”回合数。 |
| `head_down_remind_count` | Int? | 在 `session_ended` 行：“低头”的提醒**行**数，两个级别都算。 |
| `longest_good_streak_seconds` | Double? | 在 `session_ended` 行：最长连续良好秒数。 |
| `scenario` | String? | 在 `session_started` 行：脚本化场景名；相机运行为 `null`。 |
| `message` | String? | 在 `cue_played` 行：提示音名称——`end_soft` 或 `end_chime`。其他行为 `null`。 |
| `battery_level` | Double? | 电量比例 `0...1`。**由写入器采样**，不是事件驱动——见下文。 |
| `thermal_state` | String? | `nominal` / `fair` / `serious` / `critical`。**由写入器采样**——见下文。 |
| `highlighted_feature` | String? | 在 `features` 行：调试叠加层当前标红的 `PostureFeature` rawValue；没有高亮时为 `null`。 |
| `feature_values` | Object? | 在 `features` 行：每项特征一个条目，键为 `PostureFeature` rawValue，值为 `{"value": …, "threshold": …, "over": …}`（见下文）。其他行为 `null`——但与其他键一样，键本身在每行都存在。 |
| `view_mode` | String? | 在 `view_mode` 行：`avatar`（点云形象）或 `board`（黑板回退）。 |
| `overlay_on` | Bool? | 在 `view_mode` 行：调试骨架/特征叠加层是否开启。 |
| `avatar_on` | Bool? | 在 `view_mode` 行：形象模式是否开启。 |
| `posture_stats` | Object? | 在 `session_ended` 行：每个 `PostureKind` rawValue 一个条目，值为 `{"episodes": …, "reminders": …, "seconds": …}`（见下文）。其他行为 `null`——但与其他键一样，键本身在每行都存在。 |
| `remaining_seconds` | Double? | 在 `pomodoro_tick` 行：计时器当前阶段剩余秒数。其他行为 `null`——但与其他键一样，键本身在每行都存在。 |
| `phase` | String? | 在 `pomodoro_tick` 行：当前阶段的 `PomodoroPhase` rawValue，`focus` / `shortBreak` / `longBreak`。其他行为 `null`——但与其他键一样，键本身在每行都存在。 |
| `segment_kind` | String? | 在 `segment` 行：被关闭的那段时间轴段的种类，取值 `detecting`（「识别中」段，从点击「开始」到该专注第一个姿态样本）或 `no_data`（「无数据」段，v0.6.1：首样本之后样本流中断、下一个样本或专注结束才闭合）。其他行为 `null`。**v0.6.3 起时间轴段种类还有 `no_person`（无人自动暂停）与 `paused`（孩子手动暂停）**，但这两者只写在记录的 `postureSegments[].kind` 里，不会出现在 `segment` 行。 |
| `segment_start` | Int64? | 在 `segment` 行：该段起点的 Unix 纪元**毫秒**。`detecting` 是孩子点「开始」的墙钟时刻；`no_data` 是中断前**最后一个样本**到达的墙钟时刻。其他行为 `null`。 |
| `segment_end` | Int64? | 在 `segment` 行：该段终点的 Unix 纪元**毫秒**。`detecting` 是该专注第一个姿态样本到达的墙钟时刻；`no_data` 是让样本流恢复的那个样本（或专注结束）的墙钟时刻。其他行为 `null`。 |
| `segment_seconds` | Double? | 在 `segment` 行：该段时长，秒，等于 `(segment_end − segment_start) / 1000`。其他行为 `null`。 |
| `thermal_degraded` | Bool? | 在 `thermal` 行（v0.6.8）：`true` 表示发热降级开始，`false` 表示结束。其他行为 `null`，键本身仍然存在。 |

这四个 `segment_*` 键只在 `segment` 行非 `null`，`thermal_degraded` 只在 `thermal` 行非 `null`；其余所有行都写 JSON `null`，键本身仍然存在。

### `feature_values` 的嵌套结构

`feature_values` 是逐 tick 的对象键；`posture_stats`（下一节）是汇总的对象键，其他键的值都是标量。它的键是八个 `PostureFeature` rawValue（`distance`、`head_pitch`、`head_roll`、`shoulder_tilt`、`head_height_drop`、`hand_to_face`、`head_forward`、`slouch`）；每个映射到一个固定三元组：

```json
"feature_values": {
  "distance": { "value": 24.3, "threshold": 30.0, "over": true }
}
```

- `value`——本样本对该特征的读数，使用特征自己的单位（厘米、度、米或归一化比例；见 `GLOSSARY.md` 中的 `PostureFeature`）。**v0.6.8 (16) 起，缺测的读数写 `null`**（不再写「阈值的一半」）；界面显示「未测量」，不提醒、也不计入良好占比的分母。
- `threshold`——本次会话判定该值所用的阈值。
- `over`——该值是否越阈。

读数所参照的基线刻意**不**放进三元组；QA 从 `calibration_done` 行读取。输入缺失的特征仍然存在，其 `value` 取阈值的一半、`over` 为 `false`——缺失的测量永远不会被记成越阈。

### `posture_stats` 的嵌套结构

`posture_stats` 只在 `session_ended` 行填写，其他行为 JSON `null`。每个 `PostureKind` rawValue 一个条目——全部八个，包括两个实验级体态——因此消费者不必检查某个体态是否存在。每个条目是固定三元组：

```json
"posture_stats": {
  "near": { "episodes": 1, "reminders": 2, "seconds": 24.9 }
}
```

- `episodes`——该体态达到一级的回合数，无论是否发声。对 `near` 与 `head_down`，它与 `near_count` / `head_down_count` 相同。
- `reminders`——该体态发出的提醒**行**数，两个级别都算；升级过的回合计两次。对 `near` 与 `head_down`，它与 `near_remind_count` / `head_down_remind_count` 相同；永不发声的体态为 `0`。
- `seconds`——该体态累计的越阈秒数，不含暂停。对 `near` 与 `head_down`，它与 `near_seconds` / `head_down_seconds` 一致，QA 校验器会交叉核对。

从未越阈的体态也会存在，三个值都是 `0`。两个实验级体态（`head_forward`、`slouch`）永不发出提醒，因此它们的 `episodes` 可能非零而 `reminders` 保持 `0`——这是预期读法，不是矛盾。

## 事件

| `event` | 含义 | 除始终设置的 `ts`、`state`、`screen` 外，它填写的非 `null` 键 |
|---|---|---|
| `session_started` | 一次会话开始。 | `scenario` |
| `config` | 本次会话生效的阈值。 | `sensitivity`、`distance_threshold_cm`、`pitch_threshold_deg` |
| `calibration_done` | 校准结束；基线已设定。旧阅读流程写过这一行；当前无写入路径（静默校准尚未实现），事件与键保留。 | `baseline_distance_cm`、`baseline_pitch_deg` |
| `screen_shown` | 一个界面出现。 | `screen` |
| `sample` | 一个相机 tick（脚本运行中为 10 Hz）。 | `t`、`distance_cm`、`pitch_deg` |
| `status_changed` | 显示的体态状态发生变化。 | `t`、`state`、`distance_cm`、`pitch_deg` |
| `features` | 特征采样行——每五个样本一行（10 Hz tick 下为 2 Hz）。足够重建一次判定，又不至于淹没日志。 | `t`、`highlighted_feature`、`feature_values` |
| `view_mode` | 层状态变化：形象/黑板模式或任一叠加开关改变。 | `view_mode`、`overlay_on`、`avatar_on` |
| `reminder` | 触发了一次提醒（一级轻提示或二级语音）。 | `t`、`alert_type`、`level`、`breach_seconds`、`distance_cm`、`pitch_deg` |
| `speech_timeout` | 音频看门狗触发：片段开始后未在“时长 + 2 秒”内报告结束，因此队列仍被推进。 | `alert_type`、`level`（没有 `t`——播放器没有会话时钟） |
| `speech_unavailable` | 该体态的占位片段无法加载或解码，因此提醒是静音的。不会重复播放，队列继续推进。 | `alert_type`（没有 `t`，没有 `level`） |
| `speech_played` | 某个片段报告它**开始**播放。写在播放器真正开始片段的地方，而不是排队的地方，因此该行绝不会为缺失或无法播放的资源声称有声音——那些会写 `speech_unavailable`。它证明播放器已加载并开始片段，不证明房间里有人听到了。 | `alert_type`、`level`（没有 `t`——播放器没有会话时钟） |
| `pomodoro_tick` | 番茄钟倒计时，阶段运行时**每个样本时钟秒**写一行，因此一次运行是一串递减的行，而不是只有一个开始和一个结束。每个样本一行（10 Hz）会淹没日志；这只用于番茄钟流程，暂停或停驻的阶段不写任何行。 | `remaining_seconds`、`phase`（没有 `t`——从每行都有的 `ts` 读取时刻） |
| `segment` | 一个专注内的非姿态时间轴段关闭：`detecting`（从孩子点击「开始」到该专注**第一个姿态样本**到达）或 `no_data`（v0.6.1：首样本之后样本流中断，直到下一个样本到达或专注结束）。这段墙钟时间不并入任何姿态段、也不丢弃，关闭时写**一行**且只写这一行，之后不再补写；长度为 0 的段不写行。只有 `detecting` 与 `no_data` 段产生这个事件；`good`、各体态、`no_person` 与 `paused` 段不写。 | `segment_kind`（`detecting` 或 `no_data`）、`segment_start`、`segment_end`、`segment_seconds`（两端都是墙钟毫秒，时刻以 `segment_start` / `segment_end` 为准） |
| `cue_played` | 番茄钟提示音报告它**开始**播放：专注或休息阶段自然结束时的结束提示音。写在片段真正开始的地方，因此无法加载或无法开始的提示音不写任何行，`EndSound.none` 也完全不写；设置页的试听同样不写，因为那不是计时器的声音。与 `speech_played` 一样，它证明播放器开始了片段，不证明房间里有人听到了。 | `message`（提示音名称）；没有 `t`——播放器没有会话时钟 |
| `calibration_incomplete` | 校准没有完成（v0.6.8 (16)）：开头 3 秒里有效横滚样本少于 10 个。判定沿用标准直立基线，这一行用 `message` 写原因，绝不把「没校准」写成「校准过了」。 | `message` |
| `thermal` | 发热降级开始或结束（v0.6.8）：`serious`/`critical` 时 Vision 降到 5 Hz、点云降到 15 Hz，恢复时再写一行结束。降级期间 `thermal_state` 会同时在每行盖上（采样见下文），但只有翻转的那一行带 `thermal_degraded`。 | `thermal_degraded` |
| `paused` | 无人暂停开始（连续 3 秒没有脸）。 | `t` |
| `resumed` | 无人暂停结束（人脸重新出现）。 | `t` |
| `session_ended` | 会话结束；携带汇总。 | `total_seconds`、`good_seconds`、`near_seconds`、`head_down_seconds`、`paused_seconds`、`near_count`、`near_remind_count`、`head_down_count`、`head_down_remind_count`、`longest_good_streak_seconds`、`posture_stats` |

单个 tick 内的顺序遵循引擎：`sample`，然后是 `paused`/`resumed`，然后是 `status_changed`（仅当状态改变），然后是任何 `reminder`，最后当该 tick 是特征样本（每第五个）时写 `features` 行。同一 tick 内多个体态触发 `reminder` 时，它们按 `PostureKind.priority` 升序出现，每个体态一行。

番茄钟流程中，每个样本保持相同顺序，且该样本的 `pomodoro_tick` 行最后出现：在该样本上结束的阶段，到写 tick 时已经推进，因此 tick 总是标明样本离开计时器时所在的阶段。

## 识别中段、无数据段与时间轴不变量

v0.6 起，一次专注的时间轴必须能被完整解释：开头是一段「识别中」，随后是姿态段（`good`、八种体态、`no_person`），样本流中断时插入 `no_data` 段；两种暂停各有一段自 0.6.3 起分开：孩子手动暂停写 `paused`（「暂停」），无人自动暂停写 `no_person`（「不在画面」）。段的 kind 常量是 `detecting`、`no_data`、`paused` 与 `no_person`（引擎、时间轴与图例共用这些标识），界面与图例的中文分别写「识别中」「无数据」「暂停」「不在画面」；与 `paused` 一样，前两者只是时间轴取值，**永远不是 `state` 取值**——`state` 仍然是最近一次判定（初始为 `good`）。

- **独立成段，不并入第一段，也不丢弃。** 孩子点「开始」时深度流刚启动、人脸往往还没被测量到；这段墙钟时间单独记成一个 `detecting` 段，从点击「开始」到该专注第一个姿态样本到达。它不会为了好看被合并进第一个 `good` 段，也不会被当作启动噪声丢掉。
- **不计入坏姿势统计。** 这段时间没有任何体态判定，所以不产生 `reminder`，也不增加任何 `posture_stats[kind]` 的 `episodes` / `reminders` / `seconds`，更不会把 `state` 推到某种体态。
- **不计入良好占比的分母。** 良好占比只在姿态段上计算：「识别中」的秒数既不计入 `good_seconds`，也不计入 `total_seconds`。把它算成良好，等于给一段没测量过的相机启动时间记功；算成坏姿势则更没依据。
- **与「不在画面」（`no_person`）是两件事。** `no_person` 是相机**量过**并回答“没有人”；`detecting` 是相机**还没回答**。两者在时间轴与图例上各有独立条目、各自颜色（见 `GLOSSARY.md` 的「识别中」与「不在画面」），日志里前者走 `state`，后者走 `segment_kind`。
- **时间轴不变量**：一个专注的 `detecting` 段、`no_data` 段与各姿态段（`good`、八种体态）的时长之和 = `plannedSeconds`（±1 秒）。`paused` 与 `no_person`（v0.6.3 的无人暂停）段都不在这个总和里：两者都是倒计时之外的墙钟时间，期间倒计时冻结，这段时长不占用计划时长，只单独累计在 `pausedSeconds` 与对应的时间轴段里（手动暂停 `paused`，无人暂停 `no_person`）。
- **只有 `detecting` 与 `no_data` 段写 `segment` 行。** 段关闭时写一行，携带 `segment_kind`、`segment_start`、`segment_end`、`segment_seconds`；`good`、各体态、`no_person` 与 `paused` 段不写这个事件（后三者由 `sample` / `status_changed` 行与 `state`、`paused` / `resumed` 行重建）。`segment_seconds` 应等于 `(segment_end − segment_start) / 1000`，可以据此交叉核对。若第一个姿态样本与点击「开始」落在同一瞬间，这段长度为 0、没有可画的等待，于是不作为独立段，也不写 `segment` 行——时间轴直接从该样本起算，不变量照旧成立。

### 样本中断与「无数据」段

姿态样本只证明到**最后一个样本到达的那一刻**。v0.6.1 之前，样本流中断后仍张开的那一段会一直沿用上一个 kind（常为 `good`），于是「统计页开着、深度流停下」的整段时间被记成良好坐姿，良好占比虚高。现在由 SessionController 的墙钟 ticker 判定：一个专注已经有样本，且距最后一个样本超过 **1 秒**（`FocusTimeline.sampleGapThreshold`；样本本身约 10 Hz，一整秒没有样本说明流停了，而不是掉帧），就在**最后一个样本的时刻**闭合当前段，并开一段 `no_data`；下一个样本到达时（或专注结束时）闭合它。

- **颜色与「识别中」相同。** 两者都在说“相机没有给出答案”，所以共用同一档最浅的冷灰；图例仍各占一行（「识别中」与「无数据」），以免把专注中途的停流误读成启动等待。
- **不计分。** `no_data` 既不加 `good_seconds`，也不加任何 `posture_stats[kind].seconds`，并且**不在良好占比的分母里**；它只作为时间轴段出现在历史与统计页上。
- **暂停不受影响。** 暂停期间样本流若也停了，段仍是 `paused`（暂停本来就在倒计时之外）；暂停语义与 v0.6 一致。
- **首样本之前不会产生 `no_data`。** 那段仍由 `detecting` 覆盖：`segment_start` 是点击「开始」的时刻，而不是最后一个样本（那时还没有样本）。
- **日志**：`no_data` 段闭合时写一行 `segment`，四个键的语义同前；键集仍是 42 个。

示例（只列出与事件相关的键，其余键按契约写 JSON `null`）：

```json
{"ts": 1793000004230, "event": "segment", "state": "good", "screen": "pomodoro_main",
 "segment_kind": "detecting", "segment_start": 1793000000000,
 "segment_end": 1793000004230, "segment_seconds": 4.23,
 "wall_clock": "2026-10-26T07:33:24Z", "t": null}
```

这一行表示：孩子在 `07:33:20` 点了「开始」（`segment_start`），`4.23` 秒后首个姿态样本到达并关闭「识别中」段；该专注此后从这一个样本起进入姿态段。

```json
{"ts": 1793000096000, "event": "segment", "state": "good", "screen": "pomodoro_main",
 "segment_kind": "no_data", "segment_start": 1793000042000,
 "segment_end": 1793000096000, "segment_seconds": 54.0,
 "wall_clock": "2026-10-26T07:34:56Z", "t": null}
```

这一行表示：最后一个姿态样本到达于 `07:34:02`，此后 54 秒没有任何样本（例如家长打开了统计页），`07:34:56` 的样本恢复并关闭「无数据」段；这 54 秒既不算良好，也不算任何体态。

## 词汇表

### `state`

`good`、`no_person`，加上八个体态 rawValue：`desk_lean`、`near`、`head_forward`、`slouch`、`head_down`、`head_tilt`、`shoulder_tilt`、`chin_rest`。

这十个值来自 `PostureStatus`（`good`、`no_person` 或 `posture(kind)`），其 rawValue 与 `PostureKind` 完全一致——只有一套体态词汇，不是两套。`no_person` 就是中文的「无人」：连续 3 秒没有可测量的人脸。中文文档与验收口径叫「无人」，面向家长的统计页/历史图例写作「不在画面」。

### `screen`

`pomodoro_main`、`pomodoro_settings`、`report_day`、`report_week`、`report_month`。番茄钟主页是应用唯一入口，所以一次运行的首行就是 `pomodoro_main`；统计页的三个范围是三个界面名，因此它们的截图不会互相覆盖。旧阅读流程的 `home`、`calibration`、`calibration_result`、`monitoring`、`summary`、`settings` 已随该流程退役（ADR-0006）。注意 `reminder` 与 `highlight` **不是** `screen` 值。

### `alert_type`

与 `state` 相同的八个体态 rawValue：`desk_lean`、`near`、`head_forward`、`slouch`、`head_down`、`head_tilt`、`shoulder_tilt`、`chin_rest`。

### `level`

`1` = 轻提示（番茄钟保留该行与计数，但不播放提示音），`2` = 语音（应用包内的预录 WAV 片段——没有系统 TTS）。

### `sensitivity`

`low` → 25 cm / 25°，`medium` → 30 cm / 20°，`high` → 35 cm / 15°。

### `thermal_state`

`nominal`、`fair`、`serious`、`critical`。`serious` 与 `critical` 触发发热降级（v0.6.8），降级的起止由 `thermal` 行标记；这个键本身仍按下面的采样节奏盖在每行上。

### `segment_kind`

`detecting`——「识别中」段：从点击「开始」到该专注第一个姿态样本之间那段墙钟时间（v0.6）。`no_data`——「无数据」段（v0.6.1）：该专注已有样本后，样本流中断超过 1 秒；段起点是中断前最后一个样本的时刻，终点是恢复样本或专注结束的时刻。`paused` 是时间轴取值，但不是 `segment_kind` 取值：暂停不写 `segment` 行，暂停时长从 `paused` / `resumed` 行与历史里的 `pausedSeconds` 读取。

## Swift 与日志名称映射

代码保留自己的标识符；映射只发生在日志边界。本表是两套词汇的唯一事实来源。

| Swift（代码） | 日志（JSONL） |
|---|---|
| `PostureStatus.good` | `good` |
| `PostureStatus.noPerson` | `no_person` |
| `PostureStatus.posture(kind)` | `kind.rawValue`（八种体态之一） |
| `PostureKind.near` / `.headDown` / `.shoulderTilt` / … | `near` / `head_down` / `shoulder_tilt` / …（全部八个 rawValue） |
| `PostureFeature.distance` / `.handToFace` / `.shoulderTilt` / … | `distance` / `hand_to_face` / `shoulder_tilt` / …（全部八个 rawValue） |
| `ReminderLevel.gentle` / `.voice` | `level` `1` / `2` |
| `MonitoringEvent.sessionStarted(...)` | `session_started` |
| `MonitoringEvent.config(...)` | `config` |
| `MonitoringEvent.calibrated(...)` | `calibration_done` |
| `MonitoringEvent.screenShown(...)` | `screen_shown` |
| `MonitoringEvent.sample(...)` | `sample` |
| `MonitoringEvent.statusChanged(...)` | `status_changed` |
| `MonitoringEvent.reminder(...)` | `reminder` |
| `MonitoringEvent.features(...)` | `features` |
| `MonitoringEvent.viewMode(...)` | `view_mode` |
| `MonitoringEvent.pomodoroTick(...)` | `pomodoro_tick` |
| `MonitoringEvent.segment(...)` | `segment`（`segment_kind` = `detecting`） |
| `MonitoringEvent.speechTimeout(...)` | `speech_timeout` |
| `MonitoringEvent.speechUnavailable(...)` | `speech_unavailable` |
| `MonitoringEvent.speechPlayed(...)` | `speech_played` |
| `MonitoringEvent.cuePlayed(...)` | `cue_played`（`message`） |
| `MonitoringEvent.paused(...)` | `paused` |
| `MonitoringEvent.resumed(...)` | `resumed` |
| `MonitoringEvent.sessionEnded(...)` | `session_ended` |
| `PomodoroPhase.focus` / `.shortBreak` / `.longBreak` | `phase` = `focus` / `shortBreak` / `longBreak`（rawValue 保留 camelCase 拼写） |
| `PomodoroCue.endSoft` / `.endChime` | `cue_played.message` = `end_soft` / `end_chime` |
| `SessionSummary.tooCloseSeconds` | `near_seconds` |
| `SessionSummary.tooCloseCount` | `near_count` |
| `SessionSummary.tooCloseRemindCount` | `near_remind_count` |
| `SessionSummary.headDownCount` | `head_down_count` |
| `SessionSummary.headDownRemindCount` | `head_down_remind_count` |
| `SessionSummary.postureStats` | `posture_stats`（以 `PostureKind.rawValue` 为键） |

`PomodoroRecord` 与 `PomodoroOutcome` 是**历史词汇，不是日志键**。JSONL 日志没有 `outcome` 字段：`completed`、`abandoned` 与 `interrupted` 存放在 `Documents/pomodoro-history.json`，统计页从 outcome 为 `completed` 的记录计算 `completedPomodoros`。同样，`PostureSegment.kind` 使用 `state` 词汇，并额外允许 `paused`（暂停带）、`detecting`（识别中带）与 `no_data`（无数据带，v0.6.1）；这三个都是时间轴取值，永远不是 `state` 取值。`EndSound` 是设置项（`soft` / `chime` / `none`），不是键；它决定提示音片段是否开始，从而决定是否存在 `cue_played` 行。

## 中文术语 ↔ UI 文案 ↔ 日志事件映射

中文文档/验收口径、界面文案与日志/历史里的英文键不是一一同名，读日志时按这张表换算；英文事件名与键名沿用既定拼写：

| 中文术语（文档/验收） | UI 文案 | 日志与历史证据 | 不要误读成 |
|---|---|---|---|
| 离开 | 专注控制行按钮「离开」 | 无同名 JSONL 事件；关闭专注时写一条 `session_ended` 汇总，该番茄在 `Documents/pomodoro-history.json` 记 `"outcome": "abandoned"` | 不是 `paused` / `resumed`，也没有 `abandon` 这个 JSONL 事件名 |
| 无人 | 统计页/历史图例写「不在画面」 | `status_changed` 行 `state: "no_person"`；连续 3 秒无人写 `paused`，人脸回来写 `resumed` | 不是「离开」按钮，也不是 `abandoned` |
| 识别中（v0.6） | 统计页时间轴与图例写「识别中」 | 关闭时一行 `segment`：`segment_kind: "detecting"` + `segment_start` / `segment_end` / `segment_seconds`；此前没有任何姿态样本，所以没有 `sample` 行可依 | 不是 `no_person`（相机还没回答），不是 `paused`（不在倒计时之外），也不是「离开」 |
| 无数据（v0.6.1） | 统计页时间轴与图例写「无数据」，颜色同「识别中」 | 关闭时一行 `segment`：`segment_kind: "no_data"` + `segment_start`（最后一个样本的时刻）/ `segment_end` / `segment_seconds`；它之前有姿态样本，之后由恢复样本或 `session_ended` 闭合 | 不是 `no_person`（那是有样本且判定无人），不是 `paused`（暂停是主动状态、在倒计时之外），也不是「识别中」（那是首样本之前） |
| 超时中断（无人超过 300 秒） | 专注结束，停在停驻状态 | 结束时那条 `session_ended`；历史 `"outcome": "interrupted"` | 历史里不会出现 `abandoned` |
| 手动暂停 | 按钮「暂停」；暂停后按钮回到「开始专注」 | 没有 `paused` / `resumed` 行——这两个事件只表示无人；暂停时长进入历史的 `pausedSeconds` 与灰色 `paused` 时间轴段 | 不是 `no_person`，也不是 `abandoned` |

一句话：**按钮「离开」只落到历史的 `abandoned`；absence 只落到 `paused` / `resumed` 与 `state: "no_person"`；「识别中」与「无数据」只落到 `segment` 行的 `segment_kind: "detecting"` / `"no_data"`。** 这些英文键都不叫对方的名字。

## 每种体态独立计时、记录与计数

v0.3 为**每种 `PostureKind` 运行一个回合状态机**，因此八种体态各自维护越阈时钟、一级/二级升级与计数器。阅读日志时的影响：

- **一个 tick 可以携带多条 `reminder` 行。** 每个越阈且可发声的体态都发出自己的 `reminder`；多个体态同时越阈时，同一 tick 会有多条，按 `PostureKind.priority` 升序。不会为了给另一个体态腾位置而抑制任何一条。
- **优先级只给语音队列排序，不挑选单一体态。** `PostureKind.priority`（deskLean 1、near 2、headForward 3、slouch 4、headDown 5、headTilt 6、shoulderTilt 7、chinRest 8）给*语音*队列排序，让播放器一次说一条；它绝不会让越阈体态不计时、不记录或不计数。`state` 仍只报告优先级最高的单个越阈体态（`dominant`），因此 `state` 比 `reminder` 行更粗。
- **实验级体态（头前伸、驼背）永不发声。** 在默认设置（`experimentalPostures` 关闭）下，它们**完全不产生 `reminder`**——连提示音也没有——但仍会驱动 `state`、写 `features` 行并在内部计数回合。旧的实验开关打开时，它们会进入提醒流但**最高只有一级**：最多一次轻提示，绝不会有二级语音，因为它们的 `PostureKind.voiceLine` 为 `nil`。Q4 已确认实验级体态永不触发任何提醒；上述旧开关行为只描述当前代码，待后续 ticket 对齐。
- **`speech_unavailable` / `speech_timeout` 遵循同样的 `alert_type` 规则**，并且只为被允许发声的体态发出。

## 计数约定：回合与提醒行

引擎跟踪的每种体态都有**两个**计数器，计数方式不同。全部八种都通过 `posture_stats` 进入 `session_ended`；扁平的 `near_*` 与 `head_down_*` 键是旧的一对，为 QA 校验器镜像其中两个条目，而不是唯一被计数的体态：

- `*_count` 键（`near_count`、`head_down_count`）计数**达到一级的回合**——每个回合一次，无论升到多高。它与 `posture_stats[kind].episodes` 相同。
- `*_remind_count` 键（`near_remind_count`、`head_down_remind_count`）计数**提醒行**，两个级别都算。它与 `posture_stats[kind].reminders` 相同。

因此，一个升级到二级的回合给回合计数器加 **1**，给提醒计数器加 **2**。具体来说，一次运行中若单个“太近”回合先发一级再发二级，“低头”回合只发一级，最终为：

```
near_count = 1              near_remind_count = 2
head_down_count = 1         head_down_remind_count = 1
```

`MonitoringEngine` 在对应提醒发出时递增每个计数器，与回合的首次（一级）提醒同时发生。`near_count` 是“太近”回合计数器的旧名称；不存在 `head_down_episode_count`。

## 统计语义（`session_ended`，以及 `verify-session.py` 重算什么）

`scripts/verify-session.py` 上的校验器只从 `sample` 行重算汇总——不信任应用给出的任何数字——并严格使用以下规则；因此满足这些规则的日志，其汇总就是可推导的：

- **`dt` 记在区间起点的样本上。** 对两个连续样本 `t0 < t1`，区间 `dt = t1 − t0` 归属于 `t0` 样本的类别，而不是 `t1` 样本的类别。结果：状态变化反映在从切换点*开始*的区间上；从最后样本到会话结束的末尾空档由引擎的 `finish` 记入，但只看样本的重算看不到它——因此校验器对总计有 ±1 秒容差。
- **人脸缺失期间不累计时间。** 当 `t0` 样本的 `distance` 或 `pitch` 为 `null` 时，该区间只记入 `paused_seconds`，不记入其他任何项：不计 `total_seconds`、不计越阈秒数，良好连续段既不增长也不重置。
- **`total_seconds` 是有人脸在座的时间**：它只在起点样本检测到人脸的区间上累加 `dt`。
- **「识别中」与「无数据」段不进入这些汇总。** 前者发生在第一个姿态样本之前，本来就没有 `sample` 行；后者发生在样本流中断期间，同样没有样本可依。两者都不计入 `total_seconds` 与 `good_seconds`，因此良好占比的分母里没有它们；`no_data` 尤其不能记到中断前的最后一个姿态上。它们的时长只从 `segment` 行读取（见「识别中段、无数据段与时间轴不变量」）。
- **`good_seconds` 排除所有体态，而不只是前两种。** 只有当起点样本有人脸且**没有任何体态越阈**时才累加 `dt`——与 `state = good` 的条件相同。v0.3 之前它只统计“太近”和“低头”，因此一次一直托腮的会话会把自己报告成完全良好；如果你在阅读更旧的日志，这个数字可能与 `status_changed` 时间轴不一致。
- **两个越阈计数器相互独立，可能重叠。** 只要各自的谓词成立，`near_seconds` 与 `head_down_seconds` 就各自累加 `dt`，因此同时“太近”且“低头”的样本会把同一段 `dt` 计入**两者**。所以 `near_seconds + head_down_seconds + good_seconds` 超过 `total_seconds` 是正常的。谓词是严格的：“太近”为 `distance_cm < distance_threshold_cm`（相等不算越阈），“低头”为 `baseline_pitch_deg − pitch_deg > pitch_threshold_deg`。其余六种体态也有秒数计数器，但只在 `posture_stats[kind].seconds` 中；它们没有扁平的 `*_seconds` 键。
- **`longest_good_streak_seconds`** 是最长连续良好区间；**任何**体态越阈都会把当前连续段重置为 0，无人既不会延长也不会重置它。
- **阈值来自日志，而不是常量**：校验器从 `config` 行读取 `distance_threshold_cm` 与 `pitch_threshold_deg`，从 `calibration_done` 行读取 `baseline_pitch_deg`。

## 电量与热状态是趋势线，不是逐样本读数

`battery_level` 与 `thermal_state` 背后没有逐样本事件：`FileDebugLogger` 从设备本身采样，并在每行盖上最近的值。会话日志里采样**最多每 10 秒刷新一次**，因此连续多行共享同一个值，二者形成粗略趋势。v0.6.8 起另有每秒一条的 `Documents/debug/perf-*.jsonl`（DEBUG 构建、独立键名）带 `thermal_state`、`battery_level` 与 `degraded`，判「降级时段」与电量曲线用它，不用会话日志的 10 秒采样；逐帧原始事实（点数、点云间隔、上屏时间）另见 `cloud-*.jsonl`，汇总里的 `cloud_points_min` / `cloud_points_max` 只是趋势，不要拿末值当结论。阅读时比较一次会话的首行与末行；不要把相邻两行的变化当成逐样本读数。设备不报告电量时（例如模拟器），`battery_level` 为 `null`；`thermal_state` 是 `nominal`、`fair`、`serious`、`critical` 之一。

## 截图

v0.5 起应用不写任何图像文件：`FileDebugLogger.screenshot(_:)` 只把最近一帧渲染到内存，从不落盘（ADR-0005 的隐私边界）。因此：

- 容器里只有 `session-*.jsonl`、`pomodoro-history.json` 与偏好文件；`scripts/verify-session.py` 的 P2 与 `scripts/audit-sandbox.py` 都会把任何 PNG/JPG/MP4 判为失败。
- 验收留档截图由 `scripts/capture-screens.sh`、`scripts/run-acceptance.sh` 与 `.omp/skills/verify-posture-lab/scripts/verify.py` 用 `xcrun simctl io screenshot` 从设备侧拍摄，保存在证据目录，不属于 App 容器。
- 旧阅读流程的 `home`/`calibration`/`monitoring`/`summary`/`settings` 截图名称已随该流程退役（ADR-0006）；`reminder`、`highlight` 同理。

## 哪个键回答哪条验收标准

番茄钟轮次编号自己的验收清单。日志侧的几条：

| 验收 | 日志中的证据 |
|---|---|
| 倒计时 | `pomodoro_tick` 序列：`remaining_seconds` 与相邻行之间的 `ts` 间隔同步下降，`phase` 只在阶段切换处改变，序列中没有断档。 |
| 时间轴完整（v0.6 / v0.6.1） | 每个专注开头至多有一行 `segment`（首样本即时到达时没有这一行）：`segment_kind: "detecting"`，`segment_start` 是点击「开始」的墙钟毫秒，`segment_end` 是首个姿态样本到达的墙钟毫秒，`segment_seconds` 与 `(segment_end − segment_start) / 1000` 一致。之后每段样本中断都有一行 `segment_kind: "no_data"`，起点是中断前最后一个样本的时刻，终点是恢复样本或专注结束。`detecting` + `no_data` + 各姿态段的时长之和 = `plannedSeconds`（±1 秒），`paused` 段不计入该总和。 |
| 阶段流转 | `pomodoro_tick` 的 `phase` 从 `focus` 走到 `shortBreak` / `longBreak`，再回到 `focus`；每完成一个专注有一条 `session_ended`。 |
| 音频 | `speech_played` 行（`alert_type` + `level`）；语音开关关闭时完全没有这类行。阶段结束提示音只写 `cue_played`（`end_soft` / `end_chime`），静音时没有。 |
| 暂停 | `paused` / `resumed` 行；暂停期间倒计时冻结，暂停时长进入历史的 `pausedSeconds` 与灰色 `paused` 时间轴带。 |
| 体态提醒 | `reminder` 行带 `t`、`alert_type`、`level`（1 与 2）与 `breach_seconds`；实验级体态永不发声。 |
| 发热降级（v0.6.8） | `thermal` 行：`thermal_degraded: true` 与 `false` 配对切出降级时段；`serious` 期间同一时段在 `Documents/debug/perf-*.jsonl` 的 `degraded` 为 `true`。降级不改判定口径，只降采集频率。 |
| 隐私 | 没有任何网络键或远端地址；`Documents/` 下没有任何图像文件，只有 JSONL 与番茄钟历史（截图只在内存，ADR-0005）。 |
