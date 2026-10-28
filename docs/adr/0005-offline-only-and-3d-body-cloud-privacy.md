# ADR-0005: Offline-only operation and the 3D body cloud privacy boundary

- **Date**: 2026-10-28
- **Status**: Accepted

## Context

The app watches a child's face and body in the home. Sending that stream anywhere — even to a "privacy-friendly" cloud — would turn a local posture tool into a surveillance surface, and a family cannot audit what leaves the device. At the same time the child needs positive feedback: a black screen with numbers reads as a test, while a figure that mirrors their own body reads as a mirror.

## Decision

PostureLab is **offline by construction**: no network entitlement, no HTTP client, no analytics endpoint. Pomodoro history (`Documents/pomodoro-history.json`), session logs, screenshots and settings (UserDefaults) stay inside the app sandbox on the device. The parent's report is aggregated from that local history by a pure function; nothing is uploaded, and there is no account.

The child's mirror is a **3D body cloud synthesized from the front TrueDepth depth map and the person-segmentation mask** — a sparse coloured point set that hugs the figure, with a clean background and no points. Only depth and mask geometry are rendered: the original RGB camera image is never displayed, never persisted, and never leaves the device.

## Consequences

- Deleting the app deletes all family data; "clear history" in the report is a real, local delete.
- The figure cannot show clothing, the room or a face, which is the point: the parent's report and the child's mirror need posture, not identity.
- The current real-device input source emits distance and pitch only, and the cloud is currently built from pose joints without a segmentation mask; on a camera run it shows its empty state. Wiring TrueDepth depth and person segmentation into the renderer, with no RGB path, is a follow-up ticket.
- Any future sync, backup or crash-reporting feature reopens this ADR; it is not an implementation detail to slip in.
