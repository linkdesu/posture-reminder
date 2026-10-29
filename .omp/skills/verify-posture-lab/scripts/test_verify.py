#!/usr/bin/env python3
"""verify.py 自测（不碰模拟器）：分批 evidence / down 只判本批跑过的场景；离开计数的判定。

  python3 .omp/skills/verify-posture-lab/scripts/test_verify.py
"""
import argparse
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("verify", HERE / "verify.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class Batch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        verify.RUNS = Path(self.tmp.name)
        self.run_id = "r99-batch"
        self.rd = verify.run_dir(self.run_id)
        self.rd.mkdir(parents=True)
        self.state = {"runId": self.run_id, "target": "sim", "udid": "SIM", "checks": {}}
        # 离线审计、模拟器命令一律打桩：这里只测判定逻辑。
        self._sh = verify.sh
        verify.sh = lambda cmd, **kw: subprocess.CompletedProcess(cmd, 0, "PASS\n", "")
        self._term, self._booted = verify.terminate_sim, verify.sim_booted
        verify.terminate_sim = lambda sim: None
        verify.sim_booted = lambda sim: False

    def tearDown(self):
        verify.sh, verify.terminate_sim, verify.sim_booted = self._sh, self._term, self._booted
        self.tmp.cleanup()

    def save(self):
        verify.write_state(self.run_id, self.state)

    def ns(self, **kw):
        return argparse.Namespace(run=self.run_id, preflight_only=False, **kw)

    def test_drive_only_batch_passes_evidence_and_down(self):
        # 本批只跑了 drive 扩展场景（如 r17：break-count + settings-*），核心场景都没跑。
        self.state["checks"]["drive:break-count"] = {"ok": True}
        self.state["checks"]["drive:settings-toggle"] = {"ok": True}
        self.save()
        self.assertEqual(verify.command_evidence(self.ns()), 0)
        summary = json.loads((self.rd / "verification.json").read_text())
        self.assertTrue(summary["ok"], summary)
        self.assertEqual(set(summary["skipped"]), set(verify.CORE_SCENARIOS))
        self.assertNotIn("pomodoro-focus:log", summary["results"])
        self.assertEqual(verify.command_down(self.ns()), 0)

    def test_settings_only_batch_judges_settings(self):
        sdir = self.rd / "scenarios" / "settings"
        sdir.mkdir(parents=True)
        (sdir / "provenance.json").write_text("{}")
        (sdir / "settings.png").write_bytes(b"x")
        (sdir / "sandbox-audit.json").write_text("{}")
        self.save()
        self.assertEqual(verify.command_evidence(self.ns()), 0)
        summary = json.loads((self.rd / "verification.json").read_text())
        self.assertEqual(summary["ran"], ["settings"])
        self.assertTrue(summary["results"]["settings:screenshot"])

    def test_ran_scenario_without_log_still_fails(self):
        sdir = self.rd / "scenarios" / "pause"
        sdir.mkdir(parents=True)
        (sdir / "provenance.json").write_text("{}")
        self.save()
        self.assertEqual(verify.command_evidence(self.ns()), 1)
        summary = json.loads((self.rd / "verification.json").read_text())
        self.assertFalse(summary["results"]["pause:log"])

    def test_failed_drive_check_fails_evidence(self):
        self.state["checks"]["drive:abandon-count"] = {"ok": False}
        self.save()
        self.assertEqual(verify.command_evidence(self.ns()), 1)

    def test_empty_batch_is_not_a_pass(self):
        self.save()
        self.assertEqual(verify.command_evidence(self.ns()), 1)

    def test_down_still_requires_pomodoro_focus_files_when_it_ran(self):
        sdir = self.rd / "scenarios" / "pomodoro-focus"
        sdir.mkdir(parents=True)
        (sdir / "provenance.json").write_text("{}")
        self.save()
        verify.command_evidence(self.ns())
        self.assertEqual(verify.command_down(self.ns()), 1)  # 缺 mid-focus.png


class AbandonJudge(unittest.TestCase):
    def test_unchanged_count_passes(self):
        ok, _ = verify.judge_abandon_count(
            {"before": "0", "after": "0", "goal": "6", "endTapped": "true", "reset": "true"},
            (0, 6), (0, 6))
        self.assertTrue(ok)

    def test_increment_fails(self):
        ok, why = verify.judge_abandon_count(
            {"before": "0", "after": "1", "goal": "6", "endTapped": "true", "reset": "true"},
            (0, 6), (1, 6))
        self.assertFalse(ok, why)

    def test_ocr_disagreeing_with_ui_fails(self):
        ok, _ = verify.judge_abandon_count(
            {"before": "0", "after": "0", "goal": "6", "endTapped": "true", "reset": "true"},
            (0, 6), (1, 6))
        self.assertFalse(ok)

    def test_end_not_tapped_fails(self):
        ok, _ = verify.judge_abandon_count(
            {"before": "0", "after": "0", "goal": "6", "endTapped": "false", "reset": "true"},
            (0, 6), (0, 6))
        self.assertFalse(ok)


if __name__ == "__main__":
    unittest.main()
