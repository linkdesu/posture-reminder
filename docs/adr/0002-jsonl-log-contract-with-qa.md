# ADR-0002: The JSONL log is a contract with QA — snake_case, epoch-millisecond `ts`, full key set per line

- **Date**: 2026-10-17
- **Status**: Accepted

## Context

QA accepts this app remotely: they read the JSONL debug log and the screenshot
evidence without watching the screen. The log is therefore not a debugging
convenience but a **contract** with the QA scripts — a schema change breaks the
scripts as badly as a behaviour change.

The domain, however, has its own Swift vocabulary (`PostureStatus.tooClose`,
`ReminderKind.headDown`, `SessionSummary.tooCloseCount`, …) that differs from the
log vocabulary (`near`, `head_down`, `near_count`, …). The two must not be forced
together by renaming code.

## Decision

The log schema (v2) is fixed as follows:

- Keys are **snake_case**; every line carries the full key set (30 keys). `LogRecord`
  has a custom `encode(to:)` that writes every key on every line — absent values are
  encoded as JSON `null` via `encodeNil()`. It must not be switched to
  `encodeIfPresent`, which would make the key set vary by line and break the
  contract. The key-by-key reference lives in `docs/qa-log-schema.md`.
- `ts` is the Unix epoch milliseconds when the line was produced; it is present on
  **every** line (filled from `now`), not only on lines that carry a session time.
- `t` (seconds since session start) is filled only by events that carry a time.
- The `event` values are the snake_case case names: `session_started`, `config`,
  `calibration_done`, `screen_shown`, `sample`, `status_changed`, `reminder`,
  `speech_timeout`, `speech_unavailable`, `paused`, `resumed`, `session_ended`.
  The two speech events exist because a device with no Chinese voice, or a
  synthesizer that never reports a finish, must still be visible from the log
  rather than silently swallowing a reminder.
- The **domain-vocabulary mapping happens at the log boundary only**: Swift
  identifiers keep their code names, and the mapping to log spellings lives in the
  `MonitoringEvent.logRecord(now:)` conversion (see the mapping table in
  `GLOSSARY.md`). `FileDebugLogger` additionally merges its own `state` and `screen`
  tracking values into every line.

## Consequences

- QA can read a uniform schema from any line of any session; parsing is a flat,
  key-complete JSON object per line.
- The Swift codebase stays in its own naming; no identifier in `PostureLab/` is
  shaped like a log key, and renaming the log vocabulary is a schema (and QA)
  concern, not a code refactor.
- Any schema change (a new key, a renamed key, a dropped key) is a **breaking
  change to the QA contract** and must be coordinated with QA before landing.
- The mapping table in `GLOSSARY.md` is the single source of truth between the two
  vocabularies; if it drifts from the code, the log is wrong even though the
  behaviour is right.
