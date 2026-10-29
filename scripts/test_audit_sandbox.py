#!/usr/bin/env python3
"""audit-sandbox.py 自测：系统写的文件不误报，真正的违规仍然 exit 1。

  python3 scripts/test_audit_sandbox.py
"""
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "audit-sandbox.py")
B = "me.xieal.posturelab.depth"

SYSTEM_FILES = [
    f"Library/Saved Application State/{B}.savedState/72821B2F/data.data",
    f"Library/Saved Application State/{B}.savedState/KnownSceneSessions/data.data",
    f"Library/Caches/{B}/com.apple.metal/functions.data",
    f"Library/Caches/{B}/com.apple.metal/libraries.list",
    f"Library/SplashBoard/Snapshots/sceneID:{B}-default/downscaled/A1.ktx",
    f"Library/SplashBoard/Snapshots/{B} - {{DEFAULT GROUP}}/52980168@3x.ktx",
    f"Library/Preferences/{B}.plist",
    f".com.apple.mobile_container_manager.metadata.plist",
]
APP_FILES = ["Documents/debug/session-2026.jsonl", "Documents/pomodoro-history.json"]


def make(root, files):
    for rel in files:
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write('{"event":"x"}\n' if rel.endswith(".jsonl") else "x")


def audit(files):
    with tempfile.TemporaryDirectory() as root:
        make(root, files)
        return subprocess.run([sys.executable, SCRIPT, root], capture_output=True, text=True)


class AuditSandboxTests(unittest.TestCase):
    def test_system_files_are_whitelisted(self):
        r = audit(SYSTEM_FILES + APP_FILES)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_image_in_documents_fails(self):
        self.assertEqual(audit(APP_FILES + ["Documents/frame-001.png"]).returncode, 1)

    def test_raw_depth_dump_fails(self):
        self.assertEqual(audit(APP_FILES + ["Documents/depth-dump.json"]).returncode, 1)

    def test_image_hidden_in_system_dir_fails(self):
        self.assertEqual(audit(SYSTEM_FILES + ["Library/Caches/x/shot.jpg"]).returncode, 1)

    def test_unknown_app_file_fails(self):
        self.assertEqual(audit(APP_FILES + ["Documents/blob.dat"]).returncode, 1)


if __name__ == "__main__":
    unittest.main()
