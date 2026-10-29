#!/usr/bin/env python3
"""Re-run one v0.5 pomodoro acceptance check against the evidence a run left behind.

Usage:
  scripts/verify-acceptance.py <session.jsonl> [--history PATH]
      --ac1 | --ac4 | --ac5 | --ac7 [--quiet]

The log is the app's own JSONL from the sandbox (Documents/debug/session-*.jsonl); the
history is Documents/pomodoro-history.json, which is the log directory's sibling unless
--history says otherwise. Everything below is recomputed from those files alone. Exactly
one mode runs per invocation, it prints an explicit `ACn PASS` or `ACn FAIL` line, and the
exit code is non-zero unless every assertion in that mode holds.

Checks:
  AC1  the countdown never stopped: every pair of `pomodoro_tick` lines falls by the
       gap on the shared `ts` clock within half a second, with no `paused` event between
       them (the tick carries no `t`; `ts` is the instant the app's own note says to read)
  AC4  one clip at a time: no two `speech_played` clips overlap, and the plays of the
       several kinds queued on one tick follow `PostureKind.priority`
  AC5  a pause is not focus time: `focusedSeconds + pausedSeconds` equals the record's
       elapsed wall time within a second, and at least one record reports a pause
  AC7  every focus's timeline accounts for the time that focus counted: the non-paused
       `postureSegments` runs add up to its `focusedSeconds` within a second, every run is a
       legal kind, and the day still holds the `pomodoroDay` scenario's three one-minute
       focuses

Every check fails when its subject is missing: fewer than two ticks, no playback, no
simultaneous queue, no history, no paused record, or no segment is a failure, never a
quiet pass.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# `PostureKind.priority` in PostureKind.swift; lower wins. A voice queue sorts by this.
POSTURE_PRIORITY = {
    "desk_lean": 1,
    "near": 2,
    "head_forward": 3,
    "slouch": 4,
    "head_down": 5,
    "head_tilt": 6,
    "shoulder_tilt": 7,
    "chin_rest": 8,
}

# Every bundled placeholder clip is 1.2s (PostureLab/Resources/Audio/README.md). The player
# logs a clip where it starts and never logs its end, so this is what "overlap" can be read
# against; the slack absorbs the logger's millisecond jitter.
CLIP_SECONDS = 1.2
CLOCK_TOLERANCE = 0.05

# AC1 allows the countdown to differ from the gap on the shared clock by half a second.
TICK_TOLERANCE = 0.5
# AC5 and AC7 are stated to a second.
SECOND_TOLERANCE = 1.0

# The `pomodoroDay` scenario: three one-minute focuses. Their timelines are no longer three runs
# each — v0.6 opens a `detecting` band at the 开始 tap and v0.6.1 a `no_data` band when the stream
# stalls — so AC7 checks each timeline's total against the focus, not its shape.
FOCUS_SECONDS = 60.0
FOCUS_COUNT = 3

# `PostureSegment.kind`: the eight postures (`PostureKind.priority` names all of them), the two
# states, the pause band (B2), and the two non-posture bands v0.6/v0.6.1 added.
SEGMENT_KINDS = set(POSTURE_PRIORITY) | {"good", "no_person", "paused", "detecting", "no_data"}


def fmt(value):
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def show(quiet, text=""):
    """A narrative line: what the evidence actually holds. `--quiet` drops these, the way
    the other verifiers do; the PASS/FAIL verdicts and their numbers are printed either way."""
    if not quiet:
        print(text)


def number(value):
    """A JSON number, or None. Booleans are not numbers here, whatever Python thinks."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def load_log(path, mode):
    """The session log's rows, in file order. A missing file is a hard failure: this mode
    exists to read evidence, so nothing to read is the same as the evidence being absent."""
    if not os.path.exists(path):
        sys.exit(f"{mode} FAIL: no session log at {path}")
    rows = []
    with open(path, encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as error:
                sys.exit(f"{mode} FAIL: {path}:{line_number}: not JSON: {error}")
    if not rows:
        sys.exit(f"{mode} FAIL: {path} holds no records, so it carries no evidence")
    return rows


def default_history_path(log_path):
    """`Documents/debug/session-*.jsonl` -> `Documents/pomodoro-history.json`."""
    log_directory = os.path.dirname(os.path.abspath(log_path))
    return os.path.join(os.path.dirname(log_directory), "pomodoro-history.json")


def load_history(path, mode):
    """The stored pomodoro records. Missing, unreadable or empty is a hard failure: the
    history is the only evidence AC5 and AC7 have."""
    if not os.path.exists(path):
        sys.exit(f"{mode} FAIL: no pomodoro history at {path}")
    try:
        with open(path, encoding="utf-8") as handle:
            stored = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        sys.exit(f"{mode} FAIL: {path} is not readable JSON: {error}")
    if not isinstance(stored, list):
        sys.exit(f"{mode} FAIL: {path} holds a {type(stored).__name__}, not a list of records")
    records = [record for record in stored if isinstance(record, dict)]
    if len(records) != len(stored):
        sys.exit(f"{mode} FAIL: {len(stored) - len(records)} entry/entries in {path} are not records")
    if not records:
        sys.exit(f"{mode} FAIL: {path} holds no pomodoro record, so it carries no evidence")
    return records


def instant(row):
    """The wall-clock instant of one log line, in seconds, or None.

    Every line carries `ts` (docs/qa-log-schema.md), which is what a `pomodoro_tick` or a
    `speech_played` line has instead of a session `t`. That makes `ts` the one clock every
    line shares, and the one a screenshot's timestamp can be compared with; the app's own
    note on the tick says its countdown falls in step with the `ts` gap between two lines.
    """
    ts = number(row.get("ts"))
    if ts is None:
        return None
    return ts / 1000.0


def session_origin(rows):
    """(ts seconds, t) of the first sample line, so a tick's session time can be printed."""
    for row in rows:
        if row.get("event") != "sample":
            continue
        ts = number(row.get("ts"))
        t = number(row.get("t"))
        if ts is not None and t is not None:
            return (ts / 1000.0, t)
    return None


def session_time(row, origin):
    """The session-clock `t` for one line, or None.

    Only used to print a human-readable position beside the wall clock; the checks compare
    the shared `ts` clock. A line that carries `t` reports it; a tick or a play is placed by
    its offset from the first sample.
    """
    t = number(row.get("t"))
    if t is not None:
        return t
    seconds = instant(row)
    if seconds is None or origin is None:
        return None
    base_seconds, base_t = origin
    return base_t + (seconds - base_seconds)


def event_lines(rows, event):
    return [row for row in rows if row.get("event") == event]


def check_ac1(rows, quiet):
    """AC1: the countdown is a continuous series, not a value the app restarted."""
    ticks = event_lines(rows, "pomodoro_tick")
    origin = session_origin(rows)
    readable = []
    for index, row in enumerate(ticks, 1):
        when = instant(row)
        remaining = number(row.get("remaining_seconds"))
        if when is None or remaining is None:
            print(
                f"AC1 FAIL: pomodoro_tick line {index} carries "
                f"{'no ts' if when is None else ''}"
                f"{' and ' if when is None and remaining is None else ''}"
                f"{'no remaining_seconds' if remaining is None else ''}"
            )
            return False
        readable.append((when, remaining, row.get("phase"), row))

    if len(readable) < 2:
        print(
            f"AC1 FAIL: the log holds {len(readable)} readable pomodoro_tick line(s); "
            f"a countdown needs at least two to show it kept falling"
        )
        return False

    first = readable[0]
    last = readable[-1]
    print(
        f"AC1 INFO: first tick at t={fmt(session_time(first[3], origin))}s "
        f"ts={first[3].get('wall_clock')} remaining_seconds={fmt(first[1])}"
    )
    print(
        f"AC1 INFO: last tick at t={fmt(session_time(last[3], origin))}s "
        f"ts={last[3].get('wall_clock')} remaining_seconds={fmt(last[1])}"
    )

    pauses = []
    for row in event_lines(rows, "paused"):
        when = instant(row)
        if when is not None:
            pauses.append((when, row))

    ok = True
    compared = 0
    for previous, current in zip(readable, readable[1:]):
        t0, remaining0, phase0, row0 = previous
        t1, remaining1, phase1, row1 = current
        position0 = session_time(row0, origin)
        position1 = session_time(row1, origin)
        gap = t1 - t0
        if gap <= 0:
            print(
                f"AC1 FAIL: the tick clock did not advance: t={fmt(position0)}s then "
                f"t={fmt(position1)}s"
            )
            ok = False
            continue

        between = [item for item in pauses if t0 < item[0] < t1]
        if between:
            when, row = between[0]
            print(
                f"AC1 FAIL: a paused event at t={fmt(session_time(row, origin))}s "
                f"(ts={row.get('wall_clock')}) sits between ticks t={fmt(position0)}s "
                f"and t={fmt(position1)}s"
            )
            ok = False

        if phase0 != phase1:
            show(
                quiet,
                f"AC1 INFO: phase changes from {phase0} to {phase1} at t={fmt(position1)}s; "
                "the countdown restarts there",
            )
            continue

        compared += 1
        fell = remaining0 - remaining1
        delta = abs(fell - gap)
        verdict = "PASS" if delta <= TICK_TOLERANCE else "FAIL"
        if verdict == "FAIL":
            ok = False
            print(
                f"AC1 FAIL: t={fmt(position0)}..{fmt(position1)}s is a {gap:.2f}s gap but the "
                f"countdown fell {fell:.2f}s ({remaining0:.2f} -> {remaining1:.2f}, "
                f"delta {delta:.2f}s)"
            )
        else:
            show(
                quiet,
                f"AC1 PASS: t={fmt(position0)}..{fmt(position1)}s gap {gap:.2f}s, countdown "
                f"{remaining0:.2f} -> {remaining1:.2f} ({delta:.2f}s off)",
            )

    if compared == 0:
        print("AC1 FAIL: every tick is in a phase of its own, so no countdown was shown falling")
        ok = False
    if ok:
        print(
            f"AC1 PASS: {len(readable)} tick(s), {compared} consecutive pair(s) fall with the "
            f"shared clock within {TICK_TOLERANCE:.1f}s, with no pause between them"
        )
    return ok


def pair_playbacks(rows):
    """Pair each `speech_played` line with the reminder that queued it.

    Reminders and plays share the log's file order, so per kind the earliest unplayed
    reminder is the one a play belongs to. A play with no matching reminder is still
    returned; its priority simply cannot be attributed to a queue tick.
    """
    pending = {}
    pairs = []
    for row in rows:
        event = row.get("event")
        if event == "reminder" and row.get("level") == 2:
            kind = row.get("alert_type")
            pending.setdefault(kind, []).append(row)
        elif event == "speech_played":
            kind = row.get("alert_type")
            queue = pending.get(kind) or []
            reminder = queue.pop(0) if queue else None
            pairs.append((row, reminder))
    return pairs


def check_ac4(rows, quiet):
    """AC4: one clip at a time, queued by `PostureKind.priority`."""
    plays = event_lines(rows, "speech_played")
    if not plays:
        print("AC4 FAIL: the log holds no speech_played line, so no clip is proven to have played")
        return False
    if len(plays) < 2:
        print(
            f"AC4 FAIL: the log holds only {len(plays)} speech_played line(s); "
            "one-at-a-time playback needs at least two to be shown"
        )
        return False

    origin = session_origin(rows)
    timed = []
    for index, row in enumerate(plays, 1):
        when = instant(row)
        kind = row.get("alert_type")
        if when is None or kind is None:
            print(
                f"AC4 FAIL: speech_played line {index} carries "
                f"{'no timestamp' if when is None else 'no alert_type'}"
            )
            return False
        timed.append((when, kind, row))

    pauses = []
    for row in event_lines(rows, "paused"):
        when = instant(row)
        if when is not None:
            pauses.append((when, row))

    ok = True
    for previous, current in zip(timed, timed[1:]):
        gap = current[0] - previous[0]
        position0 = session_time(previous[2], origin)
        position1 = session_time(current[2], origin)
        if gap < CLIP_SECONDS - CLOCK_TOLERANCE:
            between = [item for item in pauses if previous[0] < item[0] < current[0]]
            if between:
                when, row = between[0]
                show(
                    quiet,
                    f"AC4 INFO: a pause at t={fmt(session_time(row, origin))}s "
                    f"(ts={row.get('wall_clock')}) stopped the {previous[1]} clip before the "
                    f"{current[1]} clip started {gap:.2f}s later",
                )
                continue
            print(
                f"AC4 FAIL: the {previous[1]} clip starts at t={fmt(position0)}s and the "
                f"{current[1]} clip at t={fmt(position1)}s, {gap:.2f}s later, inside the "
                f"{CLIP_SECONDS:.2f}s clip"
            )
            ok = False
        else:
            show(
                quiet,
                f"AC4 PASS: {previous[1]} at t={fmt(position0)}s then {current[1]} at "
                f"t={fmt(position1)}s, {gap:.2f}s apart, no overlap",
            )

    # Several kinds emitted on one tick are all queued at the same instant, so their plays
    # have to come out in priority order. A kind that arrived during a clip can legitimately
    # jump the queue, so only same-tick groups are compared.
    groups = {}
    for row, reminder in pair_playbacks(rows):
        if reminder is None:
            continue
        tick = number(reminder.get("t"))
        kind = row.get("alert_type")
        if tick is None or kind is None:
            continue
        groups.setdefault(round(tick, 3), []).append(kind)

    compared = 0
    for tick, kinds in sorted(groups.items()):
        if len({kind for kind in kinds if kind in POSTURE_PRIORITY}) < 2:
            continue
        compared += 1
        previous_priority = None
        for kind in kinds:
            priority = POSTURE_PRIORITY.get(kind)
            if priority is None:
                print(f"AC4 FAIL: queued kind {kind} has no PostureKind priority")
                ok = False
                continue
            if previous_priority is not None and priority < previous_priority:
                print(
                    f"AC4 FAIL: at t={fmt(tick)} the queue played {kind} (priority {priority}) "
                    f"after a lower-priority kind (priority {previous_priority})"
                )
                ok = False
            previous_priority = priority
        show(
            quiet,
            f"AC4 PASS: t={fmt(tick)} queued {', '.join(kinds)}; playback followed priority "
            f"{' < '.join(str(POSTURE_PRIORITY[kind]) for kind in kinds)}",
        )

    if compared == 0:
        print(
            "AC4 FAIL: no tick queued two voice kinds at once, so priority order is unproven"
        )
        ok = False
    if ok:
        print(
            f"AC4 PASS: {len(timed)} clip(s) played one at a time, and {compared} simultaneous "
            f"queue(s) followed PostureKind.priority"
        )
    return ok


def check_ac5(records, quiet):
    """AC5: a pause is time outside the focus clock, and the record says how much."""
    ok = True
    paused_records = 0
    for index, record in enumerate(records, 1):
        focused = number(record.get("focusedSeconds"))
        paused = number(record.get("pausedSeconds"))
        started = number(record.get("startedAt"))
        ended = number(record.get("endedAt"))
        if focused is None or paused is None or started is None or ended is None:
            print(
                f"AC5 FAIL: record {index} is missing "
                f"{'focusedSeconds ' if focused is None else ''}"
                f"{'pausedSeconds ' if paused is None else ''}"
                f"{'startedAt ' if started is None else ''}"
                f"{'endedAt' if ended is None else ''}".rstrip()
            )
            ok = False
            continue
        if paused > 0:
            paused_records += 1
        elapsed = ended - started
        total = focused + paused
        delta = abs(total - elapsed)
        verdict = "PASS" if delta <= SECOND_TOLERANCE else "FAIL"
        if verdict == "FAIL":
            ok = False
        line = (
            f"AC5 {verdict}: record {index} focusedSeconds={focused:.2f} + "
            f"pausedSeconds={paused:.2f} = {total:.2f}s against an elapsed "
            f"{elapsed:.2f}s (delta {delta:.2f}s)"
        )
        if verdict == "FAIL":
            print(line)
        else:
            show(quiet, line)

    if paused_records == 0:
        print("AC5 FAIL: no record reports pausedSeconds > 0, so the pause evidence is missing")
        ok = False
    if ok:
        print(
            f"AC5 PASS: {len(records)} record(s) account for their wall time with "
            f"focused+paused; {paused_records} record(s) report a pause"
        )
    return ok


def record_segments(record):
    """The record's timeline as (kind, start, end) runs, in time order; None when unreadable."""
    stored = record.get("postureSegments")
    if not isinstance(stored, list):
        return None
    windows = []
    for segment in stored:
        if not isinstance(segment, dict):
            return None
        kind = segment.get("kind")
        start = number(segment.get("start"))
        end = number(segment.get("end"))
        if kind is None or start is None or end is None or end < start:
            return None
        windows.append((kind, start, end))
    windows.sort(key=lambda window: window[1])
    return windows


def check_ac7(records, quiet):
    """AC7: every focus's timeline accounts for the time that focus counted.

    A focus used to be exactly three runs, which is why the script's fifteen/thirty/fifteen used to
    be read position by position. v0.6 opens a `detecting` band at the 开始 tap and v0.6.1 a
    `no_data` band when the stream stalls, so a real focus is however many runs the session needed.
    What the timeline still owes the parent is the whole 专注时长: the non-paused runs add up to
    `focusedSeconds` within a second — a pause is wall time outside the countdown and has a band of
    its own — and every run is a legal kind. The day itself is still the scenario's three
    one-minute focuses.
    """
    if len(records) != FOCUS_COUNT:
        print(
            f"AC7 FAIL: the history holds {len(records)} record(s); the pomodoroDay scenario "
            f"produces {FOCUS_COUNT} focuses, so its timeline is incomplete"
        )
        return False

    ok = True
    for index, record in enumerate(records, 1):
        planned = number(record.get("plannedSeconds"))
        focus_index = number(record.get("focusIndex"))
        if planned is None or abs(planned - FOCUS_SECONDS) > SECOND_TOLERANCE:
            print(
                f"AC7 FAIL: record {index} planned {fmt(planned)}s; the pomodoroDay focus "
                f"is {FOCUS_SECONDS:.0f}s"
            )
            ok = False
            continue
        if focus_index is None or focus_index < 1:
            print(f"AC7 FAIL: record {index} has no readable focusIndex")
            ok = False
            continue

        runs = record_segments(record)
        if runs is None or not runs:
            print(f"AC7 FAIL: record {index} carries no readable postureSegments")
            ok = False
            continue

        focused = number(record.get("focusedSeconds"))
        if focused is None:
            print(f"AC7 FAIL: record {index} has no readable focusedSeconds to add up to")
            ok = False
            continue

        unknown = sorted({kind for kind, _start, _end in runs if kind not in SEGMENT_KINDS})
        if unknown:
            print(
                f"AC7 FAIL: record {index} segment kind(s) {', '.join(unknown)} "
                f"outside the vocabulary"
            )
            ok = False

        show(quiet, f"\n--- record {index}: focus {int(focus_index)}, {len(runs)} run(s) ---")
        for position, (kind, start, end) in enumerate(runs, 1):
            show(quiet, f"  {position}. {kind} {end - start:.2f}s ({fmt(start)}..{fmt(end)})")

        counted = sum(end - start for kind, start, end in runs if kind != "paused")
        delta = counted - focused
        if abs(delta) > SECOND_TOLERANCE:
            print(
                f"AC7 FAIL: record {index}'s non-paused segments cover {counted:.2f}s of its "
                f"{focused:.2f}s focus (delta {delta:+.2f}s)"
            )
            ok = False
        else:
            show(
                quiet,
                f"  record {index}: non-paused segments cover {counted:.2f}s of "
                f"{focused:.2f}s (delta {delta:+.2f}s)",
            )

    if ok:
        print(
            f"AC7 PASS: {len(records)} focus(es), every timeline sums to its 专注时长 within a "
            f"second and every segment kind is legal"
        )
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log")
    parser.add_argument("--history")
    parser.add_argument("--quiet", action="store_true")
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--ac1", action="store_true", help="the countdown never stopped")
    modes.add_argument("--ac4", action="store_true", help="one clip at a time, in priority order")
    modes.add_argument("--ac5", action="store_true", help="a pause is not focus time")
    modes.add_argument("--ac7", action="store_true", help="every segment matches the script")
    args = parser.parse_args()

    if args.ac1:
        rows = load_log(args.log, "AC1")
        print(f"{args.log}: {len(rows)} records")
        return 0 if check_ac1(rows, args.quiet) else 1

    if args.ac4:
        rows = load_log(args.log, "AC4")
        print(f"{args.log}: {len(rows)} records")
        return 0 if check_ac4(rows, args.quiet) else 1

    history = args.history or default_history_path(args.log)
    mode = "AC5" if args.ac5 else "AC7"
    # The log is still loaded first so a missing log is reported as the missing log it is.
    rows = load_log(args.log, mode)
    print(f"{args.log}: {len(rows)} records")
    records = load_history(history, mode)
    print(f"{history}: {len(records)} pomodoro record(s)")

    if args.ac5:
        return 0 if check_ac5(records, args.quiet) else 1
    return 0 if check_ac7(records, args.quiet) else 1


if __name__ == "__main__":
    sys.exit(main())
