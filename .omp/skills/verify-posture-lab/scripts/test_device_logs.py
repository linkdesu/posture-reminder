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
              invalidated: bool = False, extra_joints: dict | None = None,
              presence_path: str | None = None, face_detected: bool | None = None) -> dict:
    joints = {name: {"c": 0.9 if visible else None, "v": visible} for name in JOINTS}
    if extra_joints:
        joints.update(extra_joints)
    path = presence_path if presence_path is not None else ("face_eyes" if visible else "none")
    return {"t": t_ms, "session_t": 0.0, "detected": detected, "stale": False,
            "shoulders_available": visible, "shoulders_invalidated": invalidated,
            "presence_path": path,
            "face_detected": face_detected if face_detected is not None else visible,
            "neck": 0.9 if visible else None,
            "left_shoulder": 0.9 if visible else None,
            "right_shoulder": 0.9 if visible else None,
            "raw": {name: (0.9 if visible else None) for name in JOINTS},
            "joints": joints}


def header_row(version: str = "0.6.8", build: int = 25, commit: str = "c648a47") -> dict:
    """0.6.8 起会话日志的第一行：版本、构建号、commit。"""
    return {"ts": T0 - 1000, "event": "log_header", "message": f"{version} ({build}) {commit}"}


def calibration_row(at: float = 3.0, *, roll: float | None = 7.5,
                    head_height: float | None = 0.28) -> dict:
    return {"ts": T0 + int(at * 1000), "event": "calibration_done", "state": "good",
            "baseline_distance_cm": 40.0, "baseline_pitch_deg": 0.0,
            "baseline_roll_deg": roll, "baseline_head_height": head_height}


def feature_rows(seconds: int = DURATION, *, straight_roll: float = 3.0,
                 tilt_roll: float = 18.0, tilt_windows=((100, 130),)) -> list[dict]:
    """2 Hz 的特征行：坐正窗口里横滚 3°，歪头窗口里 18°；手到脸永远缺测（value null）。"""
    rows = []
    for second in range(0, seconds, 2):
        roll = tilt_roll if any(start <= second < end for start, end in tilt_windows) else straight_roll
        rows.append({"ts": T0 + second * 1000, "t": float(second), "event": "features",
                     "state": "good",
                     "feature_values": {
                         "head_roll": {"value": roll, "threshold": 15.0, "over": roll > 15.0},
                         "head_pitch": {"value": 0.0, "threshold": 20.0, "over": False},
                         "hand_to_face": {"value": None, "threshold": 0.12, "over": False}}})
    return rows


def null_sample_rows(seconds: int = 60, *, start: int = 0, frames: int | None = None) -> list[dict]:
    """10 Hz 的 sample 行：没有距离、没有俯仰——相机这一帧没量到任何脸（白墙）。

    `frames` 用来造「最后一个样本在 59.8 s、专注在 60.0 s 结束」这种真机/模拟器都常见的收尾。
    """
    count = seconds * 10 if frames is None else frames
    return [{"ts": T0 + (start + index / 10) * 1000, "event": "sample",
             "distance_cm": None, "pitch_deg": None, "state": "no_person"}
            for index in range(count)]


def pause_rows(spans: list[tuple[int, int]]) -> list[dict]:
    rows = []
    for start, end in spans:
        rows.append({"ts": T0 + start * 1000, "event": "paused", "state": "no_person"})
        rows.append({"ts": T0 + end * 1000, "event": "resumed", "state": "good"})
    return rows


def session_rows(second: int = DURATION, states=None, *,
                 pauses: list[tuple[int, int]] | None = None,
                 header: dict | None = None,
                 calibration: dict | None = None) -> list[dict]:
    """一段 10 分钟的会话：构建身份、静默校准、`status_changed` 体态窗口、最长无人暂停。"""
    windows = states if states is not None else [("head_tilt", 100, 130), ("head_down", 200, 230)]
    rows = [header if header is not None else header_row(),
            {"ts": T0, "event": "session_started", "state": "good"},
            calibration if calibration is not None else calibration_row()]
    for state, start, end in windows:
        rows.append({"ts": T0 + start * 1000, "event": "status_changed", "state": state})
        rows.append({"ts": T0 + end * 1000, "event": "status_changed", "state": "good"})
    rows += pause_rows([(400, 410)] if pauses is None else pauses)
    rows.append({"ts": T0 + second * 1000, "event": "session_ended", "state": "good",
                 "posture_stats": {"head_tilt": {"episodes": 1, "reminders": 0, "seconds": 30.0},
                                   "head_down": {"episodes": 1, "reminders": 1, "seconds": 30.0}}})
    return sorted(rows, key=lambda row: row["ts"])


def joints_window(seconds: int = DURATION, *, blank=((0, 60),)) -> list[dict]:
    """10 Hz 关节流：`blank` 区间是白墙——模型没有看到人，也没有任何在场证据。"""
    rows = []
    for index in range(seconds * 10):
        second = index / 10
        blank_now = any(start <= second < end for start, end in blank)
        rows.append(joint_row(T0 + index * 100, visible=not blank_now, detected=not blank_now))
    return rows


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
                     "degraded_seconds": 150 if degraded else 0,
                     # 0.6.8 (19)：静坐下的滚动 p95 与右肩累计帧数。
                     "keypoint_jitter_p95": 0.0062, "keypoint_still_frames": 300 * (second + 1),
                     "cloud_jitter_p95": 0.0134, "cloud_still_frames": 600 * (second + 1),
                     "right_shoulder_frames": 300, "shoulder_frames": 300,
                     "cloud_blank_with_face_frames": 0})
    return rows


def frame_rows(seconds: int, *, start: int = 0, points: int = 600,
               spacing: float = 1 / 30, degraded=False,
               face: bool | None = True) -> list[dict]:
    """逐帧记录：默认 30 Hz、每帧 600 点、同帧检测到脸、上屏点数为 points。"""
    rows = []
    count = int(seconds / spacing)
    for index in range(count):
        frame_s = start + index * spacing
        rows.append({"t": T0 + int(frame_s * 1000), "frame_s": round(frame_s, 4),
                     "arrival_s": round(frame_s + 0.002, 4), "depth_ms": 1.0,
                     "segment_ms": 82.0, "cloud_ms": 0.2, "points": points,
                     "mask_cells": 1200 if points else 0, "depth_valid": 0.98,
                     "nearest_m": 0.42, "degraded": degraded, "cloud_emitted": True,
                     "render_ms": 0.4, "render_latency_ms": 21.0,
                     "visible_points": points if points else 0, "face_detected": face})
    return rows


def joints_all(seconds: int = DURATION, **kwargs) -> list[dict]:
    return [joint_row(T0 + index * 100, **kwargs) for index in range(seconds * 10)]


def segment_rows(marks: list[tuple[int, str]]) -> list[dict]:
    """DEBUG 分段测试模式（`-segmentTest 1`）写的段标记：`ts` 是 epoch 毫秒，`message` 是段名。"""
    return [{"ts": T0 + second * 1000, "event": "test_segment", "message": name}
            for second, name in marks]


def joints_visible_in(seconds_windows: list[tuple[int, int]]) -> list[dict]:
    """只在给定秒区间里关节可见的 10 Hz 关节流：用来把「段标记窗口」与「status_changed 窗口」
    做成两个不同的分母。"""
    rows = []
    for index in range(DURATION * 10):
        second = index / 10
        visible = any(start <= second < end for start, end in seconds_windows)
        rows.append(joint_row(T0 + index * 100, visible=visible))
    return rows


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
            "joints": joints if joints is not None else joints_window(),
            "sessions": sessions if sessions is not None else session_rows() + feature_rows(),
            "perf": perf if perf is not None else perf_rows(DURATION),
            "frames": frames if frames is not None else frame_rows(DURATION),
        }

    # --- PASS ---------------------------------------------------------------

    def test_all_five_checks_pass(self):
        r = self.run_device_logs(**self.fixtures())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for name in ("upper-body-only", "shoulders-not-on-head",
                     "shoulders-available-ratio", "cloud-smooth", "degradation",
                     "log-header", "serious-cold-start", "calibration", "head-tilt",
                     "presence-path", "unmeasured-quiet", "pause-debounce",
                     "pause-during-head-down", "white-wall-absence"):
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
        r = self.run_device_logs(**self.fixtures(frames=frame_rows(DURATION, points=0, face=False)))
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
            sessions=session_rows() + thermal_rows([(0, 60)]) + feature_rows()))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("PASS degradation", r.stdout)

    # --- cloud-smooth：点数只要「有点云的帧固定」就算过 -----------------------

    def test_cloud_points_fixed_below_the_budget_pass(self):
        # 600 不再是判据：点数固定 480 也是「固定」，改预算不该让这条判定失效。
        r = self.run_device_logs(**self.fixtures(frames=frame_rows(DURATION, points=480)))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("PASS cloud-smooth", r.stdout)
        self.assertIn("点数固定为 480", r.stdout)

    def test_cloud_points_that_change_between_frames_fail(self):
        frames = frame_rows(300) + frame_rows(300, start=300, points=480)
        r = self.run_device_logs(**self.fixtures(frames=frames))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL cloud-smooth", r.stdout)
        self.assertIn("点数不固定", r.stdout)

    def test_cloud_with_too_few_pointed_frames_is_insufficient(self):
        # 只有 20 帧有点云（< 30）：点数固定这件事没有被验证过。
        frames = frame_rows(DURATION, points=0, face=False)
        for row in frames[:20]:
            row["points"] = 600
        r = self.run_device_logs(**self.fixtures(frames=frames))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("INSUFFICIENT_DATA cloud-smooth", r.stdout)
        self.assertIn("有点云", r.stdout)

    # --- 抖动与点云空白（issue #6 AC5 / AC7） --------------------------------

    def test_keypoint_jitter_over_one_percent_fails(self):
        perf = perf_rows(DURATION)
        for row in perf:
            row["keypoint_jitter_p95"] = 0.012
        r = self.run_device_logs(**self.fixtures(perf=perf))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL keypoint-jitter", r.stdout)
        self.assertIn("1.20%", r.stdout)

    def test_keypoint_jitter_at_the_limit_passes(self):
        perf = perf_rows(DURATION)
        for row in perf:
            row["keypoint_jitter_p95"] = 0.010
        r = self.run_device_logs(**self.fixtures(perf=perf))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("PASS keypoint-jitter", r.stdout)

    def test_cloud_jitter_over_two_percent_fails(self):
        perf = perf_rows(DURATION)
        for row in perf:
            row["cloud_jitter_p95"] = 0.025
        r = self.run_device_logs(**self.fixtures(perf=perf))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL cloud-jitter", r.stdout)

    def test_jitter_without_samples_is_insufficient(self):
        # 0.6.8 (18) 的日志没有抖动键：不能读成「零抖动」。
        perf = perf_rows(DURATION)
        for row in perf:
            row.pop("keypoint_jitter_p95", None)
            row.pop("cloud_jitter_p95", None)
        r = self.run_device_logs(**self.fixtures(perf=perf))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("INSUFFICIENT_DATA keypoint-jitter", r.stdout)
        self.assertIn("INSUFFICIENT_DATA cloud-jitter", r.stdout)

    def test_a_blank_cloud_while_a_face_is_detected_fails(self):
        frames = frame_rows(DURATION, points=600)
        for row in frames[300:330]:
            row["visible_points"] = 0
        r = self.run_device_logs(**self.fixtures(frames=frames))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL cloud-not-blank", r.stdout)

    def test_a_blank_cloud_without_face_evidence_is_insufficient(self):
        # 没检测到脸时「点云空白」不违反正文：没有可判对象。
        r = self.run_device_logs(**self.fixtures(frames=frame_rows(DURATION, face=False)))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("INSUFFICIENT_DATA cloud-not-blank", r.stdout)

    def test_cloud_never_blank_while_a_face_is_detected_passes(self):
        r = self.run_device_logs(**self.fixtures())
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("PASS cloud-not-blank", r.stdout)

    # --- 右肩可用帧 < 50%：只记录并上报，不改判定 -----------------------------

    def test_right_shoulder_below_half_is_reported_without_failing(self):
        perf = perf_rows(DURATION)
        for row in perf:
            row["right_shoulder_frames"] = 37
            row["shoulder_frames"] = 300
        r = self.run_device_logs(**self.fixtures(perf=perf))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("REPORT right-shoulder", r.stdout)
        self.assertIn("12.3%", r.stdout)
        self.assertIn("低于 50%", r.stdout)

    def test_right_shoulder_report_falls_back_to_the_joint_frames(self):
        perf = perf_rows(DURATION)
        for row in perf:
            row.pop("right_shoulder_frames", None)
            row.pop("shoulder_frames", None)
        joints = [joint_row(T0 + index * 100) for index in range(300)]
        r = self.run_device_logs(**self.fixtures(joints=joints, perf=perf))
        self.assertIn("REPORT right-shoulder", r.stdout)
        self.assertIn("300/300", r.stdout)

    # --- shoulders-available-ratio：坐直窗口来自 test_segment 段标记 --------
    # 段标记：300 s 起坐直 20 秒、320 起歪肩、340 起低头、360 起离开。
    MARKS = [(300, "坐直"), (320, "歪肩"), (340, "低头"), (360, "离开")]
    # 关节只在 300–320（坐直段）与两个体态窗口里可见：status_changed 的 good 窗口被这些空白帧
    # 拉低到几十分之一，段标记窗口是 100%。
    VISIBLE_ZONES = [(300, 320), (100, 130), (200, 230)]

    def test_the_straight_segment_marker_is_the_window_for_the_good_state(self):
        r = self.run_device_logs(**self.fixtures(
            joints=joints_visible_in(self.VISIBLE_ZONES),
            sessions=session_rows() + segment_rows(self.MARKS) + feature_rows()))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PASS shoulders-available-ratio", r.stdout)
        self.assertIn("坐直窗口来自 test_segment 段标记", r.stdout)

    def test_without_a_segment_marker_the_status_changed_window_still_applies(self):
        r = self.run_device_logs(**self.fixtures(
            joints=joints_visible_in(self.VISIBLE_ZONES)))
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("FAIL shoulders-available-ratio", r.stdout)
        self.assertIn("坐直窗口沿用 status_changed", r.stdout)


    # --- issue #8：日志首行、冷启动发热、校准、歪头、在场路径、未测、停表去抖 ---

    def test_a_missing_log_header_fails(self):
        r = self.run_device_logs(**self.fixtures(
            sessions=[row for row in session_rows() + feature_rows()
                      if row["event"] != "log_header"]))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL log-header", r.stdout)

    def test_an_unknown_commit_in_the_log_header_fails(self):
        r = self.run_device_logs(**self.fixtures(
            sessions=[header_row(commit="unknown")] + session_rows()[1:] + feature_rows()))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL log-header", r.stdout)
        self.assertIn("unknown", r.stdout)

    def test_serious_time_over_the_cold_start_share_fails(self):
        r = self.run_device_logs(**self.fixtures(
            perf=perf_rows(DURATION, degraded_seconds=set(range(0, 150)))))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL serious-cold-start", r.stdout)
        self.assertIn("25.0%", r.stdout)

    def test_serious_time_under_the_cold_start_share_passes(self):
        r = self.run_device_logs(**self.fixtures(
            perf=perf_rows(DURATION, degraded_seconds=set(range(0, 60)))))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("PASS serious-cold-start", r.stdout)

    def test_a_session_shorter_than_the_cold_start_window_is_insufficient(self):
        r = self.run_device_logs(**self.fixtures(
            sessions=session_rows(second=120) + feature_rows(120),
            perf=perf_rows(120),
            frames=frame_rows(120)))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("INSUFFICIENT_DATA serious-cold-start", r.stdout)

    def test_a_calibration_shorter_than_three_seconds_fails(self):
        r = self.run_device_logs(**self.fixtures(
            sessions=session_rows(calibration=calibration_row(at=2.0)) + feature_rows()))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL calibration", r.stdout)
        self.assertIn("短于 3 秒", r.stdout)

    def test_a_calibration_without_a_roll_baseline_fails(self):
        r = self.run_device_logs(**self.fixtures(
            sessions=session_rows(calibration=calibration_row(roll=None)) + feature_rows()))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL calibration", r.stdout)
        self.assertIn("baseline_roll_deg", r.stdout)

    def test_a_calibration_without_a_measured_head_height_passes_honestly(self):
        # 肩线不够时头高基线是 null：没测到就写 null，不是失败，也不是假的中位数。
        r = self.run_device_logs(**self.fixtures(
            sessions=session_rows(calibration=calibration_row(head_height=None)) + feature_rows()))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("PASS calibration", r.stdout)
        self.assertIn("头高基线未测", r.stdout)

    def test_a_calibration_that_never_finished_is_insufficient(self):
        rows = [row for row in session_rows() if row["event"] != "calibration_done"]
        rows.append({"ts": T0 + 3200, "event": "calibration_incomplete",
                     "message": "3 秒内有效横滚样本不足 10 个"})
        r = self.run_device_logs(**self.fixtures(sessions=sorted(rows, key=lambda r: r["ts"])
                                                 + feature_rows()))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("INSUFFICIENT_DATA calibration", r.stdout)

    def test_a_straight_three_minute_window_without_tilt_passes(self):
        r = self.run_device_logs(**self.fixtures())
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("PASS head-tilt", r.stdout)
        self.assertIn("180", r.stdout)

    def test_tilt_over_the_threshold_while_sitting_straight_fails(self):
        rows = [row for row in session_rows() if row["event"] != "calibration_done"]
        rows.append(calibration_row())
        r = self.run_device_logs(**self.fixtures(
            sessions=sorted(rows, key=lambda r: r["ts"]) + feature_rows(straight_roll=20.0)))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL head-tilt", r.stdout)

    def test_a_roll_reading_outside_the_folded_range_fails(self):
        r = self.run_device_logs(**self.fixtures(
            sessions=session_rows() + feature_rows(straight_roll=120.0)))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL head-tilt", r.stdout)
        self.assertIn("折回", r.stdout)

    def test_a_wrong_presence_path_fails(self):
        joints = joints_window()
        joints[300]["presence_path"] = "neck_shoulder"
        r = self.run_device_logs(**self.fixtures(joints=joints))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL presence-path", r.stdout)

    def test_frames_without_presence_keys_are_insufficient(self):
        joints = joints_window()
        for row in joints:
            row.pop("presence_path")
        r = self.run_device_logs(**self.fixtures(joints=joints))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("INSUFFICIENT_DATA presence-path", r.stdout)

    def test_an_unmeasured_reading_marked_over_fails(self):
        rows = feature_rows()
        rows[3]["feature_values"]["hand_to_face"] = {"value": None, "threshold": 0.12, "over": True}
        r = self.run_device_logs(**self.fixtures(sessions=session_rows() + rows))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL unmeasured-quiet", r.stdout)

    def test_a_pause_without_a_resume_pair_fails_the_debounce_rule(self):
        sessions = [row for row in session_rows() if row["event"] != "resumed"]
        sessions.append({"ts": T0 + 500_000, "event": "paused", "state": "no_person"})
        r = self.run_device_logs(**self.fixtures(
            sessions=sorted(sessions, key=lambda r: r["ts"]) + feature_rows()))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL pause-debounce", r.stdout)

    def test_a_pause_inside_a_head_down_window_fails(self):
        r = self.run_device_logs(**self.fixtures(
            sessions=session_rows(pauses=[(210, 215)]) + feature_rows()))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL pause-during-head-down", r.stdout)

    def test_no_head_down_window_is_insufficient_for_the_pause_rule(self):
        r = self.run_device_logs(**self.fixtures(
            sessions=session_rows(states=[("head_tilt", 100, 130)]) + feature_rows()))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("INSUFFICIENT_DATA pause-during-head-down", r.stdout)

    def test_a_white_wall_absence_without_false_presence_passes(self):
        r = self.run_device_logs(**self.fixtures())
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("PASS white-wall-absence", r.stdout)
        self.assertIn("60", r.stdout)

    def test_a_blank_frame_that_claims_presence_fails(self):
        joints = joints_window()
        joints[120]["presence_path"] = "face_eyes"
        r = self.run_device_logs(**self.fixtures(joints=joints))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("FAIL white-wall-absence", r.stdout)

    def test_white_wall_from_the_session_log_passes_without_joints(self):
        sessions = session_rows(states=[("no_person", 0, 60)]) + null_sample_rows(60)
        r = self.run_device_logs(joints=[], sessions=sessions, perf=perf_rows(DURATION),
                                 frames=frame_rows(DURATION))
        self.assertIn("PASS white-wall-absence", r.stdout)
        self.assertIn("60", r.stdout)

    def test_a_blank_stretch_that_runs_to_the_session_end_counts_to_the_end(self):
        # 59.8 s 的最后一个空样本、60.0 s 专注结束：这段空镜就是 60 秒，不能因为收尾少算一格判数据不足。
        sessions = session_rows(second=60, states=[("no_person", 0, 60)]) + null_sample_rows(0, frames=599)
        r = self.run_device_logs(joints=[], sessions=sessions, perf=perf_rows(DURATION),
                                 frames=frame_rows(DURATION))
        self.assertIn("PASS white-wall-absence", r.stdout)

    def test_a_posture_inside_the_blank_stretch_fails_the_white_wall_rule(self):
        sessions = (session_rows(states=[("near", 10, 20)]) + null_sample_rows(60))
        r = self.run_device_logs(joints=[], sessions=sessions, perf=perf_rows(DURATION),
                                 frames=frame_rows(DURATION))
        self.assertIn("FAIL white-wall-absence", r.stdout)

    def test_no_long_absence_window_is_insufficient_for_the_white_wall_rule(self):
        r = self.run_device_logs(**self.fixtures(joints=joints_window(blank=((0, 10),))))
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("INSUFFICIENT_DATA white-wall-absence", r.stdout)


if __name__ == "__main__":
    unittest.main()
