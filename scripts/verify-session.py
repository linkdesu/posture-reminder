#!/usr/bin/env python3
"""Re-run the QA checks against one PostureLab session log.

Usage:
  scripts/verify-session.py <session.jsonl> [--expect-scenario NAME]
      [--expect-level1 SECONDS] [--expect-level2 SECONDS]
      [--expect-no-reminders] [--quiet]
      [--expect-feature-over FEATURE] [--expect-feature-under FEATURE]
      [--expect-highlight FEATURE] [--expect-features]
      [--expect-view-mode MODE] [--expect-overlay]

The log is the app's own JSONL from the sandbox (Documents/debug/session-*.jsonl).
Everything below is recomputed from that file alone; nothing is taken on trust
from the app. Exit code is 0 when every requested check passes.

Checks:
  P1   every line carries ts, event, state, screen, distance_cm, pitch_deg
  P3   the scenario named in session_started matches --expect-scenario
  AC2  level 1 and level 2 fire at the requested offsets from the first
       sample that breaks the threshold
  AC5  an absence pause appears and its seconds are excluded from the total
  AC6  the five summary numbers in session_ended match the samples
  AC11 no reminder at all (--expect-no-reminders)
  AC13 a view_mode line reports the overlay on when --expect-overlay is given
  AC17 --expect-feature-over / --expect-feature-under read the features lines'
       feature_values and fail loudly when there is no features line to read
  AC18 at least one features line exists, carries highlighted_feature, and
       highlights the requested feature
  P2   no image file sits next to the log: debug screenshots are memory-only
       (ADR-0005), so a PNG in the app's Documents/ is a privacy failure

Every new check fails when its subject is absent: no features or view_mode line
is a failure, never a quiet pass.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

REQUIRED_KEYS = ["ts", "event", "state", "screen", "distance_cm", "pitch_deg"]
IMAGE_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".heic", ".heif", ".tif", ".tiff", ".bmp", ".gif",
    ".webp", ".mp4", ".mov", ".m4v", ".dng", ".raw",
}
SUMMARY_FIELDS = {
    "total_seconds": "total",
    "good_seconds": "good",
    "near_seconds": "near",
    "head_down_seconds": "head_down",
    "longest_good_streak_seconds": "longest_good_streak",
}
# The `alert_type` / `state` vocabulary: `PostureKind.rawValue` in the app.
POSTURE_KINDS = [
    "desk_lean",
    "near",
    "head_forward",
    "slouch",
    "head_down",
    "head_tilt",
    "shoulder_tilt",
    "chin_rest",
]
# The `view_mode` vocabulary.
VIEW_MODES = ["avatar", "board"]


def load(path):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as error:
                sys.exit(f"{path}:{number}: not JSON: {error}")
    if not rows:
        sys.exit(f"{path}: no records")
    return rows


def check_required_keys(rows):
    """P1. This is the check QA turns into an automatic reject."""
    bad = []
    for index, row in enumerate(rows, 1):
        missing = [key for key in REQUIRED_KEYS if key not in row]
        if missing:
            bad.append((index, missing, row.get("event")))
    if bad:
        print(f"P1 FAIL: {len(bad)} line(s) missing required keys")
        for index, missing, event in bad[:10]:
            print(f"   line {index} ({event}): missing {', '.join(missing)}")
        return False
    print(f"P1 PASS: all {len(rows)} lines carry {' '.join(REQUIRED_KEYS)}")
    return True


def timeline(rows):
    print("\n--- timeline (event rows only) ---")
    for row in rows:
        event = row.get("event")
        if event == "sample":
            continue
        bits = [f"t={fmt(row.get('t'))}"]
        for key in ("state", "screen", "alert_type", "level", "breach_seconds"):
            if row.get(key) is not None:
                bits.append(f"{key}={row[key]}")
        for key in ("distance_cm", "pitch_deg"):
            if row.get(key) is not None:
                bits.append(f"{key}={fmt(row[key])}")
        print(f"  {'  '.join(bits)}   [{event}]")


def fmt(value):
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def config_of(rows):
    for row in rows:
        if row.get("event") == "config":
            return row
    return {}


def samples(rows):
    """(t, distance, pitch) for every sample line, in file order."""
    out = []
    for row in rows:
        if row.get("event") == "sample" and row.get("t") is not None:
            out.append((row["t"], row.get("distance_cm"), row.get("pitch_deg")))
    return out


def first_breach(times, predicate):
    for t, distance, pitch in times:
        if predicate(distance, pitch):
            return t
    return None


def check_expected_kind(rows, kind):
    """Without this, a session that fired nothing at all reported AC2 PASS."""
    if kind is None:
        return None
    # `--expect-kind` takes a `PostureKind` rawValue, which is exactly what `alert_type` carries.
    wanted = kind
    ok = True
    for level in (1, 2):
        found = [
            row
            for row in rows
            if row.get("event") == "reminder"
            and row.get("alert_type") == wanted
            and row.get("level") == level
        ]
        if not found:
            print(f"AC2 FAIL: expected a level-{level} {wanted} reminder and the session has none")
            ok = False
    if ok:
        print(f"AC2 PASS: {wanted} produced both reminder levels")
    return ok


def check_expected_sensitivity(rows, expected):
    if expected is None:
        return None
    config = config_of(rows)
    got = config.get("sensitivity")
    table = {"low": (25.0, 25.0), "medium": (30.0, 20.0), "high": (35.0, 15.0)}
    wanted = table[expected]
    actual = (config.get("distance_threshold_cm"), config.get("pitch_threshold_deg"))
    matched = got == expected and actual == wanted
    print(
        f"AC7 {'PASS' if matched else 'FAIL'}: sensitivity={got} thresholds={actual} "
        f"(wanted {expected} {wanted})"
    )
    return matched


def check_timing(rows, args):
    """AC2: the two levels land at the requested offsets from the first breach."""
    if args.expect_level1 is None:
        return True
    config = config_of(rows)
    distance_threshold = config.get("distance_threshold_cm")
    pitch_threshold = config.get("pitch_threshold_deg")
    baseline_pitch = None
    for row in rows:
        if row.get("event") == "calibration_done":
            baseline_pitch = row.get("baseline_pitch_deg")

    def too_close(distance, _pitch):
        return distance is not None and distance_threshold is not None and distance < distance_threshold

    def head_down(_distance, pitch):
        return (
            pitch is not None
            and baseline_pitch is not None
            and pitch_threshold is not None
            and baseline_pitch - pitch > pitch_threshold
        )

    times = samples(rows)
    start_near = first_breach(times, too_close)
    start_down = first_breach(times, head_down)

    ok = True
    fired_any = False
    for kind, start in (("near", start_near), ("head_down", start_down)):
        fired = {
            row["level"]: row["t"]
            for row in rows
            if row.get("event") == "reminder" and row.get("alert_type") == kind
        }
        if not fired:
            continue
        fired_any = True
        if start is None:
            print(f"AC2 FAIL: {kind} reminders fired but no breach was found in the samples")
            ok = False
            continue
        for level, expected in ((1, args.expect_level1), (2, args.expect_level2)):
            if level not in fired or expected is None:
                continue
            delta = fired[level] - start
            verdict = "PASS" if abs(delta - expected) <= 1.0 else "FAIL"
            if verdict == "FAIL":
                ok = False
            print(
                f"AC2 {verdict}: {kind} level {level} at t={fired[level]:.2f}, "
                f"{delta:.2f}s after the breach at t={start:.2f} (wanted {expected:.1f}s +/-1.0)"
            )
    if ok and fired_any:
        print("AC2 PASS (timing)")
    elif ok:
        print("AC2 INFO: no reminder fired here; --expect-kind is what requires one")
    return ok


def check_no_reminders(rows):
    reminders = [row for row in rows if row.get("event") == "reminder"]
    if reminders:
        print(f"AC11 FAIL: {len(reminders)} reminder(s) fired:")
        for row in reminders:
            print(f"   t={fmt(row.get('t'))} {row.get('alert_type')} level {row.get('level')}")
        return False
    print("AC11 PASS: no reminder events")
    return True


def check_pause(rows, required=False):
    """AC5: a pause happens and the absent seconds stay out of the total."""
    paused = [row for row in rows if row.get("event") == "paused"]
    times = samples(rows)
    absent = 0.0
    for (t0, d0, p0), (t1, _d1, _p1) in zip(times, times[1:]):
        if d0 is None or p0 is None:
            absent += t1 - t0
    if not paused:
        if required:
            print(f"AC5 FAIL: this scenario should have paused, and no paused event exists ({absent:.1f}s absent)")
            return False
        if absent > 0:
            print(f"AC5 FAIL: {absent:.1f}s with no face but no paused event")
            return False
        print("AC5 SKIP: no absence in this session")
        return True
    print(
        f"AC5 PASS: {len(paused)} paused event(s), first at t={fmt(paused[0].get('t'))}, "
        f"{absent:.1f}s excluded from the total"
    )
    return True


def status_timeline(rows):
    """(t, state) for every `status_changed` line, in file order.

    The engine starts on `good` and only logs a change away from it, so a session in no posture at
    all has no `status_changed` line and the state stays `good` throughout.
    """
    out = []
    for row in rows:
        if row.get("event") == "status_changed" and row.get("t") is not None:
            out.append((row["t"], row.get("state")))
    return out


def recompute(rows, rows_times, config, baseline_pitch):
    distance_threshold = config.get("distance_threshold_cm")
    pitch_threshold = config.get("pitch_threshold_deg")
    total = near = head_down = 0.0
    # `good` and the good streak come from the event timeline rather than the two-threshold rule
    # below, so this check does not repeat the engine's own arithmetic back at it. The engine earns
    # good time whenever the face is present and nothing breaches at all, which is what its
    # `status == .good` means; the old mirrored rule knew only `near` and `head_down` and so agreed
    # with a wrong `good_seconds` on every session in one of the five newer postures.
    good = 0.0
    streak = longest = 0.0
    states = status_timeline(rows)
    state_index = 0
    state = "good"
    for (t0, d0, p0), (t1, _d1, _p1) in zip(rows_times, rows_times[1:]):
        # The state in force over [t0, t1] is the last change logged at or before t0.
        while state_index < len(states) and states[state_index][0] <= t0:
            state = states[state_index][1]
            state_index += 1
        dt = t1 - t0
        if d0 is None or p0 is None:
            # No face over this interval: the engine credits paused time, and a pause neither adds
            # to nor resets the good streak.
            continue
        total += dt
        is_near = distance_threshold is not None and d0 < distance_threshold
        is_down = (
            baseline_pitch is not None
            and pitch_threshold is not None
            and baseline_pitch - p0 > pitch_threshold
        )
        if is_near:
            near += dt
        if is_down:
            head_down += dt
        if state == "good":
            good += dt
            streak += dt
            longest = max(longest, streak)
        else:
            streak = 0.0
    return {
        "total": total,
        "good": good,
        "near": near,
        "head_down": head_down,
        "longest_good_streak": longest,
    }


def check_summary(rows):
    """AC6: the numbers on the summary screen equal what the log supports."""
    ended = None
    for row in rows:
        if row.get("event") == "session_ended":
            ended = row
    if ended is None:
        print("AC6 FAIL: no session_ended record")
        return False
    config = config_of(rows)
    baseline_pitch = None
    for row in rows:
        if row.get("event") == "calibration_done":
            baseline_pitch = row.get("baseline_pitch_deg")
    reported = recompute(rows, samples(rows), config, baseline_pitch)
    ok = True
    for key, label in SUMMARY_FIELDS.items():
        claimed = ended.get(key)
        got = reported[label]
        if claimed is None:
            print(f"AC6 FAIL: session_ended has no {key}")
            ok = False
            continue
        delta = abs(claimed - got)
        verdict = "PASS" if delta <= 1.0 else "FAIL"
        if verdict == "FAIL":
            ok = False
        print(f"AC6 {verdict}: {key}: log says {claimed:.2f}, samples give {got:.2f} (delta {delta:.2f})")
    for kind in ("near", "head_down"):
        counted = len(
            [
                row
                for row in rows
                if row.get("event") == "reminder"
                and row.get("level") == 1
                and row.get("alert_type") == kind
            ]
        )
        print(f"AC6 INFO: level-1 {kind} reminder lines in the log={counted}")
    if ended.get("near_count") is not None:
        print(f"AC6 INFO: session_ended near_count={ended.get('near_count')}")
    return ok


def check_no_images(log_path):
    documents = os.path.dirname(os.path.dirname(os.path.abspath(log_path)))
    images = []
    for base, _dirs, files in os.walk(documents):
        for name in files:
            if os.path.splitext(name)[1].lower() in IMAGE_SUFFIXES:
                images.append(os.path.relpath(os.path.join(base, name), documents))
    if images:
        print(f"P2 FAIL: {documents} holds image file(s): {', '.join(sorted(images))}")
        return False
    print(f"P2 PASS: no image file under {documents}; debug screenshots stay in memory")
    return True


def event_lines(rows, event):
    return [row for row in rows if row.get("event") == event]


def feature_over(row, feature):
    """The `over` flag for one feature on one `features` line, or None if the line does not read it."""
    values = row.get("feature_values")
    if not isinstance(values, dict):
        return None
    entry = values.get(feature)
    if not isinstance(entry, dict):
        return None
    return entry.get("over")


def check_feature_over(rows, feature):
    """AC17/AC18 (experimental positives): the feature must read over threshold on the features lines."""
    lines = event_lines(rows, "features")
    if not lines:
        print(f"AC18 FAIL: no features lines in this log, so nothing can report {feature} over threshold")
        return False
    over = [row for row in lines if feature_over(row, feature) is True]
    if not over:
        print(f"AC18 FAIL: {len(lines)} features line(s) and none reports {feature} over threshold")
        return False
    print(f"AC18 PASS: {feature} reads over threshold on {len(over)} of {len(lines)} features line(s)")
    return True


def check_feature_under(rows, feature):
    """AC17 counter-examples: no features line may report the feature over threshold."""
    lines = event_lines(rows, "features")
    if not lines:
        print(f"AC17 FAIL: no features lines in this log, so nothing can show {feature} staying under threshold")
        return False
    readings = [feature_over(row, feature) for row in lines]
    present = [flag for flag in readings if flag is not None]
    if not present:
        print(f"AC17 FAIL: {len(lines)} features line(s) and none reads {feature}, so its staying under is unproven")
        return False
    over = sum(1 for flag in present if flag is True)
    if over:
        print(f"AC17 FAIL: {feature} went over threshold on {over} of {len(present)} features line(s) that read it")
        return False
    print(f"AC17 PASS: {feature} stayed under threshold on all {len(present)} features line(s) that read it")
    return True


def check_highlight(rows, feature):
    """AC18: at least one features line highlights the requested feature."""
    lines = event_lines(rows, "features")
    if not lines:
        print(f"AC18 FAIL: no features lines in this log, so nothing can carry highlighted_feature {feature}")
        return False
    matching = [row for row in lines if row.get("highlighted_feature") == feature]
    if not matching:
        seen = sorted({str(row.get("highlighted_feature")) for row in lines})
        print(f"AC18 FAIL: no features line highlights {feature} (saw {', '.join(seen)})")
        return False
    print(f"AC18 PASS: {feature} is highlighted on {len(matching)} of {len(lines)} features line(s)")
    return True


def check_features_log(rows):
    """AC18, machine form: at least one features line exists and every one carries highlighted_feature."""
    lines = event_lines(rows, "features")
    if not lines:
        print("AC18 FAIL: no features lines in this log, so which feature is highlighted is unrecorded")
        return False
    missing = [index for index, row in enumerate(lines, 1) if "highlighted_feature" not in row]
    if missing:
        print(f"AC18 FAIL: {len(missing)} of {len(lines)} features line(s) do not carry the highlighted_feature key")
        return False
    print(f"AC18 PASS: {len(lines)} features line(s), each carrying highlighted_feature")
    return True


def check_view_mode(rows, mode, expect_overlay):
    """AC13: a view_mode line reports the requested mode, and the overlay when --expect-overlay is set."""
    lines = event_lines(rows, "view_mode")
    if not lines:
        print(f"AC13 FAIL: no view_mode lines in this log, so the view mode cannot be confirmed (wanted {mode})")
        return False
    matching = [row for row in lines if row.get("view_mode") == mode]
    if not matching:
        seen = sorted({str(row.get("view_mode")) for row in lines})
        print(f"AC13 FAIL: no view_mode line says {mode} (saw {', '.join(seen)})")
        return False
    if expect_overlay and not any(row.get("overlay_on") is True for row in matching):
        print(f"AC13 FAIL: view_mode {mode} lines exist but none reports overlay_on true")
        return False
    print(f"AC13 PASS: view_mode={mode} present on {len(matching)} line(s)")
    return True


def check_overlay_evidence(rows):
    """AC13: the log reports the overlay on.

    Whether the overlay is *visibly drawn* is a human check on the screen, not something
    this script can read out of the file — and the app no longer writes a screenshot to
    read it from (ADR-0005).
    """
    lines = event_lines(rows, "view_mode")
    if not lines:
        print("AC13 FAIL: no view_mode lines in this log, so the overlay cannot be confirmed on")
        return False
    if not any(row.get("overlay_on") is True for row in lines):
        print("AC13 FAIL: no view_mode line reports overlay_on true")
        return False
    print("AC13 PASS: a view_mode line reports overlay_on true")
    print("AC13 HUMAN: whether the overlay is visibly drawn is a human check on the screen itself")
    return True


def paused_intervals(rows):
    """(start, end) for every pause, the last one running to the final sample."""
    times = samples(rows)
    session_end = times[-1][0] if times else None
    out = []
    start = None
    for row in rows:
        if row.get("event") == "paused":
            start = row.get("t")
        elif row.get("event") == "resumed" and start is not None:
            out.append((start, row.get("t")))
            start = None
    if start is not None and session_end is not None:
        out.append((start, session_end))
    return out


def check_no_reminders_during_pause(rows, required):
    """AC20. A reminder while the session is paused is a hard failure."""
    if not required:
        return None
    windows = paused_intervals(rows)
    if not windows:
        print("AC20 FAIL: no paused interval in this session, so the claim cannot be checked")
        return False
    offenders = [
        row
        for row in rows
        if row.get("event") == "reminder"
        and any(start <= (row.get("t") or -1) <= end for start, end in windows)
    ]
    if offenders:
        print(f"AC20 FAIL: {len(offenders)} reminder(s) fired inside a pause")
        for row in offenders[:5]:
            print(f"   t={fmt(row.get('t'))} {row.get('alert_type')} level {row.get('level')}")
        return False
    print(f"AC20 PASS: {len(windows)} pause window(s), zero reminders inside them")
    return True


def check_breach_invariant(rows):
    """A reminder can only fire once its breach has actually lasted long enough."""
    levels = {1: 5.0, 2: 15.0}
    bad = []
    for row in rows:
        if row.get("event") != "reminder":
            continue
        level = row.get("level")
        breach = row.get("breach_seconds")
        if level not in levels or breach is None:
            bad.append(row)
            continue
        if breach < levels[level] - 1.0:
            bad.append(row)
    if bad:
        print(f"FAIL: {len(bad)} reminder(s) report a breach shorter than their level requires")
        for row in bad[:5]:
            print(
                f"   t={fmt(row.get('t'))} {row.get('alert_type')} level {row.get('level')} "
                f"breach_seconds={fmt(row.get('breach_seconds'))}"
            )
        return False
    return True


def check_not_good_after_resume(rows, required):
    """AC21. Coming back from a pause is recomputed from the sample, never assumed good."""
    if not required:
        return None
    resumes = [row.get("t") for row in rows if row.get("event") == "resumed"]
    if not resumes:
        print("AC21 FAIL: no resume in this session, so the claim cannot be checked")
        return False
    states = [(row.get("t"), row.get("state")) for row in rows if row.get("event") == "status_changed"]
    bad = []
    for resume in resumes:
        after = [state for t, state in states if t is not None and t >= resume]
        if after and after[0] == "good":
            bad.append(resume)
    if bad:
        print(f"AC21 FAIL: {len(bad)} resume(s) landed on a forced good state")
        return False
    print(f"AC21 PASS: {len(resumes)} resume(s), none assumed good")
    return True


def check_posture_stats(rows):
    """AC22. The per-posture counters must be present and agree with the reminder lines."""
    ended = next((row for row in rows if row.get("event") == "session_ended"), None)
    if ended is None:
        print("AC22 FAIL: no session_ended record")
        return False
    stats = ended.get("posture_stats")
    if not isinstance(stats, dict) or not stats:
        print("AC22 FAIL: session_ended carries no posture_stats object")
        return False
    voicing = ["near", "head_down", "head_tilt", "desk_lean", "chin_rest"]
    missing = [kind for kind in voicing if kind not in stats]
    if missing:
        print(f"AC22 FAIL: posture_stats is missing {', '.join(missing)}")
        return False
    ok = True
    for kind in voicing:
        entry = stats[kind]
        lines = [row for row in rows if row.get("event") == "reminder" and row.get("alert_type") == kind]
        level1 = [row for row in lines if row.get("level") == 1]
        if entry.get("reminders") != len(lines):
            print(f"AC22 FAIL: {kind} reminders={entry.get('reminders')} but the log has {len(lines)} line(s)")
            ok = False
        if entry.get("episodes") != len(level1):
            print(f"AC22 FAIL: {kind} episodes={entry.get('episodes')} but the log has {len(level1)} level-1 line(s)")
            ok = False
        seconds = entry.get("seconds")
        if seconds is None or seconds < 0:
            print(f"AC22 FAIL: {kind} seconds={seconds}")
            ok = False
    for kind, flat in (("near", "near_seconds"), ("head_down", "head_down_seconds")):
        if kind in stats and ended.get(flat) is not None:
            if abs(stats[kind]["seconds"] - ended[flat]) > 0.01:
                print(f"AC22 FAIL: posture_stats.{kind}.seconds={stats[kind]['seconds']} but {flat}={ended[flat]}")
                ok = False
    if ok:
        print(f"AC22 PASS: posture_stats present for all 5 voicing postures and consistent with the log")
    return ok


def check_overlay_off(rows, required):
    """AC24. With debug off, no line may claim the overlay is on."""
    if not required:
        return None
    on = [row for row in rows if row.get("event") == "view_mode" and row.get("overlay_on") is True]
    if on:
        print(f"AC24 FAIL: {len(on)} view_mode line(s) report the overlay on while debug is off")
        return False
    modes = [row for row in rows if row.get("event") == "view_mode"]
    if not modes:
        print("AC24 FAIL: no view_mode line, so the overlay state is unrecorded")
        return False
    print("AC24 PASS: overlay reported off for the whole session")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log")
    parser.add_argument("--expect-scenario")
    parser.add_argument("--expect-level1", type=float)
    parser.add_argument("--expect-level2", type=float)
    parser.add_argument("--expect-no-reminders", action="store_true")
    parser.add_argument("--expect-near-reminders", type=int)
    parser.add_argument("--expect-kind", choices=POSTURE_KINDS)
    parser.add_argument("--expect-sensitivity", choices=["low", "medium", "high"])
    parser.add_argument("--expect-pause", action="store_true")
    parser.add_argument("--expect-feature-over")
    parser.add_argument("--expect-feature-under")
    parser.add_argument("--expect-highlight")
    parser.add_argument("--expect-features", action="store_true")
    parser.add_argument("--expect-view-mode", choices=VIEW_MODES)
    parser.add_argument("--expect-overlay", action="store_true")
    parser.add_argument("--expect-overlay-off", action="store_true")
    parser.add_argument("--expect-no-reminders-during-pause", action="store_true")
    parser.add_argument("--expect-not-good-after-resume", action="store_true")
    parser.add_argument("--expect-posture-stats", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    rows = load(args.log)
    print(f"{args.log}: {len(rows)} records")

    results = [check_required_keys(rows)]

    started = next((row for row in rows if row.get("event") == "session_started"), {})
    scenario = started.get("scenario")
    if args.expect_scenario:
        matched = scenario == args.expect_scenario
        print(f"P3 {'PASS' if matched else 'FAIL'}: scenario={scenario or '(camera)'} (wanted {args.expect_scenario})")
        results.append(matched)
    elif scenario:
        print(f"P3 INFO: scenario={scenario}")

    if not args.quiet:
        timeline(rows)

    if args.expect_no_reminders:
        results.append(check_no_reminders(rows))
    for extra in (check_expected_kind(rows, args.expect_kind), check_expected_sensitivity(rows, args.expect_sensitivity)):
        if extra is not None:
            results.append(extra)
    if args.expect_near_reminders is not None:
        near = [row for row in rows if row.get("event") == "reminder" and row.get("alert_type") == "near"]
        matched = len(near) == args.expect_near_reminders
        print(
            f"AC3 {'PASS' if matched else 'FAIL'}: {len(near)} near reminder(s), "
            f"wanted {args.expect_near_reminders}"
        )
        results.append(matched)
    results.append(check_pause(rows, required=args.expect_pause))
    results.append(check_breach_invariant(rows))
    for extra in (
        check_no_reminders_during_pause(rows, args.expect_no_reminders_during_pause),
        check_not_good_after_resume(rows, args.expect_not_good_after_resume),
        check_posture_stats(rows) if args.expect_posture_stats else None,
        check_overlay_off(rows, args.expect_overlay_off),
    ):
        if extra is not None:
            results.append(extra)
    results.append(check_timing(rows, args))
    results.append(check_summary(rows))
    results.append(check_no_images(args.log))

    if args.expect_feature_over:
        results.append(check_feature_over(rows, args.expect_feature_over))
    if args.expect_feature_under:
        results.append(check_feature_under(rows, args.expect_feature_under))
    if args.expect_highlight:
        results.append(check_highlight(rows, args.expect_highlight))
    if args.expect_features:
        results.append(check_features_log(rows))
    if args.expect_view_mode:
        results.append(check_view_mode(rows, args.expect_view_mode, args.expect_overlay))
    if args.expect_overlay:
        results.append(check_overlay_evidence(rows))

    print("\nRESULT:", "PASS" if all(results) else "FAIL")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
