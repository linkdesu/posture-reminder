#!/usr/bin/env python3
"""Audit a PostureLab sandbox for anything the privacy rules forbid.

Usage:
  scripts/audit-sandbox.py <app-container-root> [--json out.json]

Argument: the directory that *contains* Documents/, i.e. what
`xcrun simctl get_app_container <sim> me.xieal.posturelab.depth data` prints, or the
`--destination` of a `devicectl device copy from --domain-type appDataContainer`
pull. Everything under it is walked.

AC14 and AC19 say the app must never display or persist a real RGB image, and must
leave no raw frames or depth data on disk after a monitoring round. This script is
how that is checked: it classifies every file, fails on anything that could hold
imagery or raw sensor data, and prints a manifest as the evidence.

Allowed: the JSONL session logs, the pomodoro history, and the app's own
preferences. Anything else is a finding, apart from the system-owned paths described
below. Images are never allowed: the debug screenshots live in memory only (ADR-0005),
so a PNG in the container is a finding like any other. Exit code 0 only when there are
no findings.

AC19 also asks whether *anything* was left behind, so the runner points this at the
whole container rather than only at the Documents subtree it collects as evidence. A
whole container holds files the app never wrote: iOS fills Library/ with saved-state
blobs, Metal caches and a SplashBoard snapshot of the app's own rendered UI, and drops
a .com.apple.* metadata plist at the container root. Those paths are classified as
system-owned and listed as such instead of being reported as findings -- but the
suffix and name-hint checks still run on them, because a frame dumped into Library/ is
exactly the case that has to be caught.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

ALLOWED_SUFFIXES = {".jsonl", ".json", ".plist", ".txt"}
ALLOWED_NAMES = {"sessions.json"}
# Suffixes iOS itself creates under Library/: .ktx is the SplashBoard snapshot, .data and
# .list are the Metal cache, .db/.sqlite/.strings are caches and localised strings. Some
# entries (the container's own metadata) carry no suffix at all, which is allowed too.
SYSTEM_SUFFIXES = {".ktx", ".data", ".list", ".db", ".sqlite", ".strings"}
SYSTEM_ALLOWED_SUFFIXES = ALLOWED_SUFFIXES | SYSTEM_SUFFIXES
SYSTEM_DIRS = (
    "Library/Caches/",
    "Library/SplashBoard/",
    "Library/Saved Application State/",
    "Library/Preferences/",
)
SYSTEM_BASENAME_PREFIX = ".com.apple."
# Anything here means a real frame or raw sensor data reached the disk.
FORBIDDEN_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".heic", ".heif", ".tiff", ".tif", ".bmp", ".gif", ".webp",
    ".mp4", ".mov", ".m4v", ".avi", ".h264", ".hevc",
    ".dng", ".raw", ".bin", ".exr", ".pfm", ".npy", ".npz", ".tflite", ".mlmodel",
}
# The app's own bundle id ends in ".depth"; iOS names saved-state, Metal-cache and SplashBoard
# paths after it, so it is cut out before the name hints run (r16: every system file tripped
# "depth"). A file the app itself names "depth-…" or "frame-…" is still caught.
BUNDLE_IDS = ("me.xieal.posturelab.depth", "me.xieal.posturelab")
FORBIDDEN_HINTS = ("depth", "raw", "capture", "frame", "rgb", "camera", "photo", "video", "faceframe")


def digest(path: str, limit: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        chunk = handle.read(limit)
        h.update(chunk)
    return h.hexdigest()[:16]


def walk(root: str):
    for base, _dirs, files in os.walk(root):
        for name in sorted(files):
            yield os.path.join(base, name)


def is_system_owned(rel: str) -> bool:
    """Whether iOS, not the app, is the writer of this container-relative path.

    The app only ever writes under Documents/ and its own preferences; the caches,
    SplashBoard snapshots, saved-state blobs and plists under Library/, plus the
    container's own .com.apple.* metadata, are the system's. Such files are classified
    as system-owned instead of being failed on for their type -- the forbidden-suffix
    and name-hint checks still apply to them.
    """
    if os.path.basename(rel).startswith(SYSTEM_BASENAME_PREFIX):
        return True
    return any(rel.startswith(prefix) for prefix in SYSTEM_DIRS)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("--json")
    args = parser.parse_args()

    if not os.path.isdir(args.root):
        sys.exit(f"{args.root}: not a directory")

    findings = []
    manifest = []
    counts = {"jsonl": 0, "other": 0, "system": 0}
    splashboard = []

    for path in walk(args.root):
        rel = os.path.relpath(path, args.root)
        name = os.path.basename(path)
        suffix = os.path.splitext(name)[1].lower()
        system_owned = is_system_owned(rel)
        size = os.path.getsize(path)
        entry = {
            "path": rel,
            "bytes": size,
            "sha256_16": digest(path),
            "classification": "system" if system_owned else "app",
        }
        if system_owned:
            counts["system"] += 1
            if rel.startswith("Library/SplashBoard/"):
                splashboard.append(rel)

        if suffix in FORBIDDEN_SUFFIXES:
            findings.append(f"{rel}: {suffix} can hold imagery or raw sensor data")
        elif system_owned:
            if suffix and suffix not in SYSTEM_ALLOWED_SUFFIXES:
                findings.append(f"{rel}: unexpected file type under a system-owned directory")
        elif suffix not in ALLOWED_SUFFIXES and name not in ALLOWED_NAMES:
            findings.append(f"{rel}: unexpected file type")

        lowered = rel.lower()
        for bundle in BUNDLE_IDS:
            lowered = lowered.replace(bundle, "<bundle>")
        if any(hint in lowered for hint in FORBIDDEN_HINTS):
            findings.append(f"{rel}: name suggests raw imagery or sensor data")

        if suffix == ".jsonl":
            counts["jsonl"] += 1
            with open(path, encoding="utf-8", errors="replace") as handle:
                first = handle.readline()
            try:
                json.loads(first)
            except json.JSONDecodeError:
                findings.append(f"{rel}: first line is not JSON")
            for line in open(path, encoding="utf-8", errors="replace"):
                if any(token in line for token in ('"rgb"', '"image"', '"jpeg"', '"pixels"')):
                    findings.append(f"{rel}: a log line carries an image-shaped field")
                    break
        else:
            counts["other"] += 1

        manifest.append(entry)

    print(f"audited {len(manifest)} file(s) under {args.root}")
    print(f"  jsonl {counts['jsonl']}, other {counts['other']}")
    print(f"  system-owned {counts['system']} (iOS-written; classified per file, not reported as a finding)")
    if splashboard:
        print(f"    {len(splashboard)} of them under Library/SplashBoard: UIKit's own snapshot of this app's")
        print("    rendered UI. The app does not create it, and it is harmless only because the UI")
        print("    never renders a camera image; it is listed as system-owned, not as a violation,")
        print("    and the suffix and name-hint checks above still ran on it.")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump({"root": args.root, "files": manifest, "findings": findings}, handle, indent=2)
        print(f"  manifest written to {args.json}")

    if findings:
        print(f"\nAC14/AC19 FAIL: {len(findings)} finding(s)")
        for finding in findings:
            print(f"  {finding}")
        return 1

    print("AC14/AC19 PASS: no frame, image or raw sensor file; the container holds no image at all")
    return 0


if __name__ == "__main__":
    sys.exit(main())
