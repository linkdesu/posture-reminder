#!/usr/bin/env python3
"""verify.py device-logs 的自测：五条标准各自的 PASS 与 FAIL 都要出现。

  python3 .omp/skills/verify-posture-lab/scripts/test_device_logs.py

每个用例在临时目录里造一套最小的 session/perf/joints 日志，再把 `PL_VERIFY_RUNS` 指到同一个临时
目录，用 `--dir` 跳过 devicectl——测试不连真机、不写仓库的 tmp/verify。
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


def joint_row(t_ms: int, *, available: bool = True, invalidated: bool = False,
              extra_joints: dict | None = None) -> dict:
    joints = {name: {"c": 0.9 if "Shoulder" not in name else 0.7, "v": available}
              for name in JOINTS}
    if extra_joints:
        joints.update(extra_joints)
    return {"t": t_ms, "session_t": 0.0, "stale": False,
            "shoulders_available": available, "shoulders_invalidated": invalidated,
            "joints": joints}


def session_rows(states: list[tuple[str, int, int]]) -> list[dict]:
    """states: [(state, startSecond, endSecond)]，切成 status_changed 窗口。"""
    rows = [{"ts": T0, "event": "session_started", "state": "good"}]
    for state, start, end in states:
        rows.append({"ts": T0 + start * 1000, "event": "status_changed", "state": state})
        rows.append({"ts": T0 + end * 1000, "event": "status_changed", "state": "good"})
    rows.append({"ts": T0 + 120_000, "event": "session_ended", "state": "good"})
    return sorted(rows, key=lambda row: row["ts"])


def thermal_rows(periods: list[tuple[int, int]]) -> list[dict]:
    """periods: [(startSecond, endSecond)]，降级开始与结束各一行 thermal。"""
    rows = []
    for start, end in periods:
        rows.append({"ts": T0 + start * 1000, "event": "thermal", "thermal_degraded": True})
        rows.append({"ts": T0 + end * 1000, "event": "thermal", "thermal_degraded": False})
    return rows


def perf_rows(seconds: int, *, degraded_seconds: set[int] | None = None,
              bad_p95_at: int | None = None) -> list[dict]:
    degraded_seconds = degraded_seconds or set()
    rows = []
    for second in range(seconds):
        degraded = second in degraded_seconds
        rows.append({
            "t": T0 + second * 1000,
            "frames": 30, "fps": 30.0, "frame_gap_ms": 33.4,
            "cloud_gap_p95_ms": 55.0 if second == bad_p95_at else 33.4,
            "cloud_gap_max_ms": 120.0 if second == bad_p95_at else 60.0,
            "cloud_points": 600, "cloud_frames": 15 if degraded else 30,
            "vision_calls": 5 if degraded else 10,
            "thermal_state": "serious" if degraded else "nominal",
            "battery_level": 0.8, "degraded": degraded, "window_s": 1.0,
        })
    return rows


class DeviceLogsTests(unittest.TestCase):
    def run_device_logs(self, *, joints, sessions, perf, focus_seconds=600):
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root)
            debug = root_path / "debug"
            debug.mkdir()
            (root_path / "runs").mkdir()
            (debug / "session-test.jsonl").write_text(
                "\n".join(json.dumps(row) for row in sessions) + "\n")
            (debug / "perf-test.jsonl").write_text(
                "\n".join(json.dumps(row) for row in perf) + "\n")
            (debug / "joints-test.jsonl").write_text(
                "\n".join(json.dumps(row) for row in joints) + "\n")
            env = os.environ.copy()
            env["PL_VERIFY_RUNS"] = str(root_path / "runs")
            env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
            return subprocess.run(
                [sys.executable, str(SCRIPT), "device-logs", "--run", "selftest",
                 "--dir", str(debug), "--focus-seconds", str(focus_seconds)],
                capture_output=True, text=True, env=env)

    def fixtures(self, *, joints=None, degraded=(), bad_p95_at=None,
                 thermal=None, states=None):
        windows = states if states is not None else [
            ("head_tilt", 10, 20), ("head_down", 30, 40)]
        rows = session_rows(windows)
        rows += thermal_rows(list(thermal) if thermal is not None else [])
        return {
            "joints": joints if joints is not None else [joint_row(T0 + i * 100) for i in range(0, 500)],
            "sessions": sorted(rows, key=lambda row: row["ts"]),
            "perf": perf_rows(120, degraded_seconds=set(degraded), bad_p95_at=bad_p95_at),
        }

    def test_all_five_checks_pass(self):
        r = self.run_device_logs(**self.fixtures())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PASS upper-body-only", r.stdout)
        self.assertIn("PASS shoulders-not-on-head", r.stdout)
        self.assertIn("PASS shoulders-available-ratio", r.stdout)
        self.assertIn("PASS cloud-smooth", r.stdout)
        self.assertIn("PASS degradation", r.stdout)
        self.assertIn("模拟器测不到的项", r.stdout)

    def test_a_hip_joint_fails_the_upper_body_rule(self):
        joints = [joint_row(T0 + i * 100) for i in range(10)]
        joints[3] = joint_row(T0 + 300, extra_joints={"leftHip": {"c": 0.9, "v": True}})
        r = self.run_device_logs(**self.fixtures(joints=joints))
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL upper-body-only", r.stdout)
        self.assertIn("leftHip", r.stdout)

    def test_a_shoulder_on_the_head_fails(self):
        joints = [joint_row(T0 + i * 100) for i in range(10)]
        joints[5] = joint_row(T0 + 500, invalidated=True)
        r = self.run_device_logs(**self.fixtures(joints=joints))
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL shoulders-not-on-head", r.stdout)

    def test_a_slow_cloud_gap_fails_the_smoothness_rule(self):
        r = self.run_device_logs(**self.fixtures(bad_p95_at=7))
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL cloud-smooth", r.stdout)
        self.assertIn("55.0", r.stdout)

    def test_degraded_time_under_the_share_passes(self):
        # 10 分钟里的 60 秒 = 10%，低于 20% 上限。
        r = self.run_device_logs(**self.fixtures(degraded=range(0, 60), thermal=[(0, 60)]))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("PASS degradation", r.stdout)
        # 降级的那 60 秒不参与流畅门槛：它们的 cloud_gap 也是 33.4 ms，但判据只看未降级行。
        self.assertIn("PASS cloud-smooth", r.stdout)

    def test_degraded_time_over_the_share_fails(self):
        # 150 秒 / 600 秒 = 25%，超过 20% 上限。
        r = self.run_device_logs(**self.fixtures(degraded=range(0, 150), thermal=[(0, 150)]))
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL degradation", r.stdout)
        self.assertIn("25.0%", r.stdout)
        self.assertIn("降级 1 段", r.stdout)


if __name__ == "__main__":
    unittest.main()
