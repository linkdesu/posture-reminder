#!/usr/bin/env python3
"""Audit the app's own sources for any way to reach the network.

Usage:
  scripts/audit-offline.py [--root PostureLab]

AC8 says the whole experience is offline. On a simulator a "no request was made" claim is
only as good as the run you happened to observe, so this checks the stronger property:
there is no networking API in the app at all. Comments are stripped first, because doc
comments legitimately carry links to the research and the specifications, and those are
not code.

Exit code 0 only when no networking surface is found.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

# Anything here is a way out of the device. Kept deliberately concrete: a substring match on
# "socket" would fire on a variable named socketCount, and a match on "http" would fire on
# every doc-comment link before the strip below.
NETWORK_APIS = [
    "URLSession",
    "URLRequest",
    "NSURLSession",
    "NSURLConnection",
    "import Network",
    "NWConnection",
    "NWPathMonitor",
    "NWEndpoint",
    "CFStream",
    "CFSocket",
    "WKWebView",
    "WebSocket",
    "Alamofire",
    "Moya",
    "NWListener",
    "SCNetworkReachability",
    "CFHTTPStream",
    "dns_sd",
    "getaddrinfo(",
]

# A URL written in code, as opposed to one written in a comment.
URL_LITERAL = re.compile(r'"(?:https?|ws|wss)://')


def strip_comments(source: str) -> str:
    """Remove block comments, then line comments, leaving string literals intact."""
    out = []
    index = 0
    inside_string = False
    length = len(source)
    while index < length:
        char = source[index]
        if inside_string:
            out.append(char)
            if char == "\\" and index + 1 < length:
                out.append(source[index + 1])
                index += 2
                continue
            if char == '"':
                inside_string = False
            index += 1
            continue
        if char == '"':
            inside_string = True
            out.append(char)
            index += 1
            continue
        if source.startswith("//", index):
            while index < length and source[index] != "\n":
                index += 1
            continue
        if source.startswith("/*", index):
            depth = 1
            index += 2
            while index < length and depth > 0:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            continue
        out.append(char)
        index += 1
    return "".join(out)


def swift_files(root: str):
    for base, _dirs, files in os.walk(root):
        for name in sorted(files):
            if name.endswith(".swift"):
                yield os.path.join(base, name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="PostureLab")
    args = parser.parse_args()

    if not os.path.isdir(args.root):
        sys.exit(f"{args.root}: not a directory")

    findings = []
    scanned = 0
    for path in swift_files(args.root):
        scanned += 1
        with open(path, encoding="utf-8", errors="replace") as handle:
            code = strip_comments(handle.read())
        for api in NETWORK_APIS:
            if api in code:
                findings.append(f"{path}: references {api}")
        for match in URL_LITERAL.finditer(code):
            findings.append(f"{path}: contains a URL literal near offset {match.start()}")

    print(f"scanned {scanned} Swift file(s) under {args.root}")
    if findings:
        print(f"\nAC8 FAIL: {len(findings)} networking finding(s)")
        for finding in findings:
            print(f"  {finding}")
        return 1

    print("AC8 PASS: no networking API and no URL literal in the app's code")
    print("  note: this is a static property of the sources; it does not observe a run")
    return 0


if __name__ == "__main__":
    sys.exit(main())
