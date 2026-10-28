# ADR-0004: Non-intrusive, pre-recorded voice reminders in the pomodoro

- **Date**: 2026-10-28
- **Status**: Accepted

## Context

A posture reminder competes with the child's attention. A timer that stops, a dialog that covers the figure, or a loud tone every few seconds teaches the child to dread the app and breaks the focus the pomodoro exists to protect. The parent still needs the posture raised, but only when it is worth raising.

The pomodoro is the child-facing product flow: the child presses 开始, the countdown runs, and the settings and report sit behind two small icons. It does not use the reading flow's blocking calibration page; posture judgement reuses the persisted `PostureBaseline` (or the upright reference when the family has never calibrated).

## Decision

A breaching posture **never pauses the pomodoro, never opens a dialog, never draws an edge warning and never plays the 5-second level-1 tone**. The pomodoro screen keeps its layout and its clock; the only immediate feedback is the tint on the part of the 3D body cloud the dominant posture blames.

The child hears **only a bundled, pre-recorded, gentle WAV voice**, and only after a speakable posture has accumulated 15 seconds of continuous breach. Each speakable posture owns one fixed clip named after its rawValue; system TTS is deliberately not used, because a synthesizer adds a mechanical voice and unpredictable pauses to the one moment the child is already being corrected. Several postures breaching at once are queued by `ReminderPlayer` and spoken one at a time in `PostureKind.priority` order (1…8). The experimental tier (`head_forward`, `slouch`) is recorded and, with debug on, highlighted, but **never speaks**; with the experimental switch on it is still capped at the silent level-1 event.

The parent controls the voice with the settings page's voice switch and volume. With the switch off, the engine still times, logs and counts reminders; only the sound is dropped.

## Consequences

- Reminder events and the audio are decoupled: `reminder` lines exist even when the child hears nothing, and `speech_played` is written only where a clip really started. This keeps QA able to distinguish "no breach" from "breach but muted".
- The bundled clips are placeholders today; replacing them with real recordings is an asset change, not a behaviour change, as long as the names stay `<PostureKind.rawValue>.wav` and `end_<EndSound.rawValue>.wav`.
- The legacy reading flow (home → calibration → monitoring → summary) still exists in the same binary and is what a no-argument launch shows; it is not the child-facing pomodoro surface, but removing it is a separate cutover, not something this decision silently did.
- The one-minute warning and the end sound are cues, not posture reminders: they are not queued behind voice clips and are not silenced by the posture voice switch.
