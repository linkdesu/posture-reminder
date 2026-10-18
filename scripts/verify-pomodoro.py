#!/usr/bin/env python3
"""Re-run the QA checks for one pomodoro run against the history it wrote and its session log.

Usage:
  scripts/verify-pomodoro.py <session.jsonl> [--history PATH]
      [--expect-records N] [--expect-focus-seconds S] [--quiet]

Both files come out of the app's own sandbox: the history is
Documents/pomodoro-history.json and the log is Documents/debug/session-*.jsonl, which is one
directory down, so the history is looked for as the log directory's sibling unless --history
says otherwise. Everything below is recomputed from what the app wrote; nothing is taken on
trust. Exit code is 0 only when every requested check passes.

Checks:
  PM1  the history exists, parses, and holds the expected number of records
  PM2  every record is `completed`, with a positive `focusedSeconds` near its planned length
  PM3  every record's posture segments cover the focus they belong to, carry `"good"` as well
       as whatever posture broke it, and the records lay out as one increasing day
  PM4  every record's reminder counts are present and agree with the reminder lines in the log
  PM5  the log pairs each record with its own focus (`session_started` / `session_ended`)

Every check fails when its subject is missing: no history file, no records in it, a record with
no segments or no reminder counts is a failure, never a quiet pass.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# `PostureKind.rawValue`, which is what a record's `reminderCounts` is keyed by and what a
# `reminder` line carries as `alert_type`.
POSTURE_KINDS = [
    "desk_lean",
    "near",
    "head_forward",
    "slouch",
    "head_down",
    "head_tilt",
    "chin_rest",
]
# `PostureSegment.kind`: the seven postures plus the two states.
SEGMENT_KINDS = POSTURE_KINDS + ["good", "no_person"]

# A completed focus credits the whole plan by definition, so `focusedSeconds` is expected to land
# on `plannedSeconds`; the slack only covers float arithmetic.
FOCUS_TOLERANCE = 2.0
# The timeline starts on the first sample after the focus opens and closes on the sample that ends
# it, so its segments may fall a couple of ticks short of the record's window.
COVER_TOLERANCE = 2.0
# `plannedSeconds` is an exact count of seconds, so a plan that is asked for must match to a tick.
PLAN_TOLERANCE = 0.5


def fmt(value):
    if value is None:
        return "-"
    if isinstance(value, bool):
        return str(value)
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def show(quiet, text=""):
    """A narrative line: what a record actually holds. `--quiet` drops these the way
    `verify-session.py --quiet` drops its timeline, so a runner's log stays readable; the
    PASS/FAIL verdicts and their numbers are printed either way."""
    if not quiet:
        print(text)


def load_log(path):
    """The session log's rows, in file order."""
    if not os.path.exists(path):
        sys.exit(f"PM5 FAIL: no session log at {path}")
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


def default_history_path(log_path):
    """`Documents/debug/session-*.jsonl` -> `Documents/pomodoro-history.json`.

    The log lives one directory down in `debug/`, and the runner copies the whole Documents tree
    next to it, so the history is the log directory's sibling.
    """
    log_directory = os.path.dirname(os.path.abspath(log_path))
    return os.path.join(os.path.dirname(log_directory), "pomodoro-history.json")


def load_history(path):
    """The stored pomodoro records. A missing or unreadable file is a hard failure: without it
    there is nothing to check, and a quiet pass would claim the opposite."""
    if not os.path.exists(path):
        sys.exit(f"PM1 FAIL: no pomodoro history at {path}")
    try:
        with open(path, encoding="utf-8") as handle:
            stored = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        sys.exit(f"PM1 FAIL: {path} is not readable JSON: {error}")
    if not isinstance(stored, list):
        sys.exit(f"PM1 FAIL: {path} holds a {type(stored).__name__}, not a list of records")
    records = [record for record in stored if isinstance(record, dict)]
    if len(records) != len(stored):
        sys.exit(f"PM1 FAIL: {len(stored) - len(records)} entry/entries in {path} are not records")
    return records


def number(value):
    """A JSON number, or None. Booleans are not numbers here, whatever Python thinks."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def check_record_count(records, expected):
    """PM1: the history holds the pomodoros this run was supposed to complete."""
    if not records:
        print("PM1 FAIL: the history holds no record, so nothing about this run was saved")
        return False
    if expected is not None and len(records) != expected:
        print(f"PM1 FAIL: {len(records)} record(s) in the history, wanted {expected}")
        return False
    wanted = f"{expected}" if expected is not None else "at least 1"
    print(f"PM1 PASS: {len(records)} record(s) in the history (wanted {wanted})")
    return True


def check_completion(records, expected_focus_seconds, quiet):
    """PM2: every record completed, with real focus time at the length it planned.

    The numbers are printed whatever the verdict: a run that half-worked is exactly the case
    where the record has to be read rather than guessed at.
    """
    ok = True
    for index, record in enumerate(records, 1):
        planned = number(record.get("plannedSeconds"))
        focused = number(record.get("focusedSeconds"))
        paused = number(record.get("pausedSeconds"))
        outcome = record.get("outcome")
        show(
            quiet,
            f"\n--- record {index}: focus {fmt(record.get('focusIndex'))}, "
            f"started {fmt(record.get('startedAt'))}, ended {fmt(record.get('endedAt'))} ---",
        )
        show(
            quiet,
            f"  outcome={outcome} planned={fmt(planned)}s focused={fmt(focused)}s "
            f"paused={fmt(paused)}s skippedBreak={record.get('skippedBreak')}",
        )

        if outcome != "completed":
            print(f"PM2 FAIL: record {index} is {outcome or 'missing an outcome'}, not completed")
            ok = False
            continue
        if planned is None:
            print(f"PM2 FAIL: record {index} has no plannedSeconds")
            ok = False
            continue
        if expected_focus_seconds is not None and abs(planned - expected_focus_seconds) > PLAN_TOLERANCE:
            print(
                f"PM2 FAIL: record {index} planned {planned:.2f}s, wanted "
                f"{expected_focus_seconds:.2f}s (the shortened settings a scripted round uses)"
            )
            ok = False
        if focused is None or focused <= 0:
            print(f"PM2 FAIL: record {index} focusedSeconds={fmt(focused)}, wanted a positive number")
            ok = False
            continue
        if abs(focused - planned) > FOCUS_TOLERANCE:
            print(
                f"PM2 FAIL: record {index} focused {focused:.2f}s against a plan of {planned:.2f}s "
                f"(allowed {FOCUS_TOLERANCE:.1f}s)"
            )
            ok = False
            continue
        print(
            f"PM2 PASS: record {index} completed, {focused:.2f}s of focus on a plan of "
            f"{planned:.2f}s, {paused:.2f}s paused"
        )
    return ok


def segment_window(segment):
    """(kind, start, end) for one segment, or None when it is not readable."""
    if not isinstance(segment, dict):
        return None
    start = number(segment.get("start"))
    end = number(segment.get("end"))
    if start is None or end is None or end < start:
        return None
    return (segment.get("kind"), start, end)


def coverage(segments):
    """Seconds covered by the merged intervals, so overlapping segments cannot count twice."""
    total = 0.0
    reach = None
    for _kind, start, end in sorted(segments, key=lambda item: item[1]):
        if reach is None or start > reach:
            total += end - start
        elif end > reach:
            total += end - reach
        reach = end if reach is None else max(reach, end)
    return total


def check_timelines(records, quiet):
    """PM3: the parent's timeline. Each record's segments have to cover the focus they belong to
    and have to hold `"good"` entries as well as the postures that broke it, because a timeline
    written from the bad postures alone would read as a charting bug; and the day has to lay the
    records out one after another rather than rewriting one focus three times."""
    all_ok = True
    previous_end = None
    for index, record in enumerate(records, 1):
        record_ok = True
        planned = number(record.get("plannedSeconds"))
        started = number(record.get("startedAt"))
        ended = number(record.get("endedAt"))
        stored = record.get("postureSegments")
        if not isinstance(stored, list) or not stored:
            print(f"PM3 FAIL: record {index} carries no postureSegments, so its timeline is empty")
            all_ok = False
            continue
        readable = [segment_window(segment) for segment in stored]
        if any(window is None for window in readable):
            print(f"PM3 FAIL: record {index} has a segment with no readable start/end")
            all_ok = False
            continue
        if planned is None or started is None:
            print(f"PM3 FAIL: record {index} has no plan or no start to cover")
            all_ok = False
            continue

        unknown = sorted({kind for kind, _start, _end in readable if kind not in SEGMENT_KINDS})
        if unknown:
            print(f"PM3 FAIL: record {index} has segment kind(s) {', '.join(unknown)} outside the vocabulary")
            record_ok = False

        show(quiet, f"  segments of record {index}:")
        for kind, start, end in readable:
            show(quiet, f"    {kind}: {fmt(start)}..{fmt(end)} = {fmt(end - start)}s")

        seconds = sum(end - start for _kind, start, end in readable)
        covered = coverage(readable)
        window_end = ended if ended is not None else started + planned
        if covered < planned - COVER_TOLERANCE:
            print(
                f"PM3 FAIL: record {index}'s segments cover {covered:.2f}s of a {planned:.2f}s focus "
                f"(allowed {COVER_TOLERANCE:.1f}s short)"
            )
            record_ok = False
        outside = [
            (kind, start, end)
            for kind, start, end in readable
            if start < started - COVER_TOLERANCE or end > window_end + COVER_TOLERANCE
        ]
        if outside:
            kind, start, end = outside[0]
            print(
                f"PM3 FAIL: record {index}'s {kind} segment {fmt(start)}..{fmt(end)} falls outside "
                f"the record's window {fmt(started)}..{fmt(window_end)}"
            )
            record_ok = False
        if not any(kind == "good" for kind, _start, _end in readable):
            print(f"PM3 FAIL: record {index} has no \"good\" segment, so its good-posture ratio is zero by construction")
            record_ok = False
        if previous_end is not None and started < previous_end - COVER_TOLERANCE:
            print(
                f"PM3 FAIL: record {index} starts at {fmt(started)} inside the record before it "
                f"(which ran to {fmt(previous_end)})"
            )
            record_ok = False

        if record_ok:
            print(
                f"  PM3 PASS: record {index} covers {covered:.2f}s of {planned:.2f}s in "
                f"{len(readable)} segment(s), {seconds - covered:.2f}s of them overlapping, and holds good time"
            )
        all_ok = all_ok and record_ok
        previous_end = window_end
    return all_ok


def check_log_pairing(rows, record_count):
    """PM5: the log pairs each record with a focus of its own.

    One focus is logged as one posture session, so a log with fewer `session_started` lines than
    the history has records means a record was written for a focus the log never saw.
    """
    started = [row for row in rows if row.get("event") == "session_started"]
    ended = [row for row in rows if row.get("event") == "session_ended"]
    scenarios = sorted({str(row.get("scenario")) for row in started})
    if not started or not ended:
        print(
            f"PM5 FAIL: the log holds {len(started)} session_started and {len(ended)} session_ended "
            f"line(s), so it bears no focus to pair {record_count} record(s) with"
        )
        return False
    if len(started) != record_count or len(ended) != record_count:
        print(
            f"PM5 FAIL: {len(started)} session_started / {len(ended)} session_ended pair(s) in the log "
            f"against {record_count} record(s): each pomodoro has to be one session of its own"
        )
        return False
    print(
        f"PM5 PASS: {len(started)} focus session(s) in the log, one per record "
        f"(scenario {', '.join(scenarios)})"
    )
    return True


def check_reminder_counts(rows, records, quiet):
    """PM4: the reminder counts a record carries are the reminder lines the log holds.

    This is the parent's only evidence of how often the child was nagged inside one pomodoro, so
    the counts have to be there and agree with the log the record was written from.
    """
    logged = {}
    for row in rows:
        if row.get("event") == "reminder":
            kind = row.get("alert_type")
            logged[kind] = logged.get(kind, 0) + 1

    recorded = {}
    ok = True
    for index, record in enumerate(records, 1):
        counts = record.get("reminderCounts")
        if not isinstance(counts, dict) or not counts:
            print(f"PM4 FAIL: record {index} carries no reminderCounts")
            ok = False
            continue
        unknown = sorted(kind for kind in counts if kind not in POSTURE_KINDS)
        if unknown:
            print(f"PM4 FAIL: record {index} counts reminder(s) for {', '.join(unknown)}, which are not postures")
            ok = False
        bad = sorted(kind for kind, value in counts.items() if number(value) is None or value < 0)
        if bad:
            print(f"PM4 FAIL: record {index} has a reminder count that is not a non-negative number: {', '.join(bad)}")
            ok = False
        show(quiet, f"  reminders of record {index}: {json.dumps(counts, sort_keys=True)}")
        for kind, value in counts.items():
            recorded[kind] = recorded.get(kind, 0) + int(number(value) or 0)

    if not logged:
        print("PM4 FAIL: the log holds no reminder line, so no count can be checked against it")
        return False
    total = sum(recorded.values())
    if total <= 0:
        print("PM4 FAIL: every record's reminder counts are zero, so the history holds no reminder evidence")
        return False
    for kind in sorted(set(recorded) | set(logged)):
        if recorded.get(kind, 0) != logged.get(kind, 0):
            print(
                f"PM4 FAIL: the history counts {recorded.get(kind, 0)} {kind} reminder(s) "
                f"and the log holds {logged.get(kind, 0)}"
            )
            ok = False
    if ok:
        print(f"PM4 PASS: {total} reminder(s) counted across the records, matching the {sum(logged.values())} log line(s)")
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log")
    parser.add_argument("--history")
    parser.add_argument("--expect-records", type=int)
    parser.add_argument("--expect-focus-seconds", type=float)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    rows = load_log(args.log)
    print(f"{args.log}: {len(rows)} records")

    history = args.history or default_history_path(args.log)
    records = load_history(history)
    print(f"{history}: {len(records)} pomodoro record(s)")

    results = [
        check_record_count(records, args.expect_records),
        check_completion(records, args.expect_focus_seconds, args.quiet),
        check_timelines(records, args.quiet),
        check_reminder_counts(rows, records, args.quiet),
        check_log_pairing(rows, len(records)),
    ]

    print("\nRESULT:", "PASS" if all(results) else "FAIL")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
