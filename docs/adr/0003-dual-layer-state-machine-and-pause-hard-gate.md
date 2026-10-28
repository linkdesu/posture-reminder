# ADR-0003: Two state machines and the pause hard gate

- **Date**: 2026-10-28
- **Status**: Accepted

## Context

One pomodoro has two independent clocks: the timer's phases and eight posture episodes. Both have to stop while the child is not being observed, and neither may invent a violation or a reward across that gap. A manual pause and an absence are different causes of the same missing interval, but the parent's timeline must not learn two vocabularies for the same minute.

## Decision

The timer is a **phase machine** (`PomodoroEngine`) over `focus` / `shortBreak` / `longBreak`; posture is **one episode machine per `PostureKind`** (`MonitoringEngine`), each with its own breach clock, escalation and counters. Both are driven only by `PostureSample.t`, so one replay reproduces a run.

**A pause is a hard gate.** Manual pause and absence both freeze the countdown and every posture episode: no breach seconds accrue, no episode escalates, no reminder is emitted, and entering a pause does not reset an episode. Cooldown is measured on the sample clock and therefore keeps running through the pause; it still gates only a new episode's first reminder, not the level-1 → level-2 escalation.

**Time accounting.** Neither pause is counted in `focusedSeconds`; a completed focus equals its plan because the countdown can only reach zero after the plan was actually consumed. A **manual** pause accrues `pausedSeconds`; an **absence** is only excluded from focus time and is not added to `pausedSeconds`. On the report timeline both render as the same grey `paused` band, because the parent is asking "which minutes did the timer not count?", not "which button caused it?".

**Absence limit.** The countdown freezes on the first face-less sample; the posture engine declares its `paused` state after 3 continuous seconds without a face. If one absence lasts longer than 300 seconds, the focus ends where it stands as `interrupted`; no break follows, the next start replays the same focus index, and the child must press 开始 again.

**Resume is a re-measure, not a reset.** When the face returns (or the child resumes), the next sample is classified normally and the state follows it; the engine does not force `good`, because that would hide a posture the child is still holding.

## Consequences

- The UI and the log share one explanation of a frozen countdown; the timer's absence suspension and the posture engine's absence pause cannot drift apart.
- A future change to pause semantics must move the timer and all eight episode machines together, or the `focusedSeconds` / `pausedSeconds` / timeline numbers stop reconciling.
- `pausedSeconds` is deliberately narrower than the grey band; a consumer that needs absence time must derive it from the timeline or from `plannedSeconds - focusedSeconds`, not from `pausedSeconds`.
