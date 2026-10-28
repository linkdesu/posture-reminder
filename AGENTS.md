# AGENTS.md

PostureLab — iOS 17, iPhone-only reading-posture companion (Swift/SwiftUI, built with
xcodegen). Offline only; the prototype targets iPhone 13 with TrueDepth face tracking.

## Layout

- `PostureLab/Domain/` — pure logic: `PostureSample`, `PostureClassifier` (baseline,
  features, verdicts), `MonitoringEngine` (one time-injected episode machine per
  posture), `MonitoringEvent`/`LogRecord`, `Sensitivity`, `SessionSummary`,
  `SessionStore`, `SampleSource`. The pomodoro side: `PomodoroEngine` (phase machine),
  `PomodoroRecord`, `PomodoroHistory` (report aggregation), `PomodoroSettings`,
  `PomodoroSettingsStore`, `PomodoroStore` (local history).
- `PostureLab/Input/` — the `SampleSource` implementations: real ARKit face tracking,
  the scripted `Scenario` sources, and `BodyRig` (deterministic synthetic joints and a
  24×32 depth frame for camera-less runs).
- `PostureLab/Session/` — `SessionController` (reading-flow lifecycle, pomodoro
  coordination, pause wiring) and `ReminderPlayer` (pre-recorded clips and cues).
- `PostureLab/Views/` — the reading-flow screens (`HomeView`, `CalibrationView`,
  `MonitoringView`, `SummaryView`, `SettingsView`) and the child-facing pomodoro surface
  (`PomodoroView`, `PomodoroSettingsView`, `ReportView`, `AvatarView`/`BodyCloud`,
  `DebugOverlayView`), plus the shared `PosturePalette`.
- `PostureLab/Resources/Audio/` — one **placeholder** WAV per speaking posture, named
  after the posture's `rawValue`, plus the end-sound cues. They are generated, not
  recorded; replace them with real recordings and keep the names. There is no
  text-to-speech in the app.
- `PostureLabTests/` — unit tests; they exercise the single test seam (sample sequence
  → engine; see ADR-0001).

Two run modes share one coordinator and one clock. A no-argument launch shows the
reading flow (home → calibration → monitoring → summary), which the scripted scenarios
drive. `-pomodoro 1` enters the child-facing pomodoro flow, with the parent's settings
and report behind it; `-settings 1` opens the pomodoro settings and `-report
day|week|month` opens the report. In the pomodoro, the level-1 tone is off and only the
level-2 pre-recorded voice speaks — the zero-interruption rule in ADR-0004; the phase
cues are a separate, non-posture audio path.

## Conventions

- The JSONL log schema is a contract with QA — snake_case keys, `ts` in epoch
  milliseconds, the full **38-key** set on every line. v0.3 added `features` and
  `view_mode`; v0.4/v0.5 added `pomodoro_tick` (`remaining_seconds`, `phase`),
  `speech_played`, `cue_played`, `posture_stats`, and the per-focus
  `session_started`/`session_ended` pair. There are eight postures, including
  `shoulder_tilt`, and the experimental tier never speaks. Change the schema only with
  QA awareness (ADR-0002); read `docs/qa-log-schema.md` to interpret a session log.
- Domain vocabulary: see `GLOSSARY.md`. Decisions that are expensive to reverse live in
  `docs/adr/` — read ADR-0001 (test seam), ADR-0002 (log contract), ADR-0003 (two state
  machines and the pause hard gate), ADR-0004 (non-intrusive pre-recorded reminders),
  and ADR-0005 (offline-only and the 3D body cloud privacy boundary).

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
