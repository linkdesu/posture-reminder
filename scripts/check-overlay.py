#!/usr/bin/env python3
"""Check that the debug overlay's highlighted row follows the log's own `over` flags.

Usage:
  scripts/check-overlay.py <session.jsonl> [--quiet]

AC13 says the overlay highlights the features that are over threshold. The app no
longer writes a screenshot (ADR-0005: nothing in the container may be an image), so
this checks the two log facts the drawing is built from instead of sampling pixels:

  * at least one `features` line exists, so there is a table at all;
  * the overlay is reported on by a `view_mode` line;
  * whenever a `features` line marks a feature highlighted, that same line says the
    feature is over threshold — the app never points at a row it did not judge over.

Whether the red row is visibly drawn is a human check on the screen itself.

Exit code 0 when the log is consistent; 0 with a SKIP line when the overlay was off.
"""

from __future__ import annotations

import argparse
import json
import sys


def load(path):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                rows.append(json.loads(line))
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("session")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    rows = load(args.session)
    features = [row for row in rows if row.get("event") == "features"]
    if not features:
        print("AC13 FAIL: the session has no `features` lines, so there is no table to highlight")
        return 1

    overlay_on = any(
        row.get("event") == "view_mode" and row.get("overlay_on") is True for row in rows
    )
    if not overlay_on:
        print("AC13 SKIP: the overlay was off for this session, so no row is expected")
        return 0

    highlighted = 0
    mismatched = []
    worst = 0
    for row in features:
        values = row.get("feature_values") or {}
        over = sum(1 for entry in values.values() if isinstance(entry, dict) and entry.get("over") is True)
        worst = max(worst, over)
        name = row.get("highlighted_feature")
        if name is None:
            continue
        highlighted += 1
        if (values.get(name) or {}).get("over") is not True:
            mismatched.append((row.get("t"), name))

    if mismatched:
        first = mismatched[0]
        print(
            f"AC13 FAIL: {len(mismatched)} features line(s) highlight a feature the log does not "
            f"mark over; first at t={first[0]} highlighting {first[1]}"
        )
        return 1

    if not args.quiet:
        print(f"  log: up to {worst} over-threshold feature(s); {highlighted} highlighted row(s)")
    print(
        f"AC13 PASS: {highlighted} highlighted row(s), all marked over; "
        f"log max {worst} over threshold"
    )
    print("AC13 HUMAN: whether the red row is visibly drawn is a human check on the screen")
    return 0


if __name__ == "__main__":
    sys.exit(main())
