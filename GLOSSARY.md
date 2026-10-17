# Glossary

The domain vocabulary of PostureLab. Use these terms in issues, code, and tests; the
English form in parentheses is the identifier form used in the codebase.

## Core concepts

- **姿态样本 (posture sample, `PostureSample`)** — one camera tick: a session-relative
  time `t` (seconds since session start), a distance to the book in centimetres
  `distanceCM`, and a head pitch angle `pitchDeg`. A `nil` distance or pitch means the
  face was not detected on that tick. v0.3 adds optional fields — `rollDeg`, the joint
  map `joints`, a coarse `depth` frame and `depthAvailable` — all defaulted so older call
  sites keep compiling; `facePresent` is "distance and pitch present", `bodyPresent` is
  "the joint map is not empty". Lives in
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

- **二级提醒 (level 2 / voice reminder, `ReminderLevel.voice`)** — spoken Chinese (e.g.
  「离书太近啦，坐直一点哦」/「头抬起来一点哦」) played through
  `AVSpeechSynthesisVoice` (zh-CN). Triggered after the violation has lasted 15 seconds
  (`voiceDelay`). Every breaching, speakable `PostureKind` runs its own episode machine,
  so several kinds may be `reminder`-worthy at once; `ReminderPlayer` speaks one line at
  a time, taking the queue in `PostureKind.priority` order (experimental kinds have no
  voice line and never enter the queue).

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

## Postures and features

- **体态 (posture, `PostureKind`)** — one of the seven postures the app watches for. Its
  `rawValue` is the only posture vocabulary and is what the log writes into `state` and
  `alert_type`: `desk_lean` (趴桌), `near` (太近), `head_forward` (头前伸), `slouch`
  (驼背), `head_down` (低头), `head_tilt` (歪头), `chin_rest` (托腮). Each kind carries a
  `PostureTier`, a `priority` (1 deskLean … 7 chinRest; lower wins), a `displayName`, an
  optional `voiceLine` and `isEnabledByDefault`. The displayed status is `PostureStatus`
  — `.good`, `.noPerson`, or `.posture(kind)` — whose `rawValue` is `good` / `no_person`
  / the kind's rawValue, so the `state` key is one of those nine values. Lives in
  `PostureLab/Domain/PostureKind.swift` and `PostureSample.swift`.

- **体态分级 (posture tier, `PostureTier`)** — how far a posture is trusted; decides
  whether it may speak and whether it is on by default. Three tiers: `stable` = `near`,
  `headDown`, `headTilt`; `medium` = `deskLean`, `chinRest`; `experimental` =
  `headForward`, `slouch`. Only `experimental` is off by default
  (`isEnabledByDefault == false`) and never speaks (`voiceLine == nil`).

- **特征 (feature, `PostureFeature`)** — one measurable quantity the verdict is built
  from; the debug overlay shows one row per feature. Eight of them, each with a
  `rawValue` used as the `feature_values` key and an `isSmallerWorse` direction:
  `distance` (cm), `head_pitch` and `head_roll` (degrees from baseline),
  `shoulder_tilt` (degrees off the baseline shoulder line), `head_height_drop`
  (normalized), `hand_to_face` (normalized wrist-to-nose), `head_forward` (metres nearer
  than baseline) and `slouch` (proxy ratio). Lives in
  `PostureLab/Domain/PostureFeature.swift`.

- **特征读数 (feature reading, `FeatureReading`)** — one feature's result for one sample:
  the `value`, the `threshold` it was judged against, the `baseline`, whether it is
  `isOverThreshold`, and a `severity` in `0...1` for the overlay's red/amber/green. A
  feature whose inputs are missing is built by hand with `severity` 0 and never reads as
  an alarm. Written to the log as the `feature_values` triple `value`/`threshold`/`over`.

- **主导体态 (dominant)** — the highest-`priority` breaching posture in an assessment
  (`PostureAssessment.dominant`); `nil` when nothing breached. The engine reports it as
  `PostureStatus.posture(dominant)`, so `state` names the single dominant posture even
  when several breach at once.

- **高亮特征 (highlighted feature, `highlighted_feature`)** — the one feature the debug
  overlay marks red right now: among the dominant posture's breaching features, the one
  with the greatest `severity`; `nil` when there is no dominant posture. On a `features`
  log line.

- **形象模式 (avatar mode, `avatarEnabled`)** — the setting that switches `MonitoringView`
  between the point-cloud `AvatarView` and the black-board readout. On by default;
  persisted. Changing it (or the debug overlay) writes a `view_mode` log line.

- **实验性体态开关 (experimental postures, `experimentalPostures`)** — the setting that
  lets the experimental tier emit a level-1 tone. Off by default. Off, `headForward` and
  `slouch` produce **no `reminder` at all** while still moving `state`, logging `features`
  and counting episodes; on, they may fire a level-1 tone but never speech, because their
  `voiceLine` is `nil`. Reaches the engine as `Config.speaksExperimentalPostures`.
  Persisted.

- **假关节 / 假深度 (fake joints / fake depth, `BodyRig`)** — the scripted body the
  scenarios pose so the simulator can run without a camera: `BodyRig.geometry(_:distanceCM:)`
  turns a `BodyPose` into a joint map plus one coarse `DepthFrame` (24×32). Deterministic
  and pure; every pose is anchored to the *medium* thresholds (a `nearMiss…` pose sits at
  0.8× a medium threshold, a positive pose clears it). The depth frame feeds the avatar
  only — it is never a real depth reading and never written to disk. Lives in
  `PostureLab/Input/BodyRig.swift`.

## Log-vocabulary mapping

The JSONL log is a contract with QA; the log uses snake_case vocabulary that differs
from the Swift identifiers. The mapping happens at the log boundary only — the code
keeps its own names. QA reads the log, so use the **log** spelling when talking about
log lines.

| Swift (code) | Log (JSONL) |
|---|---|
| `PostureStatus.good` | `good` |
| `PostureStatus.noPerson` | `no_person` |
| `PostureStatus.posture(kind)` | `kind.rawValue` (one of the seven postures) |
| `PostureKind.near` / `.headDown` / … | `near` / `head_down` / … (all seven rawValues) |
| `PostureFeature.distance` / `.handToFace` / … | `distance` / `hand_to_face` / … (all eight rawValues) |
| `MonitoringEvent.calibrated(...)` | `calibration_done` |
| `MonitoringEvent.features(...)` | `features` |
| `MonitoringEvent.viewMode(...)` | `view_mode` |
| `SessionSummary.tooCloseSeconds` | `near_seconds` |
| `SessionSummary.tooCloseCount` | `near_count` |
| `SessionSummary.tooCloseRemindCount` | `near_remind_count` |
| `SessionSummary.headDownCount` | `head_down_count` |
| `SessionSummary.headDownRemindCount` | `head_down_remind_count` |

Every log line carries the full key set (35 keys); `ts` (epoch milliseconds) and `t`
(seconds since session start) are different quantities and neither is renamed — see
`docs/qa-log-schema.md`. Two of those keys — `battery_level` (0...1) and
`thermal_state` (`nominal` / `fair` / `serious` / `critical`) — have no Swift event
behind them: the `FileDebugLogger` samples them from the device and stamps every line.
See ADR-0002.
