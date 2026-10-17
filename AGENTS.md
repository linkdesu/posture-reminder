# AGENTS.md

PostureLab — iOS 17, iPhone-only reading-posture reminder prototype (Swift/SwiftUI,
built with xcodegen). Offline only; the prototype targets iPhone 13 with the TrueDepth
camera.

## Layout

- `PostureLab/Domain/` — pure logic: `PostureSample`, `MonitoringEngine` (the
  time-injected reminder state machine), `MonitoringEvent`/`LogRecord`, `Sensitivity`,
  `SessionSummary`, `SessionStore`, `SampleSource`.
- `PostureLab/Input/` — the `SampleSource` implementations: real ARKit input and the
  scripted `Scenario` sources.
- `PostureLab/Session/` — `SessionController` (calibration, monitoring lifecycle) and
  `ReminderPlayer`.
- `PostureLab/Views/` — the SwiftUI screens.
- `PostureLabTests/` — unit tests; they exercise the single test seam (sample sequence
  → engine; see ADR-0001).

## Conventions

- The JSONL log schema is a contract with QA — snake_case keys, `ts` in epoch
  milliseconds, the full 35-key set on every line (v0.3 adds the `features` and
  `view_mode` events with `highlighted_feature`/`feature_values`/`view_mode`/`overlay_on`/
  `avatar_on`, and experimental postures never speak). Change it only with QA awareness
  (ADR-0002); read `docs/qa-log-schema.md` to interpret a session log.
- Domain vocabulary: see `GLOSSARY.md`.
- Decisions that are expensive to reverse live in `docs/adr/`.

## Agent skills

### Issue tracker

Issues and specs live as GitHub issues in `linkdesu/posture-reminder` (the `origin`
remote), driven with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles map 1:1 to their own label strings
(`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See
`docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: `GLOSSARY.md` at the root, ADRs in `docs/adr/`. See
`docs/agents/domain.md`.
