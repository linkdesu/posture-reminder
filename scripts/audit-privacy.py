#!/usr/bin/env python3
"""审计彩色帧的静态边界：彩色像素只允许进 Vision，任何地方都不许落到屏幕、磁盘或网络。

用法：
  scripts/audit-privacy.py [--root PostureLab] [--project project.yml]

ADR-0008 把隐私边界从「不读彩色像素」改成「彩色像素只进 Vision、只在内存」。运行期只能证明
某一次运行恰好没写文件，这个脚本证明的是更强的性质：源码里根本没有第二条彩色像素通路。

三条规则：

1. 白名单。`VNDetectHumanBodyPose` 只允许出现在 `VisionJointSource.swift`；`AVCaptureVideoDataOutput`
   与视频 delegate 只允许出现在 `DepthCaptureSource.swift`。这两处就是彩色帧的全部生命周期——
   一个交出像素，一个只交出关节。
2. 禁止面。预览层、图片创建与编码（`UIImage(`、`CGImage`、`jpegData`、`pngData`、`CIImage` 写文件、
   `CIContext`、`AVAssetWriter`、`AVCaptureMovieFileOutput`）与联网 API（`URLSession`、`URLRequest`、
   `WKWebView` 等）在任何文件里都不允许。
3. 授权文案。`project.yml` 的 `NSCameraUsageDescription` 必须一字不差是规定的文案，显示名必须是
   `PostureLab`。

注释先被剥掉（与 `audit-offline.py` 同一套剥离器）：文档注释里提到这些名字是合法的，代码里不是。
退出码 0 只在没有任何发现时。
"""

from __future__ import annotations

import argparse
import os
import re
import sys

# 每个符号允许出现的文件（相对 --root）。不在这张表里的文件命中任何一个符号都是 finding。
COLOUR_BOUNDARY = {
    # 摄像头彩色这一侧的原始面：只有采集源能碰。
    "AVCaptureVideoDataOutput": {"Input/DepthCaptureSource.swift"},
    "AVCaptureVideoDataOutputSampleBufferDelegate": {"Input/DepthCaptureSource.swift"},
    "AVCaptureVideoDataOutputSampleBufferDelegate_": {"Input/DepthCaptureSource.swift"},
    "didOutput sampleBuffer": {"Input/DepthCaptureSource.swift"},
    "CMSampleBufferGetImageBuffer": {"Input/DepthCaptureSource.swift"},
    # 推理这一侧：只有 Vision 关节来源能碰。
    "VNDetectHumanBodyPose": {"Input/VisionJointSource.swift"},
    "VNHumanBodyPoseObservation": {"Input/VisionJointSource.swift"},
    "VNImageRequestHandler": {"Input/VisionJointSource.swift"},
}

# 任何文件里都不允许：预览、图片创建与编码、视频文件、联网。
FORBIDDEN = [
    "AVCaptureVideoPreviewLayer",
    "AVCaptureMovieFileOutput",
    "UIImage(",
    "NSImage(",
    "CGImage",
    "jpegData(",
    "pngData(",
    "CIImage",
    "CIContext",
    "AVAssetWriter",
    "AVAssetWriterInput",
    "URLSession",
    "URLRequest",
    "NSURLSession",
    "NSURLConnection",
    "WKWebView",
    "import Network",
    "NWConnection",
    "NWPathMonitor",
    "Alamofire",
    "Moya",
    "getaddrinfo(",
    "CFSocket",
    "dns_sd",
]

URL_LITERAL = re.compile(r'"(?:https?|ws|wss)://')

# 规定文案：一字不差，标点也不换。
CAMERA_USAGE_DESCRIPTION = "用于在本机识别坐姿，画面不会显示、保存或上传"
DISPLAY_NAME = "PostureLab"


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
                path = os.path.join(base, name)
                yield os.path.relpath(path, root), path


def check_sources(root: str) -> tuple[list[str], int]:
    findings: list[str] = []
    scanned = 0
    for rel, path in swift_files(root):
        scanned += 1
        with open(path, encoding="utf-8", errors="replace") as handle:
            code = strip_comments(handle.read())
        for symbol, allowed in COLOUR_BOUNDARY.items():
            if symbol in code and rel not in allowed:
                findings.append(f"{rel}: 彩色帧边界符号 {symbol} 只允许出现在 {sorted(allowed)}")
        for symbol in FORBIDDEN:
            if symbol in code:
                findings.append(f"{rel}: 禁止的符号 {symbol}")
        for match in URL_LITERAL.finditer(code):
            findings.append(f"{rel}: 代码里有 URL 字面量（offset {match.start()}）")
    return findings, scanned


def plist_entry(source: str, key: str) -> str | None:
    """project.yml 里 `KEY: "value"` 的值；找不到返回 None。"""
    pattern = re.compile(rf'^\s*{re.escape(key)}:\s*(.+?)\s*$', re.MULTILINE)
    match = pattern.search(source)
    if not match:
        return None
    value = match.group(1).strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    return value


def check_project(project: str) -> list[str]:
    findings: list[str] = []
    with open(project, encoding="utf-8", errors="replace") as handle:
        source = handle.read()
    usage = plist_entry(source, "INFOPLIST_KEY_NSCameraUsageDescription")
    if usage != CAMERA_USAGE_DESCRIPTION:
        findings.append(f"{project}: NSCameraUsageDescription 必须是「{CAMERA_USAGE_DESCRIPTION}」，实际 {usage!r}")
    display = plist_entry(source, "INFOPLIST_KEY_CFBundleDisplayName")
    if display != DISPLAY_NAME:
        findings.append(f"{project}: CFBundleDisplayName 必须是「{DISPLAY_NAME}」，实际 {display!r}")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="PostureLab")
    parser.add_argument("--project", default="project.yml")
    args = parser.parse_args()

    if not os.path.isdir(args.root):
        sys.exit(f"{args.root}: not a directory")

    findings, scanned = check_sources(args.root)
    if os.path.exists(args.project):
        findings += check_project(args.project)
    else:
        findings.append(f"{args.project}: 找不到工程文件，无法核对授权文案")

    print(f"scanned {scanned} Swift file(s) under {args.root}")
    if findings:
        print(f"\nADR-0008 FAIL: {len(findings)} 处彩色帧边界问题")
        for finding in findings:
            print(f"  {finding}")
        return 1

    print("ADR-0008 PASS: 彩色帧只进 Vision；无预览、无图片/视频编码、无联网 API")
    print(f"  授权文案与显示名一致（NSCameraUsageDescription / {DISPLAY_NAME}）")
    print("  注意：这是源码的静态性质，不观察任何一次运行")
    return 0


if __name__ == "__main__":
    sys.exit(main())
