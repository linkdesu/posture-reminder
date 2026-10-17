#!/usr/bin/env python3
"""Audit a PostureLab sandbox for anything the privacy rules forbid.

Usage:
  scripts/audit-sandbox.py <app-container-root> [--json out.json]

Argument: the directory that *contains* Documents/, i.e. what
`xcrun simctl get_app_container <sim> me.xieal.posturelab data` prints, or the
`--destination` of a `devicectl device copy from --domain-type appDataContainer`
pull. Everything under it is walked.

AC14 and AC19 say the app must never display or persist a real RGB image, and must
leave no raw frames or depth data on disk after a monitoring round. This script is
how that is checked: it classifies every file, fails on anything that could hold
imagery or raw sensor data, and prints a manifest as the evidence.

Allowed: the JSONL session logs, the debug screenshots (PNG, written from the
artistic canvas), the session summary file, and the app's own preferences. Anything
else is a finding. Exit code 0 only when there are no findings.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

ALLOWED_SUFFIXES = {".jsonl", ".json", ".plist", ".png", ".txt"}
ALLOWED_NAMES = {"sessions.json"}
# Anything here means a real frame or raw sensor data reached the disk.
FORBIDDEN_SUFFIXES = {
    ".jpg", ".jpeg", ".heic", ".heif", ".tiff", ".tif", ".bmp", ".gif", ".webp",
    ".mp4", ".mov", ".m4v", ".avi", ".h264", ".hevc",
    ".dng", ".raw", ".bin", ".exr", ".pfm", ".npy", ".npz", ".tflite", ".mlmodel",
}
FORBIDDEN_HINTS = ("depth", "raw", "capture", "frame", "rgb", "camera", "photo", "video", "faceframe")


def digest(path: str, limit: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        chunk = handle.read(limit)
        h.update(chunk)
    return h.hexdigest()[:16]


def png_size(path: str):
    """Read width and height from a PNG's IHDR, without decoding the image."""
    with open(path, "rb") as handle:
        header = handle.read(24)
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big")


def walk(root: str):
    for base, _dirs, files in os.walk(root):
        for name in sorted(files):
            yield os.path.join(base, name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("--json")
    args = parser.parse_args()

    if not os.path.isdir(args.root):
        sys.exit(f"{args.root}: not a directory")

    findings = []
    manifest = []
    counts = {"jsonl": 0, "png": 0, "other": 0}

    for path in walk(args.root):
        rel = os.path.relpath(path, args.root)
        name = os.path.basename(path)
        suffix = os.path.splitext(name)[1].lower()
        size = os.path.getsize(path)
        entry = {"path": rel, "bytes": size, "sha256_16": digest(path)}

        if suffix in FORBIDDEN_SUFFIXES:
            findings.append(f"{rel}: {suffix} can hold imagery or raw sensor data")
        elif suffix not in ALLOWED_SUFFIXES and name not in ALLOWED_NAMES:
            findings.append(f"{rel}: unexpected file type")

        lowered = rel.lower()
        if any(hint in lowered for hint in FORBIDDEN_HINTS):
            findings.append(f"{rel}: name suggests raw imagery or sensor data")

        if suffix == ".png":
            counts["png"] += 1
            size_px = png_size(path)
            entry["png"] = list(size_px) if size_px else None
            if size_px is None:
                findings.append(f"{rel}: not a readable PNG")
            elif size_px[0] < 100 or size_px[1] < 100:
                findings.append(f"{rel}: {size_px[0]}x{size_px[1]} is far too small to be a debug screenshot")
        elif suffix == ".jsonl":
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
    print(f"  jsonl {counts['jsonl']}, png {counts['png']}, other {counts['other']}")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump({"root": args.root, "files": manifest, "findings": findings}, handle, indent=2)
        print(f"  manifest written to {args.json}")

    if findings:
        print(f"\nAC14/AC19 FAIL: {len(findings)} finding(s)")
        for finding in findings:
            print(f"  {finding}")
        return 1

    print("AC14/AC19 PASS: no frame, image or raw sensor file, and every screenshot is a PNG")
    print("  note: whether a screenshot is recognisably artistic rather than a real face is a")
    print("  human judgement; open the PNGs in the evidence directory to check that part")
    return 0


if __name__ == "__main__":
    sys.exit(main())
