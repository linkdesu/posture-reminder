# Glossary

The domain vocabulary of PostureLab. Use these terms in issues, code, and tests; the
English form in parentheses is the identifier form used in the codebase.

## Core concepts

- **姿态样本 (posture sample, `PostureSample`)** — one camera tick: a session-relative
  time `t` (seconds since session start), a distance to the book in centimetres
  `distanceCM`, and a head pitch angle `pitchDeg`. A `nil` distance or pitch means the
  face was not detected on that tick. Lives in
  `PostureLab/Domain/PostureSample.swift`; produced by any `SampleSource`.

- **距离阈值 (distance threshold)** — the centimetre value below which a sample is a
  "too close" violation; derived from the current sensitivity setting
  (`Sensitivity.distanceThresholdCM`). Lives in `PostureLab/Domain/Sensitivity.swift`.

- **俯仰角基线 (pitch baseline)** — the head pitch angle recorded at calibration,
  against which "head down" is measured: a sample is a head-down violation when its
  pitch is more than the pitch threshold lower than the baseline. Recorded by
  `SessionController` during calibration; fed to `MonitoringEngine` at init.

- **一级提醒 (level 1 / gentle reminder, `ReminderLevel.gentle`) — a short sound plus an
  orange screen edge; no speech.** Triggered after the violation has lasted 5 seconds
  (`gentleDelay`). The orange edge is drawn in `MonitoringView`; the sound in
  `ReminderPlayer`.

- **二级提醒 (level 2 / voice reminder, `ReminderLevel.voice`)** — spoken Chinese
  (「离书太近啦，坐直一点哦」/ 「头抬起来一点哦」) played through
  `AVSpeechSynthesisVoice` (zh-CN). Triggered after the violation has lasted 15 seconds
  (`voiceDelay`). Only one speech plays at a time; `near` queues ahead of `head_down`.

- **冷却 (cooldown)** — 30 seconds (`cooldown`) between two reminders of the same kind:
  a second breach of the same kind within the cooldown is not reminded. Lives in
  `MonitoringEngine.Config`; the kind's last-reminder time is tracked per reminder kind.

- **灵敏度 (sensitivity, `Sensitivity`)** — three levels mapping to paired thresholds:
  low → 25 cm / 25°, medium (default) → 30 cm / 20°, high → 35 cm / 15°. Higher
  sensitivity means a closer / steeper threshold, i.e. earlier reminders. Lives in
  `PostureLab/Domain/Sensitivity.swift`.

- **无人暂停 (absence pause)** — no face detected for 3 seconds (`absencePauseDelay`)
  enters pause: no reading time is counted, no violation, no reminders. If cumulative
  paused time exceeds 5 minutes, the session ends on its own
  (`pausedSeconds > 300` in `SessionController`) and a summary is produced.

- **良好占比 (good ratio, `SessionSummary.goodRatio`)** — good seconds divided by total
  reading seconds; a computed property, not persisted. 0 when there was no reading
  time.

- **校准 (calibration)** — a 3-second countdown, then ~3 seconds of samples; the baseline
  distance and baseline pitch are the **median** of the non-empty samples (an even count
  averages the middle pair). No non-empty sample at all → calibration fails. Calibrates
  in `SessionController`; the resulting event is `MonitoringEvent.calibrated`.

## Log-vocabulary mapping

The JSONL log is a contract with QA; the log uses snake_case vocabulary that differs
from the Swift identifiers. The mapping happens at the log boundary only — the code
keeps its own names. QA reads the log, so use the **log** spelling when talking about
log lines.

| Swift (code) | Log (JSONL) |
|---|---|
| `PostureStatus.good` | `good` |
| `PostureStatus.tooClose` | `near` |
| `PostureStatus.headDown` | `head_down` |
| `PostureStatus.absent` | `no_person` |
| `ReminderKind.tooClose` | `near` |
| `ReminderKind.headDown` | `head_down` |
| `MonitoringEvent.calibrated(...)` | `calibration_done` |
| `SessionSummary.tooCloseSeconds` | `near_seconds` |
| `SessionSummary.tooCloseCount` | `near_count` |
| `SessionSummary.tooCloseRemindCount` | `near_remind_count` |
| `SessionSummary.headDownCount` | `head_down_count` |
| `SessionSummary.headDownRemindCount` | `head_down_remind_count` |

Every log line carries the full key set (30 keys); `ts` (epoch milliseconds) and `t`
(seconds since session start) are different quantities and neither is renamed — see
`docs/qa-log-schema.md`. Two of those keys — `battery_level` (0...1) and
`thermal_state` (`nominal` / `fair` / `serious` / `critical`) — have no Swift event
behind them: the `FileDebugLogger` samples them from the device and stamps every line.
See ADR-0002.
