# QA 日志结构——如何阅读 PostureLab 会话日志

这是番茄钟会话日志的参考。它描述 `FileDebugLogger` 写出、`scripts/verify-session.py` 与 `scripts/verify-acceptance.py` 读取的日志格式。它是日志参考，不是 PRD 的复述；日志为何是契约见 `docs/adr/0002-jsonl-log-contract-with-qa.md`，领域词汇见 `GLOSSARY.md`。日志结构是与 QA 的契约：新增、重命名或删除键对脚本的破坏程度与行为变更相同，落地前必须与 QA 协调。

## `ts` 与 `t` 不是一回事

请仔细读一遍，因为这是最容易弄错的一点：

- **`ts` 是 Unix 纪元毫秒**——绝对墙上时钟时刻，即自 1970-01-01T00:00:00Z 起的毫秒数。它在**每一行**都填写。
- **`t` 是会话开始后的秒数**——相对偏移，会话开始时为 `0`，只有携带会话时间的事件才填写。

它们是两个不同的量，单位也不同。**二者不可互换，也都不会被重命名。** 不要把两者都叫作“时间戳”：`ts` 是墙上时钟时间戳，`t` 是会话相对时间。如果你把 `ts` 与 `t` 相比，你是在拿“1970 年起的毫秒”与“会话开始后的秒”作比较，算术没有意义。

## 文件位置

位于应用沙盒的 `Documents/` 下：

- `Documents/debug/session-<ISO8601>.jsonl`——每次启动一个 JSONL 文件。文件名是启动时间的 ISO8601 表示并去掉冒号，例如 `2026-10-17T01:23:45Z` 启动会产出 `session-2026-10-17T012345Z.jsonl`。每次新运行写一个新文件；`run-scenarios.sh` 选取最新的那个。
- `Documents/debug/screenshots/<name>.png`——运行展示过的每个界面一张 PNG，另加提醒/高亮证据截图；名称见下文“截图”一节。

日志器只在调试模式开启时工作（`FileDebugLogger.isEnabled`）；关闭时不写任何文件。

### 从设备取出文件

`devicectl` 可以复制整个应用数据容器（或其中某个子目录）：

```sh
xcrun devicectl device copy from \
  --device <device-id> \
  --domain-type appDataContainer \
  --domain-identifier me.xieal.posturelab \
  --source Documents \
  --destination <local-round-directory>
```

这会把 `Documents/`——包括 `debug/session-*.jsonl` 与 `debug/screenshots/`——取到本轮目录。模拟器中的等价命令是 `xcrun simctl get_app_container <sim-id> me.xieal.posturelab data`。`scripts/run-scenarios.sh` 两者都会做，然后把最新的 `session-*.jsonl` 交给 `scripts/verify-session.py`。

## 行格式与完整键集

每行一个 JSON 对象，UTF-8，以换行结尾。**每行携带全部 38 个键。** 写入器在每行编码完整键集，不适用值写成 JSON `null`，因此读者**永远不必检查键是否存在**——对某个事件没有意义的键以 JSON `null` 存在，而不是缺失。每行唯一的变化是哪些键非 `null`。

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

### `feature_values` 的嵌套结构

`feature_values` 是逐 tick 的对象键；`posture_stats`（下一节）是汇总的对象键，其他键的值都是标量。它的键是八个 `PostureFeature` rawValue（`distance`、`head_pitch`、`head_roll`、`shoulder_tilt`、`head_height_drop`、`hand_to_face`、`head_forward`、`slouch`）；每个映射到一个固定三元组：

```json
"feature_values": {
  "distance": { "value": 24.3, "threshold": 30.0, "over": true }
}
```

- `value`——本样本对该特征的读数，使用特征自己的单位（厘米、度、米或归一化比例；见 `GLOSSARY.md` 中的 `PostureFeature`）。
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
| `cue_played` | 番茄钟提示音报告它**开始**播放：专注或休息阶段自然结束时的结束提示音。写在片段真正开始的地方，因此无法加载或无法开始的提示音不写任何行，`EndSound.none` 也完全不写；设置页的试听同样不写，因为那不是计时器的声音。与 `speech_played` 一样，它证明播放器开始了片段，不证明房间里有人听到了。 | `message`（提示音名称）；没有 `t`——播放器没有会话时钟 |
| `paused` | 无人暂停开始（连续 3 秒没有脸）。 | `t` |
| `resumed` | 无人暂停结束（人脸重新出现）。 | `t` |
| `session_ended` | 会话结束；携带汇总。 | `total_seconds`、`good_seconds`、`near_seconds`、`head_down_seconds`、`paused_seconds`、`near_count`、`near_remind_count`、`head_down_count`、`head_down_remind_count`、`longest_good_streak_seconds`、`posture_stats` |

单个 tick 内的顺序遵循引擎：`sample`，然后是 `paused`/`resumed`，然后是 `status_changed`（仅当状态改变），然后是任何 `reminder`，最后当该 tick 是特征样本（每第五个）时写 `features` 行。同一 tick 内多个体态触发 `reminder` 时，它们按 `PostureKind.priority` 升序出现，每个体态一行。

番茄钟流程中，每个样本保持相同顺序，且该样本的 `pomodoro_tick` 行最后出现：在该样本上结束的阶段，到写 tick 时已经推进，因此 tick 总是标明样本离开计时器时所在的阶段。

## 词汇表

### `state`

`good`、`no_person`，加上八个体态 rawValue：`desk_lean`、`near`、`head_forward`、`slouch`、`head_down`、`head_tilt`、`shoulder_tilt`、`chin_rest`。

这十个值来自 `PostureStatus`（`good`、`no_person` 或 `posture(kind)`），其 rawValue 与 `PostureKind` 完全一致——只有一套体态词汇，不是两套。

### `screen`

`pomodoro_main`、`pomodoro_settings`、`report_day`、`report_week`、`report_month`。番茄钟主页是应用唯一入口，所以一次运行的首行就是 `pomodoro_main`；统计页的三个范围是三个界面名，因此它们的截图不会互相覆盖。旧阅读流程的 `home`、`calibration`、`calibration_result`、`monitoring`、`summary`、`settings` 已随该流程退役（ADR-0006）。注意 `reminder` 与 `highlight` **不是** `screen` 值。

### `alert_type`

与 `state` 相同的八个体态 rawValue：`desk_lean`、`near`、`head_forward`、`slouch`、`head_down`、`head_tilt`、`shoulder_tilt`、`chin_rest`。

### `level`

`1` = 轻提示（番茄钟保留该行与计数，但不播放提示音），`2` = 语音（应用包内的预录 WAV 片段——没有系统 TTS）。

### `sensitivity`

`low` → 25 cm / 25°，`medium` → 30 cm / 20°，`high` → 35 cm / 15°。

### `thermal_state`

`nominal`、`fair`、`serious`、`critical`。

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

`PomodoroRecord` 与 `PomodoroOutcome` 是**历史词汇，不是日志键**。JSONL 日志没有 `outcome` 字段：`completed`、`abandoned` 与 `interrupted` 存放在 `Documents/pomodoro-history.json`，统计页从 outcome 为 `completed` 的记录计算 `completedPomodoros`。同样，`PostureSegment.kind` 使用 `state` 词汇，并额外允许 `paused` 表示暂停带；`paused` 是时间轴取值，永远不是 `state` 取值。`EndSound` 是设置项（`soft` / `chime` / `none`），不是键；它决定提示音片段是否开始，从而决定是否存在 `cue_played` 行。

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
- **`good_seconds` 排除所有体态，而不只是前两种。** 只有当起点样本有人脸且**没有任何体态越阈**时才累加 `dt`——与 `state = good` 的条件相同。v0.3 之前它只统计“太近”和“低头”，因此一次一直托腮的会话会把自己报告成完全良好；如果你在阅读更旧的日志，这个数字可能与 `status_changed` 时间轴不一致。
- **两个越阈计数器相互独立，可能重叠。** 只要各自的谓词成立，`near_seconds` 与 `head_down_seconds` 就各自累加 `dt`，因此同时“太近”且“低头”的样本会把同一段 `dt` 计入**两者**。所以 `near_seconds + head_down_seconds + good_seconds` 超过 `total_seconds` 是正常的。谓词是严格的：“太近”为 `distance_cm < distance_threshold_cm`（相等不算越阈），“低头”为 `baseline_pitch_deg − pitch_deg > pitch_threshold_deg`。其余六种体态也有秒数计数器，但只在 `posture_stats[kind].seconds` 中；它们没有扁平的 `*_seconds` 键。
- **`longest_good_streak_seconds`** 是最长连续良好区间；**任何**体态越阈都会把当前连续段重置为 0，无人既不会延长也不会重置它。
- **阈值来自日志，而不是常量**：校验器从 `config` 行读取 `distance_threshold_cm` 与 `pitch_threshold_deg`，从 `calibration_done` 行读取 `baseline_pitch_deg`。

## 电量与热状态是趋势线，不是逐样本读数

`battery_level` 与 `thermal_state` 背后没有事件：`FileDebugLogger` 从设备本身采样，并在每行盖上最近的值。采样**最多每 10 秒刷新一次**，因此连续多行共享同一个值，二者形成粗略趋势。阅读时比较一次会话的首行与末行；不要把相邻两行的变化当成逐样本读数。设备不报告电量时（例如模拟器），`battery_level` 为 `null`；`thermal_state` 是 `nominal`、`fair`、`serious`、`critical` 之一。

## 截图

`Documents/debug/screenshots/` 为运行到达过的每个 `screen_shown` 名称保存一张 PNG：

- `pomodoro_main`（应用启动页）、`pomodoro_settings`，以及 `report_day` / `report_week` / `report_month`（每个统计范围一个名称）。

只有到达过对应界面，名称才存在；设置页通过 `-settings 1` 到达，统计页通过 `-report day|week|month` 到达。`reminder` 与 `highlight` 曾是旧阅读流程直接捕获的证据截图，已随该流程退役。

## 哪个键回答哪条验收标准

番茄钟轮次编号自己的验收清单。日志侧的几条：

| 验收 | 日志中的证据 |
|---|---|
| 倒计时 | `pomodoro_tick` 序列：`remaining_seconds` 与相邻行之间的 `ts` 间隔同步下降，`phase` 只在阶段切换处改变，序列中没有断档。 |
| 阶段流转 | `pomodoro_tick` 的 `phase` 从 `focus` 走到 `shortBreak` / `longBreak`，再回到 `focus`；每完成一个专注有一条 `session_ended`。 |
| 音频 | `speech_played` 行（`alert_type` + `level`）；语音开关关闭时完全没有这类行。阶段结束提示音只写 `cue_played`（`end_soft` / `end_chime`），静音时没有。 |
| 暂停 | `paused` / `resumed` 行；暂停期间倒计时冻结，暂停时长进入历史的 `pausedSeconds` 与灰色 `paused` 时间轴带。 |
| 体态提醒 | `reminder` 行带 `t`、`alert_type`、`level`（1 与 2）与 `breach_seconds`；实验级体态永不发声。 |
| 隐私 | 没有任何网络键或远端地址；`Documents/` 下没有 RGB 图像，只有 JSONL、截图与番茄钟历史。 |
