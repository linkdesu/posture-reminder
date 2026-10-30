#!/usr/bin/env python3
"""verify-session.py AC6 自测：多番茄日志按段重算、短日志 SKIP、真错仍然 FAIL。

  python3 scripts/test_verify_session.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify-session.py")
BASE = {"ts": 0, "state": "good", "screen": "pomodoro_main", "distance_cm": None, "pitch_deg": None}


def row(event, **kw):
    r = dict(BASE, event=event)
    r.update(kw)
    return r


def pomodoro(t0, seconds, good=None):
    """一段番茄钟：session_started、config、每 0.1 秒一个样本，最后 session_ended。"""
    rows = [row("session_started", scenario="pomodoroDay"),
            row("config", distance_threshold_cm=30, pitch_threshold_deg=20)]
    n = int(seconds * 10)
    rows += [row("sample", t=round(t0 + i / 10, 2), distance_cm=50.0, pitch_deg=0.0) for i in range(n + 1)]
    g = seconds if good is None else good
    rows.append(row("session_ended", total_seconds=seconds, good_seconds=g, near_seconds=0,
                    head_down_seconds=0, longest_good_streak_seconds=g))
    return rows


def break_samples(t0, seconds):
    return [row("sample", t=round(t0 + i / 10, 2), distance_cm=50.0, pitch_deg=0.0)
            for i in range(1, int(seconds * 10))]


def run(rows, *extra):
    # 放进干净的 Documents/debug/ 目录：P2 会扫日志所在目录有没有图像文件。
    with tempfile.TemporaryDirectory() as root:
        debug = os.path.join(root, "Documents", "debug")
        os.makedirs(debug)
        path = os.path.join(debug, "session-test.jsonl")
        with open(path, "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
        p = subprocess.run([sys.executable, SCRIPT, path, "--quiet", *extra],
                           capture_output=True, text=True)
        return p.returncode, p.stdout


class AC6(unittest.TestCase):
    def test_single_pomodoro_passes(self):
        code, out = run([row("screen_shown")] + pomodoro(0, 60))
        self.assertEqual(code, 0, out)
        self.assertIn("AC6 PASS: total_seconds", out)
        self.assertNotIn("without session_ended", out)

    def test_two_pomodoros_with_break_samples_pass(self):
        # r17 break-count 的形状：专注 60s → 休息 60s（照常记样本）→ 第二段专注（同一进程）。
        rows = pomodoro(0, 60) + break_samples(60, 60) + pomodoro(120, 60)
        code, out = run(rows)
        self.assertEqual(code, 0, out)
        self.assertIn("AC6[1/2] PASS: total_seconds", out)
        self.assertIn("AC6[2/2] PASS: total_seconds", out)

    def test_running_second_pomodoro_is_not_recomputed(self):
        rows = pomodoro(0, 60) + break_samples(60, 60) + [row("session_started")] + break_samples(120, 15)
        code, out = run(rows)
        self.assertEqual(code, 0, out)
        self.assertIn("AC6 INFO: 1 session(s) without session_ended", out)

    def test_short_log_is_skip_not_fail(self):
        code, out = run([row("screen_shown")])
        self.assertEqual(code, 0, out)
        self.assertIn("AC6 SKIP", out)

    def test_short_log_fails_when_summary_required(self):
        code, out = run([row("screen_shown")], "--expect-summary")
        self.assertEqual(code, 1, out)
        self.assertIn("AC6 FAIL: no session_ended", out)

    def test_head_down_is_recomputed_without_a_calibration_row(self):
        # 阅读流程退役后日志里不再有 calibration_done；引擎的基线此时是 0，重算必须照这个口径。
        rows = [row("session_started", scenario="headDown"),
                row("config", distance_threshold_cm=30, pitch_threshold_deg=20),
                row("status_changed", t=0.0, state="head_down")]
        rows += [row("sample", t=round(i / 10, 2), distance_cm=40.0, pitch_deg=-25.0) for i in range(101)]
        rows.append(row("session_ended", total_seconds=10.0, good_seconds=0,
                        near_seconds=0, head_down_seconds=10.0, longest_good_streak_seconds=0,
                        head_down_count=1, head_down_remind_count=1,
                        posture_stats={"head_down": {"episodes": 1, "reminders": 1, "seconds": 10.0}}))
        rows.append(row("reminder", t=5.0, alert_type="head_down", level=1, breach_seconds=5.0))
        code, out = run(rows, "--expect-level1", "5")
        self.assertEqual(code, 0, out)
        self.assertIn("AC6 PASS: head_down_seconds", out)
        self.assertIn("AC2 PASS: head_down level 1", out)

    def test_wrong_summary_still_fails(self):
        rows = pomodoro(0, 60) + break_samples(60, 60) + pomodoro(120, 60, good=40)
        code, out = run(rows)
        self.assertEqual(code, 1, out)
        self.assertIn("AC6[2/2] FAIL: good_seconds", out)


if __name__ == "__main__":
    unittest.main()
