# ADR-0001: A single test seam — posture-sample sequence into a pure, time-injected state machine

- **Date**: 2026-10-17
- **Status**: Accepted

## Context

PostureLab's core behaviour — violation detection, the two-level reminder ladder,
cooldown, absence pause, and session statistics — has to be verified three ways:
unit tests, scripted simulated runs, and real-device acceptance. The camera path
(ARKit) and the scripted `Scenario` path are two implementations of one thing;
unit tests must not depend on a real camera, and the scripted runs must exercise
exactly the same behaviour as the real device.

The engine has no access to wall-clock time. All timing (the 5 s gentle delay, the
15 s voice delay, the 30 s cooldown, the 3 s absence pause) derives from
`PostureSample.t`, the seconds since session start carried on each sample. This is
a deliberate constraint: a recorded sample stream replayed into the engine is
deterministic byte for byte, so tests need no clock, no `sleep`, and no network.

## Decision

There is **one test seam** in the app: a sequence of `PostureSample`s, together with
the calibration baseline and the settings, is fed into the pure state machine
(`MonitoringEngine`), and the output — the sequence of `MonitoringEvent`s with their
times and levels, plus the resulting `SessionSummary` — is asserted.

The real input source and the scripted input source both conform to the single
`SampleSource` interface (`onSample` + `start()`/`stop()`), so every code path
downstream of a sample is shared. Unit tests and real-device simulated acceptance
therefore test the same behaviour. Tests only look at external behaviour: feed a
sample timeline in, assert the emitted events — never internal implementation.

## Consequences

- Adding a new input source (or changing ARKit details) cannot change reminder
  behaviour; any behavioural fix must be made in the engine and is covered by the
  same seam.
- Tests are fast and deterministic: no camera, no timing flakiness, no simulator
  needed for the domain.
- The seam's contract is the log: event names and values are QA's vocabulary
  (ADR-0002), so tests and the log speak the same language.
- If a future design introduces time outside `PostureSample.t` (e.g. wall-clock
  scheduling in the coordinator), the seam narrows to the engine only; that would
  be a trade to reopen deliberately, not an accident.
