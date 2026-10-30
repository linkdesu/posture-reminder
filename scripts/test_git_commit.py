#!/usr/bin/env python3
"""GitCommit 构建脚本自测：commit 的三种来源（git 仓库 / GIT_COMMIT / .verify-commit）。

脚本本体在 project.yml 里（xcodegen 生成的工程直接内联它），所以测试从 project.yml 抽出来跑，
测的就是真正会被 Xcode 执行的那段 shell。

  python3 scripts/test_git_commit.py
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT_INDENT = " " * 10


def git_commit_script() -> str:
    lines = (ROOT / "project.yml").read_text().splitlines()
    name_at = next(i for i, line in enumerate(lines) if line.strip() == "- name: GitCommit")
    script_at = next(i for i in range(name_at, len(lines)) if lines[i].strip() == "script: |")
    body = []
    for line in lines[script_at + 1:]:
        if line.strip() and not line.startswith(SCRIPT_INDENT):
            break
        body.append(line[len(SCRIPT_INDENT):])
    assert body, "project.yml 里的 GitCommit 脚本是空的"
    return "\n".join(body) + "\n"


# 固定的仓库 fixture：内容、作者、时间都钉死，HEAD 是这两个已知字面量，不靠 git 现场算。
FIXTURE_SHA = "ab59d0ca8e6f7e8a173813ae172ac05593a0526e"
FIXTURE_SHORT = "ab59d0c"


def make_repo(path: Path) -> None:
    path.mkdir(parents=True)
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@e",
        "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@e",
        "GIT_AUTHOR_DATE": "2020-01-01T00:00:00Z",
        "GIT_COMMITTER_DATE": "2020-01-01T00:00:00Z",
    }
    (path / "f.txt").write_text("x\n")
    for cmd in (["git", "init", "-q", "--object-format=sha1"],
                ["git", "add", "f.txt"],
                ["git", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "m"]):
        subprocess.run(cmd, cwd=path, env=env, check=True)


class GitCommit(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.src = base / "src"
        self.products = base / "products"
        self.out = self.products / "PostureLab.app" / "GitCommit.txt"
        self.out.parent.mkdir(parents=True)
        self.empty_path = base / "empty-path"
        self.empty_path.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *, with_git: bool, git_commit: str | None = None,
                   marker: str | None = None) -> subprocess.CompletedProcess:
        env = {
            "PATH": os.environ["PATH"] if with_git else str(self.empty_path),
            "BUILT_PRODUCTS_DIR": str(self.products),
            "UNLOCALIZED_RESOURCES_FOLDER_PATH": "PostureLab.app",
            "SRCROOT": str(self.src),
        }
        if git_commit is not None:
            env["GIT_COMMIT"] = git_commit
        if marker is not None:
            self.src.mkdir(exist_ok=True)
            (self.src / ".verify-commit").write_text(marker + "\n")
        return subprocess.run(["/bin/sh", "-c", git_commit_script()], env=env,
                              text=True, capture_output=True)

    def commit_written(self) -> str:
        return self.out.read_text().strip()

    def test_git_repository_wins(self):
        make_repo(self.src)
        result = self.run_script(with_git=True, git_commit="deadbeef", marker="cafebabe")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commit_written(), FIXTURE_SHORT)

    def test_env_var_used_without_git(self):
        self.src.mkdir()
        result = self.run_script(with_git=False, git_commit=FIXTURE_SHA)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commit_written(), FIXTURE_SHA)

    def test_verify_commit_file_used_without_git(self):
        result = self.run_script(with_git=False, marker=FIXTURE_SHA)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commit_written(), FIXTURE_SHA)

    def test_env_var_beats_verify_commit_file(self):
        result = self.run_script(with_git=False, git_commit=FIXTURE_SHA,
                                 marker="cafebabe")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commit_written(), FIXTURE_SHA)

    def test_fails_loudly_without_any_source(self):
        self.src.mkdir()
        result = self.run_script(with_git=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GIT_COMMIT", result.stderr)
        self.assertIn(".verify-commit", result.stderr)
        self.assertFalse(self.out.exists(), "缺 commit 时不能写出任何占位值")

    def test_fails_when_not_a_repository(self):
        self.src.mkdir()
        result = self.run_script(with_git=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(".verify-commit", result.stderr)
        self.assertFalse(self.out.exists())


if __name__ == "__main__":
    unittest.main()
