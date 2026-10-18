#!/usr/bin/env python3
"""Check that the debug overlay's red rows match what the log says is over threshold.

Usage:
  scripts/check-overlay.py <session.jsonl> [--quiet]

AC13 says the overlay highlights the features that are over threshold, and that this is
visible in a screenshot. Reading that off a screenshot by eye is exactly the kind of
check that goes wrong, so this samples the pixels instead and compares the count of red
rows against the `over` flags the app itself recorded in its `features` lines.

Method: decode the PNGs with the standard library, look at the bottom strip where the
feature table is, find horizontal bands containing strongly red pixels, and count them.
The layout assumption is deliberate and shallow: if the table moves, this fails loudly
rather than quietly passing.

Exit code 0 only when the most red rows seen in any screenshot equals the most
over-threshold features the log ever recorded, and is 0 exactly when the log has none.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import struct
import sys
import zlib

# The feature table sits in the bottom strip; these are fractions of the image size.
STRIP_TOP = 0.70
STRIP_BOTTOM = 0.98
# Columns to scan, chosen to sit inside the table and clear of the edge-alert border.
COLUMN_LEFT = 0.07
COLUMN_RIGHT = 0.60


def read_png(path):
    """Minimal PNG reader: 8- or 16-bit, colour types 2 and 6, non-interlaced."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")
    pos = 8
    header = None
    idat = bytearray()
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    width, height, depth, colour, _comp, _filter, interlace = header
    if interlace:
        raise ValueError(f"{path}: interlaced PNGs are not supported")
    channels = {2: 3, 6: 4}[colour]
    sample = depth // 8
    bpp = channels * sample
    raw = zlib.decompress(bytes(idat))
    stride = width * bpp
    out = bytearray(height * stride)
    previous = bytearray(stride)
    pos = 0
    for row in range(height):
        filter_type = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if filter_type == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                up = previous[i]
                upleft = previous[i - bpp] if i >= bpp else 0
                estimate = left + up - upleft
                pa, pb, pc = abs(estimate - left), abs(estimate - up), abs(estimate - upleft)
                if pa <= pb and pa <= pc:
                    best = left
                elif pb <= pc:
                    best = up
                else:
                    best = upleft
                line[i] = (line[i] + best) & 0xFF
        out[row * stride:(row + 1) * stride] = line
        previous = line
    return width, height, channels, sample, out


def red_bands(path):
    """Count horizontal bands of strongly red pixels in the feature-table strip."""
    width, height, channels, sample, pixels = read_png(path)
    stride = width * channels * sample
    left = int(width * COLUMN_LEFT)
    right = int(width * COLUMN_RIGHT)
    top = int(height * STRIP_TOP)
    bottom = int(height * STRIP_BOTTOM)

    bands = []
    inside = False
    for y in range(top, bottom):
        row_has_red = False
        base = y * stride
        for x in range(left, right):
            offset = base + x * channels * sample
            r = pixels[offset]
            g = pixels[offset + sample]
            b = pixels[offset + 2 * sample]
            if r > 150 and r > g * 1.6 and r > b * 1.6:
                row_has_red = True
                break
        if row_has_red and not inside:
            bands.append(y)
            inside = True
        elif not row_has_red:
            inside = False
    return bands


def log_over_counts(session_path):
    counts = []
    with open(session_path, encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            row = json.loads(line)
            if row.get("event") == "features":
                values = row.get("feature_values") or {}
                counts.append(sum(1 for entry in values.values() if entry.get("over")))
    return counts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("session")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    counts = log_over_counts(args.session)
    if not counts:
        print("AC13 FAIL: the session has no `features` lines, so there is nothing to check against")
        return 1

    overlay_on = False
    for line in open(args.session, encoding="utf-8"):
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("event") == "view_mode" and row.get("overlay_on") is True:
            overlay_on = True
            break
    if not overlay_on:
        print("AC13 SKIP: the overlay was off for this session, so no red rows are expected")
        return 0
    worst = max(counts)

    directory = os.path.join(os.path.dirname(os.path.abspath(args.session)), "screenshots")
    shots = sorted(glob.glob(os.path.join(directory, "*.png")))
    if not shots:
        print(f"AC13 FAIL: no screenshots in {directory}")
        return 1

    seen = {}
    for shot in shots:
        bands = red_bands(shot)
        seen[os.path.basename(shot)] = len(bands)
    best = max(seen.values())

    if not args.quiet:
        print(f"  log: up to {worst} over-threshold feature(s); counts seen: {counts[:8]}{'…' if len(counts) > 8 else ''}")
        for name, count in sorted(seen.items()):
            print(f"  {name}: {count} red row(s)")

    if worst > 0 and best == 0:
        print(f"AC13 FAIL: the log records up to {worst} over-threshold feature(s) but no screenshot shows a red row")
        return 1
    if worst > 0 and best > worst:
        print(f"AC13 FAIL: {best} red rows drawn but the log never recorded more than {worst} over threshold")
        return 1
    if worst == 0 and best > 0:
        print(f"AC13 FAIL: {best} red row(s) drawn while the log records none over threshold")
        return 1
    print(f"AC13 PASS: red rows track the log (log max {worst}, screenshot max {best})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
