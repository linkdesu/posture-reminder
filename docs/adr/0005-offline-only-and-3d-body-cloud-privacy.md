# ADR-0005: Offline-only operation and the 3D body cloud privacy boundary

- **Date**: 2026-10-28
- **Status**: Accepted

## Context

The app watches a child's face and body in the home. Sending that stream anywhere — even to a "privacy-friendly" cloud — would turn a local posture tool into a surveillance surface, and a family cannot audit what leaves the device. At the same time the child needs positive feedback: a black screen with numbers reads as a test, while a figure that mirrors their own body reads as a mirror.

## Decision

PostureLab is **offline by construction**: no network entitlement, no HTTP client, no analytics endpoint. Pomodoro history (`Documents/pomodoro-history.json`), session logs, screenshots and settings (UserDefaults) stay inside the app sandbox on the device. The parent's report is aggregated from that local history by a pure function; nothing is uploaded, and there is no account.

The child's mirror is a **3D body cloud built from pose joints** — a sparse coloured point set covering the head, torso and upper arms. The renderer draws geometry only: it never reads, displays or persists an RGB camera image, and the depth frame an input sample may carry feeds the figure and the debug overlay, never a file. The input contract itself has no image field, so an RGB frame cannot leak through code that later forgets the rule.

## Consequences

- Deleting the app deletes all family data; "clear history" in the report is a real, local delete.
- The figure cannot show clothing, the room or a face, which is the point: the parent's report and the child's mirror need posture, not identity.
- The current real-device input source emits distance and pitch only; joints and the coarse depth frame come from the synthetic rig, so on a camera run the cloud shows its empty state. Wiring TrueDepth body geometry into the real source is a follow-up; it must keep this boundary (no RGB) when it lands.
- Any future sync, backup or crash-reporting feature reopens this ADR; it is not an implementation detail to slip in.
