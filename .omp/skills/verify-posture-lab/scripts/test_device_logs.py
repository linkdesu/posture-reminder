#!/usr/bin/env python3
"""verify.py device-logs 的自测：PASS / FAIL / INSUFFICIENT_DATA 三个状态都要出现。

  python3 .omp/skills/verify-posture-lab/scripts/test_device_logs.py

每个用例在临时目录里造一套最小的 session/perf/joints/frames 日志，再把 `PL_VERIFY_RUNS` 指到
同一个临时目录，用 `--dir` 跳过 devicectl——测试不连真机、不写仓库的 tmp/verify。

退出码约定：PASS = 0，FAIL = 1，INSUFFICIENT_DATA = 2。
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "verify.py"
JOINTS = ["nose", "leftEye", "rightEye", "leftEar", "rightEar", "neck",
          "leftShoulder", "rightShoulder"]
T0 = 1_793_000_000_000  # 一个固定的 epoch 毫秒起点
DURATION = 600          # 计划专注 10 分钟


def joint_row(t_ms: int, *, visible: bool = True, detected: bool = True,
              invalidated: bool = False, extra_joints: dict | None = None) -> dict:
    joints = {name: {"c": 0.9 if visible else None, "v": visible} for name in JOINTS}
    if extra_joints:
        joints.update(extra_joints)
    return {"t": t_ms, "session_t": 0.0, "detected": detected, "stale": False,
            "shoulders_available": visible, "shoulders_invalidated": invalidated,
            "raw": {name: (0.9 if visible else None) for name in JOINTS},
            "joints": joints}


def session_rows(second: int = DURATION, states=None) -> list[dict]:
    """一段 10 分钟的会话：`status_changed` 切出体态窗口，最后一个 session_ended 撑满时长。"""
    windows = states if states is not None else [("head_tilt", 100, 130), ("head_down", 200, 230)]
    rows = [{"ts": T0, "event": "session_started", "state": "good"}]
    for state, start, end in windows:
        rows.append({"ts": T0 + start * 1000, "event": "status_changed", "state": state})
        rows.append({"ts": T0 + end * 1000, "event": "status_changed", "state": "good"})
    rows.append({"ts": T0 + second * 1000, "event": "session_ended", "state": "good"})
    return sorted(rows, key=lambda row: row["ts"])


def thermal_rows(periods: list[tuple[int, int]]) -> list[dict]:
    rows = []
    for start, end in periods:
        rows.append({"ts": T0 + start * 1000, "event": "thermal", "thermal_degraded": True})
        rows.append({"ts": T0 + end * 1000, "event": "thermal", "thermal_degraded": False})
    return rows


def perf_rows(seconds: int, *, degraded_seconds: set[int] | None = None) -> list[dict]:
    degraded_seconds = degraded_seconds or set()
    rows = []
    for second in range(seconds):
        degraded = second in degraded_seconds
        rows.append({"t": T0 + second * 1000, "frames": 30, "fps": 30.0,
                     "cloud_frames": 15 if degraded else 30,
                     "thermal_state": "serious" if degraded else "nominal",
                     "battery_level": 0.8, "degraded": degraded, "window_s": 1.0,
                     "sanity_eye_below_mouth": 0, "sanity_shoulder_above_ear": 0,
                     "sanity_points_without_person": 0,
                     "serious_seconds": 150 if degraded else 0,
                     "degraded_seconds": 150 if degraded else 0})
    return rows


def frame_rows(seconds: int, *, start: int = 0, points: int = 600,
               spacing: float = 1 / 30, degraded=False) -> list[dict]:
    """逐帧记录：默认 30 Hz、每帧 600 点。"""
    rows = []
    count = int(seconds / spacing)
    for index in range(count):
        frame_s = start + index * spacing
        rows.append({"t": T0 + int(frame_s * 1000), "frame_s": round(frame_s, 4),
                     "arrival_s": round(frame_s + 0.002, 4), "depth_ms": 1.0,
                     "segment_ms": 82.0, "cloud_ms": 0.2, "points": points,
                     "mask_cells": 1200 if points else 0, "depth_valid": 0.98,
                     "nearest_m": 0.42, "degraded": degraded, "cloud_emitted": True,
                     "render_ms": 0.4, "render_latency_ms": 21.0})
    return rows


def joints_all(seconds: int = DURATION, **kwargs) -> list[dict]:
    return [joint_row(T0 + index * 100, **kwargs) for index in range(seconds * 10)]


class DeviceLogsTests(unittest.TestCase):
    def run_device_logs(self, *, joints, sessions, perf, frames,
                        focus_seconds=DURATION):
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root)
            debug = root_path / "debug"
            debug.mkdir()
            (root_path / "runs").mkdir()
            for name, rows in (("session", sessions), ("perf", perf),
                               ("joints", joints), ("cloud", frames)):
                (debug / f"{name}-test.jsonl").write_text(
                    "\n".join(json.dumps(row) for row in rows) + "\n")
            env = os.environ.copy()
            env["PL_VERIFY_RUNS"] = str(root_path / "runs")
            env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
            return subprocess.run(
                [sys.executable, str(SCRIPT), "device-logs", "--run", "selftest",
                 "--dir", str(debug), "--focus-seconds", str(focus_seconds)],
                capture_output=True, text=True, env=env)

    def fixtures(self, *, joints=None, perf=None, frames=None, sessions=None):
        return {
            "joints": joints if joints is not None else joints_all(),
            "sessions": sessions if sessions is not None else session_rows(),
            "perf": perf if perf is not None else perf_rows(DURATION),
            "frames": frames if frames is not None else frame_rows(DURATION),
        }

    # --- PASS ---------------------------------------------------------------

    def test_all_five_checks_pass(self):
        r = self.run_device_logs(**self.fixtures())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for name in ("upper-body-only", "shoulders-not-on-head",
                     "shoulders-available-ratio", "cloud-smooth", "degradation"):
            self.assertIn(f"PASS {name}", r.stdout)
        self.assertIn("模拟器测不到的项", r.stdout)

    # --- FAIL ---------------------------------------------------------------

    def test_a_hip_joint_fails_the_upper_body_rule(self):
        joints = [joint_row(T0 + i * 100) for i in range(600)]
        joints[3] = joint_row(T0 + 300, extra_joints={"leftHip": {"c": 0.9, "v": True}})
        r = self.run_device_logs(**self.fixtures(joints=joints))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL upper-body-only", r.stdout)
        self.assertIn("leftHip", r.stdout)

    def test_a_shoulder_on_the_head_fails(self):
        joints = [joint_row(T0 + i * 100) for i in range(600)]
        joints[5] = joint_row(T0 + 500, invalidated=True)
        r = self.run_device_logs(**self.fixtures(joints=joints))
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL shoulders-not-on-head", r.stdout)

    def test_a_slow_cloud_gap_fails_the_smoothness_rule(self):
        frames = frame_rows(60) + frame_rows(60, start=60, spacing=1 / 15)
        r = self.run_device_logs(**self.fixtures(frames=frames))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL cloud-smooth", r.stdout)

    def test_degraded_time_over_the_share_fails(self):
        r = self.run_device_logs(**self.fixtures(
            perf=perf_rows(DURATION, degraded_seconds=set(range(0, 150))),
            sessions=session_rows() + thermal_rows([(0, 150)])))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL degradation", r.stdout)
        self.assertIn("25.0%", r.stdout)

    # --- INSUFFICIENT_DATA --------------------------------------------------

    def test_nobody_in_frame_is_insufficient_not_pass(self):
        # 193 帧全不可见的真实情形：结构上「没有髋关节」成立，但没有证据，不能 PASS。
        r = self.run_device_logs(**self.fixtures(
            joints=joints_all(visible=False, detected=False)))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("INSUFFICIENT_DATA upper-body-only", r.stdout)
        self.assertIn("INSUFFICIENT_DATA shoulders-not-on-head", r.stdout)
        self.assertIn("结论：INSUFFICIENT_DATA", r.stdout)

    def test_zero_cloud_points_is_insufficient(self):
        r = self.run_device_logs(**self.fixtures(frames=frame_rows(DURATION, points=0)))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("INSUFFICIENT_DATA cloud-smooth", r.stdout)

    def test_a_short_session_is_insufficient(self):
        r = self.run_device_logs(**self.fixtures(
            sessions=session_rows(second=120),
            perf=perf_rows(120),
            frames=frame_rows(120)))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("INSUFFICIENT_DATA degradation", r.stdout)
        self.assertIn("短于 600 s", r.stdout)

    def test_too_few_visible_joint_frames_is_insufficient(self):
        # 每 10 秒才一帧可见：窗口里凑不满 30 帧，双肩占比没有统计意义。
        joints = [joint_row(T0 + index * 10_000) for index in range(DURATION // 10)]
        r = self.run_device_logs(**self.fixtures(joints=joints))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("INSUFFICIENT_DATA shoulders-available-ratio", r.stdout)

    def test_nobody_in_frame_is_insufficient_for_the_shoulder_ratio(self):
        # build 16 的反例：无人会话里 good 窗口有 47 帧、双肩 0/47，被判 FAIL。现在必须是 INSUFFICIENT_DATA。
        joints = joints_all(visible=False, detected=False)
        r = self.run_device_logs(**self.fixtures(joints=joints))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("INSUFFICIENT_DATA shoulders-available-ratio", r.stdout)

    def test_eye_below_mouth_fails_the_figure_sanity_rule(self):
        perf = perf_rows(DURATION)
        for row in perf:
            row["sanity_eye_below_mouth"] = 9
        r = self.run_device_logs(**self.fixtures(perf=perf))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL figure-sanity", r.stdout)

    def test_degraded_time_under_the_share_passes_when_the_session_is_long_enough(self):
        r = self.run_device_logs(**self.fixtures(
            perf=perf_rows(DURATION, degraded_seconds=set(range(0, 60))),
            sessions=session_rows() + thermal_rows([(0, 60)])))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("PASS degradation", r.stdout)


if __name__ == "__main__":
    unittest.main()
