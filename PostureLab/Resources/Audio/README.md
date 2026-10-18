# Placeholder reminder clips

These five files are **placeholders, not the final voice recordings**. Each is a soft synthetic
tone so the build has a real, bundled asset per voicing posture before any recording exists.
They are replaced during the recording pass, owned by the product owner (Link) together with
the voice recordings; nobody should ship them as the child-facing voice.

They deliberately contain no speech. The final set must be recorded gentle voice lines, one
per posture, and dropped in under the same names.

## File naming contract

One clip per posture that can speak (the five non-experimental kinds). The file name is exactly
`<PostureKind.rawValue>.wav`, and `ReminderPlayer` looks the clip up by that name:

| Posture | File | Placeholder pitch |
|---|---|---|
| `near` | `near.wav` | C5, 523.25 Hz |
| `head_down` | `head_down.wav` | G4, 392.00 Hz |
| `head_tilt` | `head_tilt.wav` | A4, 440.00 Hz |
| `desk_lean` | `desk_lean.wav` | E4, 329.63 Hz |
| `chin_rest` | `chin_rest.wav` | D5, 587.33 Hz |

The experimental kinds (`head_forward`, `slouch`) have no clip and never reach level 2, so
adding a file for them has no effect.

The replacement recordings must keep the same file names and extension. If the format ever
changes, `ReminderPlayer.clipExtension` is the single place to change, and every file must change
with it — a missing asset is logged as `speech_unavailable` and plays nothing.

## Format: WAV, not m4a

The PRD allowed either. WAV is used because the standard library's `wave` module produces it
with no external tool, so the placeholders are reproducible byte for byte on any machine with
Python and no audio dependencies. These are throwaway placeholders, so the larger file size
(about 52 KB each) does not matter; the final recordings may use m4a if the recording pipeline
prefers it.

## Regenerating

The placeholders are 16-bit mono, 22.05 kHz, 1.2 s, with a raised-cosine attack (0.12 s) and
release (0.30 s) so nothing clicks, at a low peak amplitude (0.18 of full scale). This script
is deterministic and is the source of the committed files:

```python
import math, struct, wave, os

SAMPLE_RATE = 22050
DURATION = 1.2
ATTACK = 0.12
RELEASE = 0.30
PEAK = 0.18

clips = {
    "near": 523.25,
    "head_down": 392.00,
    "head_tilt": 440.00,
    "desk_lean": 329.63,
    "chin_rest": 587.33,
}

frames = int(SAMPLE_RATE * DURATION)
for name, freq in clips.items():
    samples = []
    for i in range(frames):
        t = i / SAMPLE_RATE
        if t < ATTACK:
            env = 0.5 - 0.5 * math.cos(math.pi * t / ATTACK)
        elif t > DURATION - RELEASE:
            env = 0.5 - 0.5 * math.cos(math.pi * (DURATION - t) / RELEASE)
        else:
            env = 1.0
        value = math.sin(2 * math.pi * freq * t) * env * PEAK
        samples.append(int(round(value * 32767)))
    with wave.open(os.path.join("PostureLab/Resources/Audio", name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(struct.pack("<%dh" % len(samples), *samples))
```

`project.yml` includes everything under `PostureLab`, so the files are bundled automatically.
