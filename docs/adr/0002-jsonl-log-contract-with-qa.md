# ADR-0002: The JSONL log is a contract with QA — snake_case, epoch-millisecond `ts`, 38 keys per line

- **Date**: 2026-10-17
- **Status**: Accepted

## Context

QA accepts this app remotely: they read the JSONL debug log and the screenshot evidence without watching the screen. The log is therefore not a debugging convenience but a **contract** with the QA scripts — a schema change breaks the scripts as badly as a behaviour change.

The domain has its own Swift vocabulary (`PostureStatus.noPerson`, `MonitoringEvent.speechPlayed`, `SessionSummary.tooCloseCount`, …) that differs from the log vocabulary (`no_person`, `speech_played`, `near_count`, …). The two must not be forced together by renaming code.

## Decision

The log schema is fixed as follows:

- Keys are **snake_case**; every line carries the full key set (**38 keys**). `LogRecord` has a custom `encode(to:)` that writes every key on every line — absent values become JSON `null`. It must not be switched to `encodeIfPresent`, which would make the key set vary by line and break the contract.
- `ts` is Unix epoch milliseconds, filled on **every** line. `t` is seconds since session start and is filled only by events that carry a session time.
- The `event` values are the snake_case case names: `session_started`, `config`, `calibration_done`, `screen_shown`, `sample`, `status_changed`, `features`, `view_mode`, `reminder`, `speech_timeout`, `speech_unavailable`, `speech_played`, `pomodoro_tick`, `cue_played`, `paused`, `resumed`, `session_ended`.
- v0.3 added `features` (`highlighted_feature`, `feature_values`) and `view_mode` (`view_mode`, `overlay_on`, `avatar_on`). v0.4/v0.5 added `pomodoro_tick` (`remaining_seconds`, `phase`), `speech_played`, `cue_played` (`message`), `posture_stats`, and the per-focus `session_started` / `session_ended` pair a pomodoro writes.
- Posture audio is a **bundle of pre-recorded WAV clips** — one voice line per speakable posture plus the phase cues. There is no system TTS anywhere, so there is no synthesis-start or synthesis-timeout ambiguity: `speech_played` and `cue_played` are written where a clip really started, and a missing asset reports `speech_unavailable` (or writes nothing, for a cue).
- The **domain-vocabulary mapping happens at the log boundary only**: Swift identifiers keep their code names. The complete Swift ↔ JSONL mapping table lives in `docs/qa-log-schema.md`, which is the single source of truth for the wire vocabulary; `GLOSSARY.md` stays domain language and carries no implementation paths.

## Consequences

- QA can read a uniform schema from any line of any session; parsing is a flat, key-complete JSON object per line.
- The Swift codebase stays in its own naming; no identifier in `PostureLab/` is shaped like a log key.
- Any schema change (a new key, a renamed key, a dropped key) is a **breaking change to the QA contract** and must be coordinated with QA before landing.
- If the mapping table in `docs/qa-log-schema.md` drifts from the code, the log is wrong even though the behaviour is right.
