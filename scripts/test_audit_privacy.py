#!/usr/bin/env python3
"""audit-privacy.py 自测：白名单真的拦得住越界符号，规定文案真的被校验。

  python3 scripts/test_audit_privacy.py
"""
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "audit-privacy.py")

PROJECT_OK = """\
settings:
  base:
    INFOPLIST_KEY_NSCameraUsageDescription: "用于在本机识别坐姿，画面不会显示、保存或上传"
    INFOPLIST_KEY_CFBundleDisplayName: "PostureLab"
"""

OK_FILES = {
    "Input/VisionJointSource.swift": "let r = VNDetectHumanBodyPoseRequest()\n",
    "Input/DepthCaptureSource.swift": (
        "let o = AVCaptureVideoDataOutput()\n"
        "func f(_ b: CMSampleBufferGetImageBuffer) {}\n"
    ),
    "Domain/PostureClassifier.swift": "// 注释里提到 AVCaptureVideoPreviewLayer 不算\nlet x = 1\n",
}


def audit(files=None, project=PROJECT_OK):
    with tempfile.TemporaryDirectory() as root:
        for rel, body in (files or OK_FILES).items():
            path = os.path.join(root, "PostureLab", rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as handle:
                handle.write(body)
        project_path = os.path.join(root, "project.yml")
        with open(project_path, "w") as handle:
            handle.write(project)
        return subprocess.run(
            [sys.executable, SCRIPT,
             "--root", os.path.join(root, "PostureLab"), "--project", project_path],
            capture_output=True, text=True)


class AuditPrivacyTests(unittest.TestCase):
    def test_whitelisted_boundary_passes(self):
        self.assertEqual(audit().returncode, 0, audit().stdout)

    def test_vision_outside_whitelist_fails(self):
        files = dict(OK_FILES)
        files["Domain/PostureClassifier.swift"] = "let r = VNDetectHumanBodyPoseRequest()\n"
        self.assertEqual(audit(files).returncode, 1)

    def test_video_output_outside_capture_fails(self):
        files = dict(OK_FILES)
        files["Views/AvatarView.swift"] = "let o = AVCaptureVideoDataOutput()\n"
        self.assertEqual(audit(files).returncode, 1)

    def test_preview_layer_fails(self):
        files = dict(OK_FILES)
        files["Views/PomodoroView.swift"] = "let l = AVCaptureVideoPreviewLayer()\n"
        self.assertEqual(audit(files).returncode, 1)

    def test_image_encoding_fails(self):
        files = dict(OK_FILES)
        files["Debug/FileDebugLogger.swift"] = "let d = buffer.jpegData()\n"
        self.assertEqual(audit(files).returncode, 1)

    def test_network_api_fails(self):
        files = dict(OK_FILES)
        files["App.swift"] = "let s = URLSession.shared\n"
        self.assertEqual(audit(files).returncode, 1)

    def test_camera_copy_is_exact(self):
        bad = PROJECT_OK.replace("画面不会显示、保存或上传", "画面不会上传")
        self.assertEqual(audit(project=bad).returncode, 1)

    def test_display_name_is_posturelab(self):
        bad = PROJECT_OK.replace('"PostureLab"', '"PostureLab 深度版"')
        self.assertEqual(audit(project=bad).returncode, 1)


if __name__ == "__main__":
    unittest.main()
