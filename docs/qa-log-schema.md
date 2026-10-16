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

One JSON object per line, UTF-8, newline-terminated. **Every line carries all 30 keys.**
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
| `t` | Double? | **Seconds since session start.** Filled only on events that carry a time (`sample`, `status_changed`, `reminder`, `paused`, `resumed`); `null` on the rest. |
| `wall_clock` | String? | The same instant as `ts` rendered as ISO8601 (`withInternetDateTime`). Human-readable; use `ts` for arithmetic. |
| `event` | String? | The event kind. See the event table. |
| `state` | String? | Posture state after this line. On `status_changed` lines it is the new state; on every other line the writer stamps the last state it saw (initial `good`). Never `null`. |
| `screen` | String? | Visible screen for this line. On `screen_shown` lines it is the screen just shown; elsewhere the writer stamps the last screen it saw (initial `home`). Never `null`. |
| `distance_cm` | Double? | Distance to the book in cm, for the sample/status/reminder at this tick; `null` when no face was detected or the event carries no sample. |
| `pitch_deg` | Double? | Head pitch in degrees for the same ticks; `null` when the face was not detected. |
| `alert_type` | String? | Reminder kind: `near` or `head_down`. Filled on `reminder`, `speech_timeout` and `speech_unavailable` lines. |
| `level` | Int? | Reminder level: `1` (gentle) or `2` (voice). Filled on `reminder` lines and on `speech_timeout`. |
| `breach_seconds` | Double? | On a `reminder` line, seconds from the episode's breach start to this reminder (`t − breachStart`). |
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
| `message` | String? | Reserved. No event fills it today, so it is `null` on every line. |
| `battery_level` | Double? | Battery charge in `0...1`. **Writer-sampled**, not event-driven — see below. |
| `thermal_state` | String? | `nominal` / `fair` / `serious` / `critical`. **Writer-sampled** — see below. |

## Events

| `event` | Meaning | Non-`null` keys it fills (besides the always-set `ts`, `state`, `screen`) |
|---|---|---|
| `session_started` | A session began. | `scenario` |
| `config` | The thresholds in force for the session. | `sensitivity`, `distance_threshold_cm`, `pitch_threshold_deg` |
| `calibration_done` | Calibration finished; the baseline is set. | `baseline_distance_cm`, `baseline_pitch_deg` |
| `screen_shown` | A screen appeared. | `screen` |
| `sample` | One camera tick (10 Hz in a scripted run). | `t`, `distance_cm`, `pitch_deg` |
| `status_changed` | The displayed posture state changed. | `t`, `state`, `distance_cm`, `pitch_deg` |
| `reminder` | A reminder fired (level 1 gentle or level 2 voice). | `t`, `alert_type`, `level`, `breach_seconds`, `distance_cm`, `pitch_deg` |
| `speech_timeout` | The speech watchdog fired: synthesis started but never called back within the estimate + 2 s, so the voice queue was advanced anyway. | `alert_type`, `level` (no `t` — the speaker has no session clock) |
| `speech_unavailable` | No `zh-CN` voice is installed, so the voice reminder could not be spoken; the player falls back to the gentle tone. | `alert_type` (no `t`, no `level`) |
| `paused` | The absence pause started (no face for 3 s). | `t` |
| `resumed` | The absence pause ended (a face reappeared). | `t` |
| `session_ended` | The session ended; carries the summary. | `total_seconds`, `good_seconds`, `near_seconds`, `head_down_seconds`, `paused_seconds`, `near_count`, `near_remind_count`, `head_down_count`, `head_down_remind_count`, `longest_good_streak_seconds` |

Ordering within one tick follows the engine: `sample`, then `paused`/`resumed`, then
`status_changed` (only when the state changes), then any `reminder`s (`near` before
`head_down` when both fire on the same tick).

## Vocabularies

### `state`

`good`, `near`, `head_down`, `no_person`.

### `screen`

`home`, `calibration`, `calibration_result`, `monitoring`, `summary`, `settings`.
Note `reminder` is **not** a `screen` value: the reminder screenshot is captured
directly without a `screen_shown` line, so it never contaminates the `screen` key.

### `alert_type`

`near`, `head_down` (the two reminder kinds).

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
| `PostureStatus.tooClose` | `near` |
| `PostureStatus.headDown` | `head_down` |
| `PostureStatus.absent` | `no_person` |
| `ReminderKind.tooClose` | `near` |
| `ReminderKind.headDown` | `head_down` |
| `MonitoringEvent.calibrated(...)` | `calibration_done` |
| `MonitoringEvent.speechTimeout(...)` | `speech_timeout` |
| `MonitoringEvent.speechUnavailable(...)` | `speech_unavailable` |
| `SessionSummary.tooCloseSeconds` | `near_seconds` |
| `SessionSummary.tooCloseCount` | `near_count` |
| `SessionSummary.tooCloseRemindCount` | `near_remind_count` |
| `SessionSummary.headDownCount` | `head_down_count` |
| `SessionSummary.headDownRemindCount` | `head_down_remind_count` |

## The counting convention: episodes vs reminder lines

Each posture has **two** counters, and they are counted differently:

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
- **`good_seconds` excludes both violations**: it adds `dt` only when the start sample
  had a face and was neither near nor head-down.
- **The two violation counters are independent and may overlap.** `near_seconds` and
  `head_down_seconds` each add `dt` whenever their own predicate holds, so a sample
  that is both too close and head-down contributes the same `dt` to **both**. It is
  therefore normal for `near_seconds + head_down_seconds + good_seconds` to exceed
  `total_seconds`. The predicates are strict: near is `distance_cm <
  distance_threshold_cm` (equal is not a violation), head-down is `baseline_pitch_deg −
  pitch_deg > pitch_threshold_deg`.
- **`longest_good_streak_seconds`** is the longest unbroken run of good intervals; any
  violation interval (near or head-down) resets the running streak to 0.
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
