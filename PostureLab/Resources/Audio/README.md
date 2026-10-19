# Placeholder audio clips

This folder holds two families of generated placeholders. Neither family is a final
recording: every file is a soft synthetic tone whose only job is to give the build a real,
bundled asset. They deliberately contain no speech.

- **Posture reminders** — six files, one per speaking posture (`near` … `chin_rest`).
  These are **placeholders for the child-facing voice lines**, replaced during the
  recording pass, owned by the product owner (Link) together with the voice recordings;
  nobody should ship them as the child-facing voice. The final set must be recorded gentle
  voice lines, one per posture, dropped in under the same names.
- **Pomodoro finish sounds** — two files, `end_soft.wav` and `end_chime.wav`. These are
  **the pomodoro's end-of-phase sounds, not posture reminders**: the pomodoro surface picks
  one from the `EndSound` setting (`soft` / `chime` / `none`) and hands the matching
  `PomodoroCue` to `ReminderPlayer.play(cue:)`, which loads and starts the clip. They are
  never played as a posture cue — the posture path cannot reach them — even though the same
  player owns both. `none` selects no cue and has no file.

Do not confuse the two families. A posture clip answers "you are sitting badly, sit up"; a
finish sound answers "this focus block is over". They share a format and nothing else.

The pomodoro's **one-minute warning** (`PomodoroCue.warnBeforeEnd`) is deliberately absent
from this folder: it is a generated two-blip 660 Hz tone built in memory by `ReminderPlayer`,
not a sound anyone chooses, so the recording pass that replaces this folder has nothing to do
with it. Its cue name `warn_before_end` is a log value only — it is not a file name and there
is no `warn_before_end.wav` to look for.

## File naming contract

Two naming rules, one per family:

- A **posture clip** is exactly `<PostureKind.rawValue>.wav`, one per posture that can
  speak (the six non-experimental kinds), and `ReminderPlayer` looks the clip up by that
  name.
- A **finish sound** is exactly `end_<EndSound.rawValue>.wav`: `end_soft.wav` for the
  default calm tone and `end_chime.wav` for the brighter alternative. Those two names are
  also the `PomodoroCue` raw values (`soft` and `chime` are the two `EndSound` cases that
  name a file), and the player looks the clip up by that value. `EndSound.none` has no file,
  because "no sound" is silence, not an asset.

| Family | Purpose | File | Placeholder tone |
|---|---|---|---|
| Posture | reminder for `near` | `near.wav` | C5, 523.25 Hz |
| Posture | reminder for `head_down` | `head_down.wav` | G4, 392.00 Hz |
| Posture | reminder for `head_tilt` | `head_tilt.wav` | A4, 440.00 Hz |
| Posture | reminder for `shoulder_tilt` | `shoulder_tilt.wav` | F4, 349.23 Hz |
| Posture | reminder for `desk_lean` | `desk_lean.wav` | E4, 329.63 Hz |
| Posture | reminder for `chin_rest` | `chin_rest.wav` | D5, 587.33 Hz |
| Finish | pomodoro end sound, `EndSound.soft` (the default) | `end_soft.wav` | one low tone, G3, 196.00 Hz |
| Finish | pomodoro end sound, `EndSound.chime` | `end_chime.wav` | two rising bell notes, G5 783.99 Hz then C6 1046.50 Hz |

The experimental kinds (`head_forward`, `slouch`) have no clip and never reach level 2, so
adding a file for them has no effect. The finish sounds have no posture and are selected by
the `EndSound` setting alone.

The replacement recordings must keep the same file names and extension. If the format ever
changes, `ReminderPlayer.clipExtension` is the single place to change, and every file must change
with it — a missing posture clip is logged as `speech_unavailable` and plays nothing, while a
missing finish sound plays nothing and writes no `cue_played` line.

## Format: WAV, not m4a

The PRD allowed either. WAV is used because the standard library's `wave` module produces it
with no external tool, so the placeholders are reproducible byte for byte on any machine with
Python and no audio dependencies. These are throwaway placeholders, so the larger file size
(about 52 KB each) does not matter; the final recordings may use m4a if the recording pipeline
prefers it.

## Regenerating

All eight files are one deterministic script: no randomness, no third-party audio library, so
a re-run on any machine with Python reproduces the committed bytes exactly.

Every file is 16-bit mono, 22.05 kHz, 1.2 s, at peak amplitude 0.18 of full scale (the peak
sample of every clip is 5898), with a gentle raised-cosine attack and release so nothing
clicks.

- The six **posture** clips are a single sine, 0.12 s attack and 0.30 s release.
- `end_soft` is a single low sine too, but with a slower 0.30 s attack and 0.45 s release —
  the same shape, stretched, so it reads as calmer and lower than any reminder.
- `end_chime` is two overlapping bell notes (a fundamental plus a weak 2nd and 3rd harmonic),
  each with a fast 0.012 s attack and an exponential decay, tapered over the last 0.06 s of
  the note so the note boundaries do not click; the pair is then normalized back to the same
  0.18 peak as everything else. It is deliberately brighter and higher than every posture
  clip.

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
    "shoulder_tilt": 349.23,
    "desk_lean": 329.63,
    "chin_rest": 587.33,
}

frames = int(SAMPLE_RATE * DURATION)

def write_wav(name, samples):
    with wave.open(os.path.join("PostureLab/Resources/Audio", name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(struct.pack("<%dh" % len(samples), *samples))

def sine(freq, attack, release):
    """One sine over the full clip length with a raised-cosine attack and release."""
    out = []
    for i in range(frames):
        t = i / SAMPLE_RATE
        if t < attack:
            env = 0.5 - 0.5 * math.cos(math.pi * t / attack)
        elif t > DURATION - release:
            env = 0.5 - 0.5 * math.cos(math.pi * (DURATION - t) / release)
        else:
            env = 1.0
        out.append(math.sin(2 * math.pi * freq * t) * env)
    return out

# Posture reminders: one sine per speaking posture.
for name, freq in clips.items():
    write_wav(name, [int(round(v * PEAK * 32767)) for v in sine(freq, ATTACK, RELEASE)])

# Pomodoro finish sounds. Not posture reminders; the pomodoro surface alone plays these.
# end_soft: the default calm tone — a low sine with a slower swell than a reminder.
write_wav("end_soft", [int(round(v * PEAK * 32767)) for v in sine(196.00, 0.30, 0.45)])

# end_chime: two bright bell notes, the second overlapping the first, normalized to PEAK.
NOTE_DURATION = 0.75
NOTE_ATTACK = 0.012
NOTE_TAIL = 0.06
DECAY = 0.30

def bell(freq, u):
    if u < 0 or u >= NOTE_DURATION:
        return 0.0
    env = math.exp(-u / DECAY)
    if u < NOTE_ATTACK:
        env *= 0.5 - 0.5 * math.cos(math.pi * u / NOTE_ATTACK)
    tail = NOTE_DURATION - u
    if tail < NOTE_TAIL:
        env *= 0.5 - 0.5 * math.cos(math.pi * tail / NOTE_TAIL)
    return env * (math.sin(2 * math.pi * freq * u)
                  + 0.30 * math.sin(4 * math.pi * freq * u)
                  + 0.10 * math.sin(6 * math.pi * freq * u))

chime = [bell(783.99, i / SAMPLE_RATE) + bell(1046.50, i / SAMPLE_RATE - 0.45)
         for i in range(frames)]
peak = max(abs(v) for v in chime)
write_wav("end_chime", [int(round(v / peak * PEAK * 32767)) for v in chime])
```

`project.yml` includes everything under `PostureLab`, so the files are bundled automatically.
