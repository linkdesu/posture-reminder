# ADR-0004: Non-intrusive, pre-recorded voice reminders in the pomodoro

- **Date**: 2026-10-28
- **Status**: Accepted

## Context

A posture reminder competes with the child's attention. A timer that stops, a dialog that covers the figure, or a loud tone every few seconds teaches the child to dread the app and breaks the focus the pomodoro exists to protect. The parent still needs the posture raised, but only when it is worth raising.

The pomodoro is the **only user-facing flow**: the child presses 开始, the countdown runs, and the settings and report sit behind two small icons; the user side contains exactly those three screens. It has no blocking calibration page: the first 3 seconds of valid face samples at focus start establish the distance and pitch `PostureBaseline` by median, silently; if there is no valid sample, the upright reference stands in.

## Decision

A breaching posture **never pauses the pomodoro, never opens a dialog, never draws an edge warning and never plays the 5-second level-1 tone**. The pomodoro screen keeps its layout and its clock; the only immediate feedback is the tint on the part of the 3D body cloud the dominant posture blames.

The child hears **only a bundled, pre-recorded, gentle WAV voice**, and only after a speakable posture has accumulated 15 seconds of continuous breach. Each speakable posture owns one fixed clip named after its rawValue; system TTS is deliberately not used, because a synthesizer adds a mechanical voice and unpredictable pauses to the one moment the child is already being corrected. Several postures breaching at once are queued by `ReminderPlayer` and spoken one at a time in `PostureKind.priority` order (1…8). The experimental tier (`head_forward`, `slouch`) is recorded in history and the log and, with debug on, highlighted; it **never triggers any reminder at all**, not even level 1.

The parent controls the voice with the settings page's voice switch and volume. With the switch off, the engine still times, logs and counts reminders; only the sound is dropped.

## Consequences

- Reminder events and the audio are decoupled: `reminder` lines exist even when the child hears nothing, and `speech_played` is written only where a clip really started. This keeps QA able to distinguish "no breach" from "breach but muted".
- The bundled clips are placeholders today; replacing them with real recordings is an asset change, not a behaviour change, as long as the names stay `<PostureKind.rawValue>.wav` and `end_<EndSound.rawValue>.wav`.
- The current code still launches into the legacy reading flow, has no silent 3-second calibration, and can emit a level-1 event for an experimental posture when the old switch is on. Aligning those behaviours with these confirmed decisions is a follow-up ticket.
- The one-minute warning and the end sound are cues, not posture reminders: they are not queued behind voice clips and are not silenced by the posture voice switch.
