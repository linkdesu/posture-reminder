#!/usr/bin/env python3
"""PostureLab 验证运行器：构建、启动、健康检查、场景驱动、取证与清理。

用法：
  .omp/skills/verify-posture-lab/scripts/verify.py up --run <run-id>
  .omp/skills/verify-posture-lab/scripts/verify.py doctor --run <run-id>
  .omp/skills/verify-posture-lab/scripts/verify.py drive --run <run-id>
  .omp/skills/verify-posture-lab/scripts/verify.py evidence --run <run-id>
  .omp/skills/verify-posture-lab/scripts/verify.py down --run <run-id>

所有证据写入 tmp/verify/<run-id>/，并维护 tmp/verify/latest 软链接。脚本从不写 artifacts/。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
RUNS = ROOT / "tmp" / "verify"
BUILD = Path("/tmp/pl-verify-build")
BUNDLE = "me.xieal.posturelab"
DEFAULT_SIM = "C12DA589-2444-4F2E-A943-4D6BAFB02BF1"
DEFAULT_DEVICE = "00008110-001271181AD3801E"
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"

# 与 docs/qa-log-schema.md 的 38 键契约一致；顺序无关，集合必须完全相等。
LOG_KEYS = {
    "ts", "t", "wall_clock", "event", "state", "screen", "distance_cm",
    "pitch_deg", "alert_type", "level", "breach_seconds", "sensitivity",
    "distance_threshold_cm", "pitch_threshold_deg", "baseline_distance_cm",
    "baseline_pitch_deg", "total_seconds", "good_seconds", "near_seconds",
    "head_down_seconds", "paused_seconds", "near_count", "near_remind_count",
    "head_down_count", "head_down_remind_count", "longest_good_streak_seconds",
    "scenario", "message", "battery_level", "thermal_state",
    "highlighted_feature", "feature_values", "view_mode", "overlay_on",
    "avatar_on", "posture_stats", "remaining_seconds", "phase",
}


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def env() -> dict[str, str]:
    e = os.environ.copy()
    e["DEVELOPER_DIR"] = DEVELOPER_DIR
    return e


def sh(cmd: list[str], *, check: bool = True, log: Path | None = None,
       timeout: int = 1800) -> subprocess.CompletedProcess:
    result = subprocess.run(cmd, cwd=ROOT, env=env(), text=True,
                            capture_output=True, timeout=timeout)
    if log is not None:
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(
            "$ " + " ".join(cmd) + "\n\n"
            + result.stdout + result.stderr
            + f"\n[exit {result.returncode}]\n"
        )
    if check and result.returncode != 0:
        sys.exit(f"命令失败（{result.returncode}）：{' '.join(cmd)}\n{result.stdout}{result.stderr}")
    return result


def sh_out(cmd: list[str], *, check: bool = True) -> str:
    return sh(cmd, check=check).stdout.strip()


def run_dir(run_id: str) -> Path:
    return RUNS / run_id


def state_file(run_id: str) -> Path:
    return run_dir(run_id) / "state.json"


def read_state(run_id: str) -> dict:
    path = state_file(run_id)
    if not path.exists():
        sys.exit(f"没有 state.json：{path}；先运行 up --run {run_id}")
    return json.loads(path.read_text())


def write_state(run_id: str, state: dict) -> None:
    state["updatedAt"] = now()
    path = state_file(run_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
    latest = RUNS / "latest"
    latest.parent.mkdir(parents=True, exist_ok=True)
    if latest.is_symlink() or latest.exists():
        latest.unlink()
    latest.symlink_to(path.parent, target_is_directory=True)


def check(state: dict, name: str, ok: bool, detail: str) -> bool:
    state.setdefault("checks", {})[name] = {
        "ok": bool(ok), "detail": detail, "at": now()
    }
    print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}")
    return ok


def resolve_run(arg: str | None) -> str:
    if arg:
        return arg
    latest = RUNS / "latest"
    if latest.exists():
        return latest.resolve().name
    sys.exit("缺少 --run，且 tmp/verify/latest 不存在")


def sim_booted(sim: str) -> bool:
    out = sh_out(["xcrun", "simctl", "list", "devices"], check=False)
    return any(sim in line and "(Booted)" in line for line in out.splitlines())


def boot(sim: str, state: dict) -> None:
    if sim_booted(sim):
        state["bootedByUs"] = False
        return
    sh(["xcrun", "simctl", "boot", sim], check=False)
    sh(["xcrun", "simctl", "bootstatus", sim, "-b"], check=False, timeout=300)
    state["bootedByUs"] = True


def build_sim(sim: str, run_id: str) -> None:
    log = run_dir(run_id) / "logs" / "build.log"
    sh(["xcodebuild", "-project", "PostureLab.xcodeproj", "-scheme", "PostureLab",
        "-destination", f"platform=iOS Simulator,id={sim}",
        "-derivedDataPath", str(BUILD), "build"], log=log)


def app_path() -> Path:
    return BUILD / "Build" / "Products" / "Debug-iphonesimulator" / "PostureLab.app"


def install_sim(sim: str) -> None:
    sh(["xcrun", "simctl", "terminate", sim, BUNDLE], check=False)
    sh(["xcrun", "simctl", "uninstall", sim, BUNDLE], check=False)
    sh(["xcrun", "simctl", "install", sim, str(app_path())])


def launch_sim(sim: str, args: list[str]) -> int:
    out = sh_out(["xcrun", "simctl", "launch", sim, BUNDLE, *args])
    # 输出形如：me.xieal.posturelab: 12345
    tail = out.rsplit(":", 1)[-1].strip()
    return int(tail) if tail.isdigit() else 0


def terminate_sim(sim: str) -> None:
    sh(["xcrun", "simctl", "terminate", sim, BUNDLE], check=False)


def screenshot(sim: str, dest: Path) -> bool:
    # 模拟器无法直接写这个卷，先写 /tmp 再复制。
    scratch = Path(f"/tmp/pl-verify-{os.getpid()}-{time.time_ns()}.png")
    result = sh(["xcrun", "simctl", "io", sim, "screenshot", str(scratch)], check=False)
    if result.returncode != 0 or not scratch.exists():
        return False
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(scratch, dest)
    scratch.unlink(missing_ok=True)
    return True


def container_sim(sim: str) -> str:
    return sh_out(["xcrun", "simctl", "get_app_container", sim, BUNDLE, "data"])


def copy_documents(container: str, dest: Path) -> None:
    src = Path(container) / "Documents"
    if dest.exists():
        shutil.rmtree(dest)
    if src.exists():
        shutil.copytree(src, dest)


def newest_log(scenario_dir: Path) -> Path | None:
    logs = sorted(scenario_dir.glob("Documents/debug/session-*.jsonl"))
    return logs[-1] if logs else None


def history_file(scenario_dir: Path) -> Path:
    return scenario_dir / "Documents" / "pomodoro-history.json"


def audit_sandbox(container: str, dest: Path) -> subprocess.CompletedProcess:
    return sh([sys.executable, "scripts/audit-sandbox.py", container, "--json", str(dest)],
              check=False)


def launch_and_capture(sim: str, scenario: str, args: list[str], shots: list[tuple[int, str]],
                       run_id: str) -> dict:
    """重装、启动一个场景，按相对秒数截图，导出 Documents 与沙盒审计。"""
    out = run_dir(run_id) / "scenarios" / scenario
    out.mkdir(parents=True, exist_ok=True)
    (out / "launch-args.txt").write_text(" ".join(args) + "\n")
    install_sim(sim)
    t0 = time.time()
    pid = launch_sim(sim, args)
    for delay, name in shots:
        wait = delay - (time.time() - t0)
        if wait > 0:
            time.sleep(wait)
        ok = screenshot(sim, out / name)
        print(f"{'PASS' if ok else 'FAIL'} shot:{scenario}:{name}: {out / name}")
        if scenario == "pomodoro-focus" and name == "after-focus.png":
            live = Path(container_sim(sim)) / "Documents" / "debug"
            logs = sorted(live.glob("session-*.jsonl"))
            if logs:
                shutil.copy2(logs[-1], out / "session-at-70.jsonl")
    container = container_sim(sim)
    audit = audit_sandbox(container, out / "sandbox-audit.json")
    copy_documents(container, out / "Documents")
    terminate_sim(sim)
    log = newest_log(out)
    provenance = {
        "scenario": scenario,
        "launchArgs": args,
        "pid": pid,
        "gitSha": sh_out(["git", "rev-parse", "HEAD"]),
        "container": container,
        "log": str(log.relative_to(out)) if log else None,
        "history": str(history_file(out).relative_to(out)) if history_file(out).exists() else None,
        "sandboxAuditExit": audit.returncode,
        "when": now(),
    }
    (out / "provenance.json").write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + "\n")
    return provenance


def command_up(args) -> int:
    run_id = args.run
    rd = run_dir(run_id)
    rd.mkdir(parents=True, exist_ok=True)
    state = {
        "runId": run_id,
        "gitSha": sh_out(["git", "rev-parse", "HEAD"]),
        "branch": sh_out(["git", "rev-parse", "--abbrev-ref", "HEAD"]),
        "target": args.target,
        "deviceId": args.udid or (DEFAULT_SIM if args.target == "sim" else DEFAULT_DEVICE),
        "udid": args.udid or (DEFAULT_SIM if args.target == "sim" else DEFAULT_DEVICE),
        "bundleId": BUNDLE,
        "appContainerDataPath": "",
        "startedAt": now(),
        "updatedAt": now(),
        "checks": {},
    }
    if args.target == "device":
        state["appContainerDataPath"] = "(device: use devicectl copy)"
        write_state(run_id, state)
        check(state, "up", False, "device 目标请按 SKILL.md 用 devicectl 构建/安装/启动")
        write_state(run_id, state)
        return 0

    sim = state["udid"]
    boot(sim, state)
    if not args.skip_build:
        build_sim(sim, run_id)
    install_sim(sim)
    pid = launch_sim(sim, args.launch or [])
    time.sleep(4)
    container = container_sim(sim)
    state["pid"] = pid
    state["appContainerDataPath"] = container
    ok = screenshot(sim, rd / "launch" / "pomodoro_main.png")
    check(state, "launch", ok and bool(container), f"pid={pid} container={container}")
    write_state(run_id, state)
    return 0


def command_doctor(args) -> int:
    run_id = resolve_run(args.run)
    state = read_state(run_id)
    rd = run_dir(run_id)
    checks: dict[str, dict] = {}
    if state["target"] != "sim":
        checks["target"] = {"ok": False, "detail": "Doctor 目前只实现模拟器目标"}
    else:
        sim = state["udid"]
        checks["simulatorBooted"] = {"ok": sim_booted(sim), "detail": sim}
        processes = sh_out(["xcrun", "simctl", "spawn", sim, "launchctl", "list"], check=False)
        running = BUNDLE in processes
        checks["processRunning"] = {"ok": running, "detail": BUNDLE}
        container = sh(["xcrun", "simctl", "get_app_container", sim, BUNDLE, "data"],
                       check=False)
        checks["container"] = {"ok": container.returncode == 0,
                               "detail": container.stdout.strip()}
        if container.returncode == 0:
            state["appContainerDataPath"] = container.stdout.strip()
        pid = 0
        for line in processes.splitlines():
            if BUNDLE in line:
                head = line.split()[0]
                pid = int(head) if head.isdigit() else 0
                break
        state["pid"] = pid
        app = sh(["xcrun", "simctl", "get_app_container", sim, BUNDLE, "app"],
                 check=False)
        version = ""
        if app.returncode == 0:
            v = sh(["plutil", "-extract", "CFBundleShortVersionString", "raw",
                    str(Path(app.stdout.strip()) / "Info.plist")], check=False)
            version = v.stdout.strip() if v.returncode == 0 else ""
        checks["version"] = {"ok": bool(version), "detail": version}
        checks["gitSha"] = {"ok": state["gitSha"] == sh_out(["git", "rev-parse", "HEAD"]),
                            "detail": state["gitSha"]}
    ok = all(entry["ok"] for entry in checks.values())
    (rd / "doctor.json").write_text(json.dumps({"when": now(), "ok": ok, "checks": checks},
                                               ensure_ascii=False, indent=2) + "\n")
    state.setdefault("checks", {})["doctor"] = {"ok": ok, "detail": checks, "at": now()}
    write_state(run_id, state)
    print(json.dumps(checks, ensure_ascii=False, indent=2))
    return 0 if ok else 1


def command_drive(args) -> int:
    run_id = resolve_run(args.run)
    state = read_state(run_id)
    if state["target"] != "sim":
        sys.exit("drive 目前只实现模拟器目标；真机步骤见 SKILL.md")
    sim = state["udid"]
    scenarios = [
        ("pomodoro-focus",
         ["-scenario", "pomodoroDay", "-focusMinutes", "1",
          "-shortBreakMinutes", "1", "-voice", "1", "-debug", "1", "-endSound", "chime"],
         [(35, "mid-focus.png"), (70, "after-focus.png"), (130, "history-ready.png")]),
        ("posture-voice",
         ["-scenario", "deskLean", "-focusMinutes", "1",
          "-shortBreakMinutes", "1", "-voice", "1", "-debug", "1"],
         [(30, "desk-lean.png")]),
        ("pause",
         ["-scenario", "pauseWhileBreach", "-focusMinutes", "1", "-debug", "0"],
         [(30, "absence-pause.png")]),
        ("settings",
         ["-settings", "1"],
         [(5, "settings.png")]),
    ]
    for scenario, launch, shots in scenarios:
        provenance = launch_and_capture(sim, scenario, launch, shots, run_id)
        state.setdefault("scenarios", {})[scenario] = provenance
        write_state(run_id, state)

    # 统计页：先 seed 三个范围，再杀进程无 seed 重开，证明历史来自磁盘。
    report_dir = run_dir(run_id) / "scenarios" / "report"
    report_dir.mkdir(parents=True, exist_ok=True)
    install_sim(sim)
    launch_sim(sim, ["-seedHistory", "30", "-report", "day"])
    time.sleep(6)
    screenshot(sim, report_dir / "report-day.png")
    container = container_sim(sim)
    audit_sandbox(container, report_dir / "sandbox-audit.json")
    copy_documents(container, report_dir / "Documents")
    before = len(json.loads(history_file(report_dir).read_text())) if history_file(report_dir).exists() else 0
    terminate_sim(sim)
    # 不重装：历史必须来自同一个沙盒，否则证明的只是 seed，不是持久化。
    launch_sim(sim, ["-report", "day"])
    time.sleep(6)
    screenshot(sim, report_dir / "report-day-after-restart.png")
    container = container_sim(sim)
    copy_documents(container, report_dir / "Documents-after-restart")
    after = len(json.loads((report_dir / "Documents-after-restart" / "pomodoro-history.json").read_text())) \
        if (report_dir / "Documents-after-restart" / "pomodoro-history.json").exists() else 0
    terminate_sim(sim)
    (report_dir / "report-persistence.json").write_text(json.dumps(
        {"recordsBefore": before, "recordsAfterRestart": after, "ok": before > 0 and before == after},
        ensure_ascii=False, indent=2) + "\n")
    state.setdefault("checks", {})["reportPersistence"] = {
        "ok": before > 0 and before == after,
        "detail": f"before={before} after={after}", "at": now()}
    write_state(run_id, state)
    print(f"report persistence: before={before} after={after}")
    return 0


def run_py(script: str, *args: str, out: Path) -> bool:
    result = sh([sys.executable, f"scripts/{script}", *args], check=False)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("$ " + " ".join([sys.executable, f"scripts/{script}", *args])
                   + "\n\n" + result.stdout + result.stderr
                   + f"\n[exit {result.returncode}]\n")
    return result.returncode == 0


def check_contract(log: Path, out: Path) -> bool:
    bad = []
    rows = 0
    for number, line in enumerate(log.read_text().splitlines(), 1):
        if not line.strip():
            continue
        rows += 1
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            bad.append(f"line {number}: invalid JSON: {error}")
            continue
        missing = LOG_KEYS - set(row)
        extra = set(row) - LOG_KEYS
        if missing or extra:
            bad.append(f"line {number}: missing={sorted(missing)} extra={sorted(extra)}")
    ok = rows > 0 and not bad
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        f"log={log}\nrows={rows}\nkeys={len(LOG_KEYS)}\n"
        + ("PASS: every line carries exactly the 38-key contract\n" if ok
           else "FAIL:\n" + "\n".join(bad) + "\n")
    )
    return ok


def command_evidence(args) -> int:
    run_id = resolve_run(args.run)
    state = read_state(run_id)
    rd = run_dir(run_id)
    results: dict[str, bool] = {}

    offline = rd / "audits" / "offline.txt"
    offline.parent.mkdir(parents=True, exist_ok=True)
    r = sh([sys.executable, "scripts/audit-offline.py"], check=False)
    offline.write_text(r.stdout + r.stderr + f"\n[exit {r.returncode}]\n")
    results["offline"] = r.returncode == 0

    for scenario in ("pomodoro-focus", "posture-voice", "pause", "report", "settings"):
        sdir = rd / "scenarios" / scenario
        ver = sdir / "verification"
        log = newest_log(sdir)
        if log is not None:
            results[f"{scenario}:contract"] = check_contract(log, ver / "contract.txt")
        elif scenario in ("pomodoro-focus", "posture-voice", "pause"):
            results[f"{scenario}:log"] = False
            continue
        history = history_file(sdir)
        if scenario == "pomodoro-focus":
            results["pomodoro-focus:ac1"] = run_py(
                "verify-acceptance.py", str(log), "--ac1", "--quiet",
                out=ver / "ac1.txt")
            history_log = sdir / "session-at-70.jsonl"
            results["pomodoro-focus:history"] = run_py(
                "verify-pomodoro.py", str(history_log), "--history", str(history),
                "--expect-records", "1", "--expect-focus-seconds", "60", "--quiet",
                out=ver / "history.txt")
        elif scenario == "posture-voice":
            results["posture-voice:ac4"] = run_py(
                "verify-acceptance.py", str(log), "--ac4", "--quiet",
                out=ver / "ac4.txt")
        elif scenario == "pause":
            results["pause:ac5"] = run_py(
                "verify-acceptance.py", str(log), "--history", str(history),
                "--ac5", "--quiet", out=ver / "ac5.txt")
        elif scenario == "report":
            persistence = sdir / "report-persistence.json"
            results["report:persistence"] = persistence.exists() and json.loads(
                persistence.read_text()).get("ok") is True
        elif scenario == "settings":
            results["settings:screenshot"] = (sdir / "settings.png").exists()

        audit = sdir / "sandbox-audit.json"
        results[f"{scenario}:sandbox"] = audit.exists()

    summary = {"when": now(), "runId": run_id, "results": results,
               "ok": all(results.values())}
    (rd / "verification.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    state.setdefault("checks", {})["evidence"] = {
        "ok": summary["ok"], "detail": results, "at": now()}
    write_state(run_id, state)
    print(json.dumps(results, ensure_ascii=False, indent=2))
    return 0 if summary["ok"] else 1


def command_down(args) -> int:
    run_id = resolve_run(args.run)
    state = read_state(run_id)
    rd = run_dir(run_id)
    if state["target"] == "sim":
        sim = state["udid"]
        terminate_sim(sim)
        if state.get("bootedByUs"):
            sh(["xcrun", "simctl", "shutdown", sim], check=False)
    state["pid"] = 0
    state["checks"]["cleanup"] = {"ok": True, "detail": "app terminated; evidence kept", "at": now()}
    write_state(run_id, state)
    expected = ["state.json", "launch/pomodoro_main.png", "verification.json",
                "scenarios/pomodoro-focus/mid-focus.png",
                "scenarios/pomodoro-focus/provenance.json",
                "audits/offline.txt"]
    missing = [item for item in expected if not (rd / item).exists()]
    print("cleanup: evidence kept at", rd)
    if missing:
        print("missing evidence:", ", ".join(missing))
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="PostureLab 验证运行器")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("up", "doctor", "drive", "evidence", "down"):
        p = sub.add_parser(name)
        p.add_argument("--run", default=None)
        if name == "up":
            p.add_argument("--target", choices=["sim", "device"], default="sim")
            p.add_argument("--udid", default=None)
            p.add_argument("--skip-build", action="store_true")
            p.add_argument("--launch", nargs="*", default=None)
    args = parser.parse_args()
    if args.command == "up" and args.run is None:
        parser.error("up 需要 --run <run-id>")
    return {
        "up": command_up,
        "doctor": command_doctor,
        "drive": command_drive,
        "evidence": command_evidence,
        "down": command_down,
    }[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
