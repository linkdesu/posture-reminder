# QA log schema — how to read a PostureLab session log

This is the reference for reading a session log. It describes the wire format that
`FileDebugLogger` writes and that `scripts/verify-session.py` reads. It is the log
reference, not a restatement of the PRD; see `docs/adr/0002-jsonl-log-contract-with-qa.md`
for why the log is a contract and `GLOSSARY.md` for the domain vocabulary. The schema
is a QA contract: a new, renamed, or dropped key breaks the scripts as badly as a
behaviour change, so coordinate with QA before landing one.

## `ts` and `t` are not the same thing

Read this once, carefully, because it is the one thing that is easy to get wrong:

- **`ts` is Unix epoch milliseconds** — an absolute wall-clock instant, the number of
  milliseconds since 1970-01-01T00:00:00Z. It is filled on **every** line.
- **`t` is seconds since the session started** — a relative offset, `0` at session
  start, filled only on events that carry a session time.

They are two different quantities with two different units. **They are not
interchangeable and neither will be renamed.** Do not call both of them "the
timestamp": `ts` is the wall-clock timestamp, `t` is the session-relative time. If you
compare a `ts` value against a `t` value you are comparing milliseconds-since-1970
against seconds-since-start and the arithmetic is meaningless.

## Where the files live

Inside the app sandbox, under `Documents/`:

- `Documents/debug/session-<ISO8601>.jsonl` — one JSONL file per launch. The name is
  the launch time as ISO8601 with the colons stripped, e.g. a launch at
  `2026-10-17T01:23:45Z` produces `session-2026-10-17T012345Z.jsonl`. A fresh run
  writes a new file; `run-scenarios.sh` picks the newest one.
- `Documents/debug/screenshots/<name>.png` — the seven page screenshots, names listed
  under "Screenshots" below.

The logger is only active when debug mode is enabled (`FileDebugLogger.isEnabled`);
with it off, no files are written.

### Pulling the files off a device

`devicectl` copies the whole app data container (or one subdirectory of it):

```sh
xcrun devicectl device copy from \
  --device <device-id> \
  --domain-type appDataContainer \
  --domain-identifier me.xieal.posturelab \
  --source Documents \
  --destination <local-round-directory>
```

That pulls `Documents/` — including `debug/session-*.jsonl` and `debug/screenshots/` —
into the round directory. In the simulator the equivalent is
`xcrun simctl get_app_container <sim-id> me.xieal.posturelab data`. `scripts/run-scenarios.sh`
does both and then feeds the newest `session-*.jsonl` to `scripts/verify-session.py`.

## Line format and the full key set

One JSON object per line, UTF-8, newline-terminated. **Every line carries all 38 keys.**
The writer encodes the complete key set on every line, with `null` for values that do
not apply, so a reader **never has to test for key presence** — a key that is not
meaningful for a given event is present as JSON `null`, not absent. The only per-line
variation is which keys are non-null.

`scripts/verify-session.py` still hard-checks six of them as its P1 reject
(`REQUIRED_KEYS`): `ts`, `event`, `state`, `screen`, `distance_cm`, `pitch_deg`. Those
six are non-null on every line.

## The keys

| Key | Type | Meaning |
|---|---|---|
| `ts` | Int64 | Unix epoch **milliseconds** when the line was produced. Present and non-null on every line. |
| `t` | Double? | **Seconds since session start.** Filled only on events that carry a time (`sample`, `status_changed`, `features`, `reminder`, `paused`, `resumed`); `null` on the rest. |
| `wall_clock` | String? | The same instant as `ts` rendered as ISO8601 (`withInternetDateTime`). Human-readable; use `ts` for arithmetic. |
| `event` | String? | The event kind. See the event table. |
| `state` | String? | Posture state after this line. On `status_changed` lines it is the new state; on every other line the writer stamps the last state it saw (initial `good`). Never `null`. |
| `screen` | String? | Visible screen for this line. On `screen_shown` lines it is the screen just shown; elsewhere the writer stamps the last screen it saw (initial `home`). Never `null`. |
| `distance_cm` | Double? | Distance to the book in cm, for the sample/status/reminder at this tick; `null` when no face was detected or the event carries no sample. |
| `pitch_deg` | Double? | Head pitch in degrees for the same ticks; `null` when the face was not detected. |
| `alert_type` | String? | Reminder posture: one of the eight `PostureKind` rawValues (see the `alert_type` vocabulary). Filled on `reminder`, `speech_timeout`, `speech_unavailable` and `speech_played` lines. |
| `level` | Int? | Reminder level: `1` (gentle) or `2` (voice). Filled on `reminder`, `speech_timeout` and `speech_played` lines. |
| `breach_seconds` | Double? | On a `reminder` line: accumulated breach seconds for this episode at this reminder. An absence pause stops the accumulator, so it is wall-clock time minus any pause inside the episode and can lag the distance from the episode's first breaching sample. |
| `sensitivity` | String? | On the `config` line: `low` / `medium` / `high`. |
| `distance_threshold_cm` | Double? | On the `config` line: the near threshold in cm for this session. |
| `pitch_threshold_deg` | Double? | On the `config` line: the head-down threshold in degrees for this session. |
| `baseline_distance_cm` | Double? | On the `calibration_done` line: calibrated baseline distance (median of the non-empty calibration samples). |
| `baseline_pitch_deg` | Double? | On the `calibration_done` line: calibrated baseline pitch, the reference for head-down. |
| `total_seconds` | Double? | On the `session_ended` line: face-present reading time. |
| `good_seconds` | Double? | On `session_ended`: time with neither violation. |
| `near_seconds` | Double? | On `session_ended`: cumulative time in the near violation. |
| `head_down_seconds` | Double? | On `session_ended`: cumulative time in the head-down violation. |
| `paused_seconds` | Double? | On `session_ended`: time the face was not detected (excluded from `total_seconds`). |
| `near_count` | Int? | On `session_ended`: near episodes that reached level 1. |
| `near_remind_count` | Int? | On `session_ended`: near reminder **lines**, both levels. |
| `head_down_count` | Int? | On `session_ended`: head-down episodes that reached level 1. |
| `head_down_remind_count` | Int? | On `session_ended`: head-down reminder **lines**, both levels. |
| `longest_good_streak_seconds` | Double? | On `session_ended`: longest unbroken run of good seconds. |
| `scenario` | String? | On the `session_started` line: the scripted scenario name, or `null` for a camera run. |
| `message` | String? | On a `cue_played` line: the cue's name — `warn_before_end`, `end_soft` or `end_chime`. `null` on every other line. |
| `battery_level` | Double? | Battery charge in `0...1`. **Writer-sampled**, not event-driven — see below. |
| `thermal_state` | String? | `nominal` / `fair` / `serious` / `critical`. **Writer-sampled** — see below. |
| `highlighted_feature` | String? | On a `features` line: the `PostureFeature` rawValue the debug overlay is highlighting right now, or `null` when nothing is highlighted. |
| `feature_values` | Object? | On a `features` line: one entry per feature, keyed by `PostureFeature` rawValue, each `{"value": …, "threshold": …, "over": …}` (see below). `null` on every other line — but the key itself is present on every line like the rest. |
| `view_mode` | String? | On a `view_mode` line: `avatar` (point-cloud avatar) or `board` (the black-board fallback). |
| `overlay_on` | Bool? | On a `view_mode` line: whether the debug skeleton/feature overlay is on. |
| `avatar_on` | Bool? | On a `view_mode` line: whether avatar mode is on. |
| `posture_stats` | Object? | On the `session_ended` line: one entry per `PostureKind` rawValue with `{"episodes": …, "reminders": …, "seconds": …}` (see below). `null` on every other line — but the key itself is present on every line like the rest. |
| `remaining_seconds` | Double? | On a `pomodoro_tick` line: seconds left in the phase the timer is in. `null` on every other line — but the key itself is present on every line like the rest. |
| `phase` | String? | On a `pomodoro_tick` line: the phase's `PomodoroPhase` rawValue, `focus` / `shortBreak` / `longBreak`. `null` on every other line — but the key itself is present on every line like the rest. |

### The `feature_values` nested shape

`feature_values` is the per-tick object key; `posture_stats` (the next section) is the summary's, and every other key's value is a scalar. Its keys are the eight `PostureFeature` rawValues (`distance`, `head_pitch`, `head_roll`, `shoulder_tilt`, `head_height_drop`, `hand_to_face`, `head_forward`, `slouch`); each maps to a fixed triple:

```json
"feature_values": {
  "distance": { "value": 24.3, "threshold": 30.0, "over": true }
}
```

- `value` — this sample's reading of the feature, in the feature's own unit (cm, degrees, metres, or a normalized ratio; see `PostureFeature` in `GLOSSARY.md`).
- `threshold` — the threshold that value was judged against for this session.
- `over` — whether the value breached its threshold.

The baseline a reading was measured against is deliberately **not** in the triple; QA reads it off the `calibration_done` line. A feature whose inputs were missing is still present, with its `value` set to half the threshold and `over` `false` — an absent measurement is never recorded as a breach.

### The `posture_stats` nested shape

`posture_stats` is filled on the `session_ended` line only, and is JSON `null` on every other line. It has one entry per `PostureKind` rawValue — all eight, the two experimental kinds included — so a consumer never has to test for a kind. Each entry is a fixed triple:

```json
"posture_stats": {
  "near": { "episodes": 1, "reminders": 2, "seconds": 24.9 }
}
```

- `episodes` — episodes of that posture that reached level 1, whether or not the line was voiced. For `near` and `head_down` this is the same number as `near_count` / `head_down_count`.
- `reminders` — reminder **lines** emitted for that posture, both levels; an escalated episode counts twice. For `near` and `head_down` this is the same number as `near_remind_count` / `head_down_remind_count`, and it is `0` for a kind that never speaks.
- `seconds` — accumulated breach seconds for that posture, with pauses excluded. For `near` and `head_down` it agrees with `near_seconds` / `head_down_seconds`, which the QA checker cross-checks.

A kind that never breached is present with all three values `0`. The two experimental kinds (`head_forward`, `slouch`) never emit a reminder, so their `episodes` can be non-zero while `reminders` stays `0` — that is the intended reading, not a contradiction.

## Events

| `event` | Meaning | Non-`null` keys it fills (besides the always-set `ts`, `state`, `screen`) |
|---|---|---|
| `session_started` | A session began. | `scenario` |
| `config` | The thresholds in force for the session. | `sensitivity`, `distance_threshold_cm`, `pitch_threshold_deg` |
| `calibration_done` | Calibration finished; the baseline is set. | `baseline_distance_cm`, `baseline_pitch_deg` |
| `screen_shown` | A screen appeared. | `screen` |
| `sample` | One camera tick (10 Hz in a scripted run). | `t`, `distance_cm`, `pitch_deg` |
| `status_changed` | The displayed posture state changed. | `t`, `state`, `distance_cm`, `pitch_deg` |
| `features` | A feature sample line — one per five samples (2 Hz at the 10 Hz tick). Enough to reconstruct a decision, not enough to flood the log. | `t`, `highlighted_feature`, `feature_values` |
| `view_mode` | A layer-state change: the avatar / black-board mode or either overlay switch changed. | `view_mode`, `overlay_on`, `avatar_on` |
| `reminder` | A reminder fired (level 1 gentle or level 2 voice). | `t`, `alert_type`, `level`, `breach_seconds`, `distance_cm`, `pitch_deg` |
| `speech_timeout` | The audio watchdog fired: a clip started but never reported finishing within its length + 2 s, so the queue was advanced anyway. | `alert_type`, `level` (no `t` — the player has no session clock) |
| `speech_unavailable` | The posture's placeholder clip could not be loaded or decoded, so the reminder was silent. Nothing is played twice, and the queue advances. | `alert_type` (no `t`, no `level`) |
| `speech_played` | A clip reported that it **started** playing. Written where the player actually starts the clip, not where it was queued, so the line never claims audio for an asset that is missing or will not play — those report `speech_unavailable` instead. It is proof that the player loaded and started the clip, not that a room heard it. | `alert_type`, `level` (no `t` — the player has no session clock) |
| `pomodoro_tick` | The pomodoro countdown, written **once per second of the sample clock** while a phase is running, so a run is a descending series of lines instead of a single start and end. One line per sample (10 Hz) would bury the log; this is the pomodoro flow only, and a phase that is paused or parked writes nothing. | `remaining_seconds`, `phase` (no `t` — read the instant off `ts`, which is on every line) |
| `cue_played` | A pomodoro cue reported that it **started** playing: the one-minute warning, or the end sound of a finished focus. Written where the clip really started, so a cue that could not be loaded or started writes nothing, and `EndSound.none` writes nothing at all. Like `speech_played`, it is proof that the player started the clip, not that a room heard it. | `message` (the cue name); no `t` — the player has no session clock |
| `paused` | The absence pause started (no face for 3 s). | `t` |
| `resumed` | The absence pause ended (a face reappeared). | `t` |
| `session_ended` | The session ended; carries the summary. | `total_seconds`, `good_seconds`, `near_seconds`, `head_down_seconds`, `paused_seconds`, `near_count`, `near_remind_count`, `head_down_count`, `head_down_remind_count`, `longest_good_streak_seconds`, `posture_stats` |

Ordering within one tick follows the engine: `sample`, then `paused`/`resumed`, then
`status_changed` (only when the state changes), then any `reminder`s, then the `features`
line when the tick is a feature sample (every fifth). When several postures fire
`reminder`s on the same tick they appear in ascending `PostureKind.priority` order, one
line per posture.

In the pomodoro flow the same ordering holds per sample, and a sample's `pomodoro_tick`
line comes last: a phase that ended on that sample has already moved on by the time the
tick is written, so the tick always names the phase the sample left the timer in.

## Vocabularies

### `state`

`good`, `no_person`, plus the eight posture rawValues: `desk_lean`, `near`,
`head_forward`, `slouch`, `head_down`, `head_tilt`, `shoulder_tilt`, `chin_rest`.

The ten values come from `PostureStatus` (`good`, `no_person`, or `posture(kind)`) and
its rawValues are exactly `PostureKind`'s — there is one posture vocabulary, not two.

### `screen`

`home`, `calibration`, `calibration_result`, `monitoring`, `summary`, `settings`.
Note `reminder` is **not** a `screen` value: the reminder screenshot is captured
directly without a `screen_shown` line, so it never contaminates the `screen` key.

### `alert_type`

The same eight posture rawValues as `state`: `desk_lean`, `near`, `head_forward`,
`slouch`, `head_down`, `head_tilt`, `shoulder_tilt`, `chin_rest`.

### `level`

`1` = gentle (tone + orange edge), `2` = voice (zh-CN speech).

### `sensitivity`

`low` → 25 cm / 25°, `medium` → 30 cm / 20°, `high` → 35 cm / 15°.

### `thermal_state`

`nominal`, `fair`, `serious`, `critical`.

## Swift-to-log name mapping

The code keeps its own identifiers; the mapping happens only at the log boundary.

| Swift (code) | Log (JSONL) |
|---|---|
| `PostureStatus.good` | `good` |
| `PostureStatus.noPerson` | `no_person` |
| `PostureStatus.posture(kind)` | `kind.rawValue` (one of the eight postures) |
| `PostureKind.near` / `.headDown` / … | `near` / `head_down` / … (all eight rawValues) |
| `PostureFeature.distance` / `.handToFace` / … | `distance` / `hand_to_face` / … (all eight rawValues) |
| `MonitoringEvent.calibrated(...)` | `calibration_done` |
| `MonitoringEvent.features(...)` | `features` |
| `MonitoringEvent.viewMode(...)` | `view_mode` |
| `MonitoringEvent.speechTimeout(...)` | `speech_timeout` |
| `MonitoringEvent.speechUnavailable(...)` | `speech_unavailable` |
| `MonitoringEvent.speechPlayed(...)` | `speech_played` |
| `MonitoringEvent.pomodoroTick(...)` | `pomodoro_tick` |
| `SessionSummary.tooCloseSeconds` | `near_seconds` |
| `SessionSummary.tooCloseCount` | `near_count` |
| `SessionSummary.tooCloseRemindCount` | `near_remind_count` |
| `SessionSummary.headDownCount` | `head_down_count` |
| `SessionSummary.headDownRemindCount` | `head_down_remind_count` |

## Every posture is timed, logged and counted on its own

v0.3 runs **one episode machine per `PostureKind`**, so each of the eight postures keeps
its own breach clock, its own level-1/level-2 escalation and its own counters. The
consequences for reading a log:

- **A tick can carry more than one `reminder` line.** Every breaching, speakable posture
  emits its own `reminder`; several fire on the same tick when several postures breach at
  once, in ascending `PostureKind.priority` order. Nothing is suppressed to leave room
  for another.
- **The priority order only sequences the voice queue, it does not select one posture.**
  `PostureKind.priority` (deskLean 1, near 2, headForward 3, slouch 4, headDown 5,
  headTilt 6, shoulderTilt 7, chinRest 8) orders the *speech* queue so the player speaks
  one line at a time; it never causes a breaching posture to go untimed, unlogged or
  uncounted. `state` still reports only the single highest-priority breaching posture
  (`dominant`), which is why `state` is coarser than the `reminder` lines.
- **Experimental postures (head-forward, slouch) never speak.** At the default setting
  (`experimentalPostures` off) they produce **no `reminder` at all** — not even a tone —
  while still moving `state`, still writing `features` lines and still counting episodes
  internally. With the experimental toggle on they enter the reminder stream but are
  **capped at level 1**: at most one gentle tone, never a level-2 voice line, because
  `PostureKind.voiceLine` is `nil` for them. So a `reminder` line whose `alert_type` is
  `head_forward` or `slouch` is always `level` 1.
- **`speech_unavailable` / `speech_timeout` follow the same `alert_type` rules** and are
  only ever emitted for a kind that was allowed to speak.

## The counting convention: episodes vs reminder lines

Every posture tracked by the engine has **two** counters, and they are counted
differently. Only the `near` and `head_down` pair reaches the `session_ended` summary
today, but the engine keeps a pair per `PostureKind` internally for the log and the next
slice:

- The `*_count` key (`near_count`, `head_down_count`) counts **episodes that reached
  level 1** — one per episode, no matter how high it escalated.
- The `*_remind_count` key (`near_remind_count`, `head_down_remind_count`) counts
  **reminder lines**, both levels.

So an episode that escalates to level 2 adds **1** to the episode counter and **2** to
the remind counter. Concretely, a run where a single near episode fires level 1 then
level 2, and a head-down episode fires only level 1, ends with:

```
near_count = 1              near_remind_count = 2
head_down_count = 1         head_down_remind_count = 1
```

Each counter is incremented by `MonitoringEngine` as the corresponding reminder fires,
alongside the episode's first (level 1) reminder. `near_count` is the legacy name for
the near episode counter; there is no `head_down_episode_count`.

## Statistics semantics (`session_ended`, and what `verify-session.py` recomputes)

The checker on `scripts/verify-session.py` recomputes the summary from the `sample`
lines alone — nothing is taken on trust from the app — using exactly these rules, so a
log that satisfies them is a log whose summary is derivable:

- **`dt` is credited to the sample at the start of the interval.** For two consecutive
  samples at `t0 < t1`, the interval `dt = t1 − t0` is attributed to the `t0` sample's
  class, not the `t1` sample's. Consequence: a change in state is reflected on the
  interval that *begins* at the transition, and the final gap from the last sample to
  the session end is credited by the engine's `finish` but is not visible to a
  samples-only recompute — hence the checker's ±1 s tolerance on the totals.
- **No time accrues while the face is missing.** When the `t0` sample has a `null`
  distance or pitch, the interval is credited to `paused_seconds` and to nothing else:
  no `total_seconds`, no violation seconds, and the good streak neither grows nor
  resets.
- **`total_seconds` is face-present time**: it adds `dt` over exactly the intervals
  whose start sample had a detected face.
- **`good_seconds` excludes every posture, not just the first two.** It adds `dt` only
  when the start sample had a face and **no posture breached at all** — the same condition
  as `state = good`. Before v0.3 this counted only near and head-down, so a session spent
  chin-resting reported itself as entirely good; if you are reading an older log, expect
  that number to disagree with the `status_changed` timeline.
- **The two violation counters are independent and may overlap.** `near_seconds` and
  `head_down_seconds` each add `dt` whenever their own predicate holds, so a sample
  that is both too close and head-down contributes the same `dt` to **both**. It is
  therefore normal for `near_seconds + head_down_seconds + good_seconds` to exceed
  `total_seconds`. The predicates are strict: near is `distance_cm <
  distance_threshold_cm` (equal is not a violation), head-down is `baseline_pitch_deg −
  pitch_deg > pitch_threshold_deg`. The other six postures have no `*_seconds` counter yet;
  their time shows up as absent from `good_seconds` and as `reminder` lines.
- **`longest_good_streak_seconds`** is the longest unbroken run of good intervals; a breach
  of **any** posture resets the running streak to 0, and absence neither extends it nor
  resets it.
- **Thresholds come from the log, not from constants**: the checker reads
  `distance_threshold_cm` and `pitch_threshold_deg` from the `config` line and
  `baseline_pitch_deg` from the `calibration_done` line.

## Battery and thermal state are a trend line, not a per-sample reading

`battery_level` and `thermal_state` have no event behind them: `FileDebugLogger` samples
them from the device itself and stamps every line with the most recent value. The
sample is **refreshed at most once every 10 seconds**, so a run of consecutive lines
shares the same value and the pair forms a coarse trend. To read them, compare the
first and last line of a session (see AC8); do not treat a change between two adjacent
lines as a per-sample reading. `battery_level` is `null` where the device does not
report a charge (e.g. the simulator), and `thermal_state` is one of `nominal`, `fair`,
`serious`, `critical`.

## Screenshots

`Documents/debug/screenshots/` holds seven PNGs: `home`, `calibration`,
`calibration_result`, `monitoring`, `summary`, `settings`, `reminder`. The `reminder`
shot exists only in a run where a level-1 reminder actually fired; `verify-session.py`
drops it from its expected set otherwise. In a scripted run the `settings` shot is
produced only when the run was launched with the `-captureSettings` argument.

## Which key answers which acceptance criterion

This table indexes the reading-session acceptance list (AC1 = first run through
`calibration_done`, and so on). The pomodoro round numbers its own checklist separately:
there its AC1 is the countdown, answered by the `pomodoro_tick` series — `remaining_seconds`
falling in step with the `ts` gap between lines, with no gap in the series — and its AC4 is
the audio, answered by `speech_played` lines (`alert_type` + `level`) plus the absence of
any such line while the voice switch is off.

| AC | Evidence in the log |
|---|---|
| AC1 | Order of `screen_shown` lines (`home` → `calibration` → `calibration_result`) and the `calibration_done` line's `baseline_distance_cm` / `baseline_pitch_deg`. |
| AC2 | `distance_cm` / `pitch_deg` on `sample` lines to find the first breach; the `t` values on `reminder` lines (`level` 1 and 2) minus that first breach; `distance_threshold_cm` / `pitch_threshold_deg` from `config`; `baseline_pitch_deg`. |
| AC3 | `status_changed` with `state = good` after the approach; absence of `near` `reminder` lines within the cooldown window. |
| AC4 | `reminder` lines with `alert_type = head_down`, `level` 1 and (when sustained) 2. |
| AC5 | `status_changed` with `state = no_person`; `paused` / `resumed` lines; `paused_seconds` and the fact that `total_seconds` does not grow across the pause. |
| AC6 | The `session_ended` summary keys: `total_seconds`, `good_seconds`, `near_seconds`, `head_down_seconds`, `longest_good_streak_seconds` (recomputed from samples). |
| AC7 | `config`: `sensitivity`, `distance_threshold_cm`, `pitch_threshold_deg` (35/15, 30/20, 25/25); the shift in when the `reminder`s fire. |
| AC8 | `battery_level` and `thermal_state` on the first and last lines; the `ts` span across the run. |
| AC9 | The seven PNGs under `Documents/debug/screenshots/` (not a log key). |
| AC10 | Same keys as AC2/AC4 from a real-camera run: `reminder` timing and `alert_type`. |
| AC11 | No `reminder` lines at all. |
| AC12 | `paused` lines, no `reminder` lines, no violation seconds, and every `reminder` line carrying `t`, `alert_type` and `level`. |
