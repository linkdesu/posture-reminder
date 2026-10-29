#!/usr/bin/env python3
"""PostureLab 验证运行器：构建、启动、健康检查、场景驱动、取证与清理。

用法：
  .omp/skills/verify-posture-lab/scripts/verify.py preflight --sha <SHA> --version <x.y.z> --build <N> --slug <slug>
  .omp/skills/verify-posture-lab/scripts/verify.py up --run <run-id>
  .omp/skills/verify-posture-lab/scripts/verify.py doctor --run <run-id> [--version x.y.z --build N]
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
BUNDLE = "me.xieal.posturelab.depth"
DEFAULT_SIM = "C12DA589-2444-4F2E-A943-4D6BAFB02BF1"
DEFAULT_DEVICE = "00008110-001271181AD3801E"
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"

# 与 docs/qa-log-schema.md 的 42 键契约一致；顺序无关，集合必须完全相等。
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
    # v0.6 事件 `segment`（识别中段）专用；只有 `segment` 行这四键非 null。
    "segment_kind", "segment_start", "segment_end", "segment_seconds",
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


# preflight 冻结的产物路径；有它就只装它，绝不回落到共享 worktree 的构建。
FROZEN_APP: Path | None = None
FROZEN_SHA: str | None = None


def load_preflight(run_id: str) -> dict | None:
    """读本轮 preflight.json；只有 ok 的才算数。顺手设置冻结的产物与 SHA。"""
    global FROZEN_APP, FROZEN_SHA
    path = run_dir(run_id) / "preflight.json"
    if not path.exists():
        return None
    data = json.loads(path.read_text())
    if not data.get("ok"):
        return None
    FROZEN_APP = Path(data["frozen"]["appPath"])
    FROZEN_SHA = data["frozen"]["gitSha"]
    return data


def install_sim(sim: str) -> None:
    if FROZEN_APP is None:
        sys.exit("没有 preflight 冻结的产物；先跑 scripts/verify-preflight.sh（ENV-BLOCKED）")
    sh(["xcrun", "simctl", "terminate", sim, BUNDLE], check=False)
    sh(["xcrun", "simctl", "uninstall", sim, BUNDLE], check=False)
    sh(["xcrun", "simctl", "install", sim, str(FROZEN_APP)])
    # 重装会清掉相机授权；预授权，免得权限弹窗盖住截图（r15 作废 33 张截图的原因）。
    sh(["xcrun", "simctl", "privacy", sim, "grant", "camera", BUNDLE], check=False)


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
        "gitSha": FROZEN_SHA or sh_out(["git", "rev-parse", "HEAD"]),
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
    preflight = load_preflight(run_id) if args.target == "sim" else None
    if args.target == "sim" and preflight is None:
        sys.exit(f"没有通过的 preflight：{rd / 'preflight.json'}。先跑 scripts/verify-preflight.sh，"
                 "不过就标 ENV-BLOCKED，不开跑。")
    old = read_state(run_id) if state_file(run_id).exists() else {}
    state = {
        **old,
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

    frozen = preflight["frozen"]
    state.update({"gitSha": frozen["gitSha"], "udid": frozen["udid"], "deviceId": frozen["udid"],
                  "appPath": frozen["appPath"], "binarySha256": frozen["binarySha256"]})
    sim = state["udid"]
    boot(sim, state)
    state["bootedByUs"] = True
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
    preflight = load_preflight(run_id)
    checks["preflight"] = {"ok": preflight is not None, "detail": str(rd / "preflight.json")}
    frozen = (preflight or {}).get("frozen", {})
    expected_version = args.version or (preflight or {}).get("expected", {}).get("version")
    expected_build = args.build or (preflight or {}).get("expected", {}).get("build")
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
        version = build = binary = ""
        if app.returncode == 0:
            installed = Path(app.stdout.strip())
            version = plist_value(installed / "Info.plist", "CFBundleShortVersionString")
            build = plist_value(installed / "Info.plist", "CFBundleVersion")
            if (installed / "PostureLab").exists():
                binary = sha256_file(installed / "PostureLab")
        # 和传入/冻结的预期值比对，而不是「读得出来就算过」。
        checks["version"] = {"ok": bool(expected_version) and version == expected_version
                             and bool(expected_build) and build == expected_build,
                             "detail": f"已安装 {version} ({build})，预期 {expected_version} ({expected_build})"}
        # 和 preflight 冻结的快照 SHA 比对，不看共享 worktree 的 HEAD。
        checks["gitSha"] = {"ok": bool(frozen) and state.get("gitSha") == frozen.get("gitSha"),
                            "detail": f"state={state.get('gitSha')} 快照={frozen.get('gitSha')}"}
        checks["binary"] = {"ok": bool(frozen) and binary == frozen.get("binarySha256"),
                            "detail": f"已安装={binary[:12]} 冻结={str(frozen.get('binarySha256'))[:12]}"}
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
    if load_preflight(run_id) is None:
        sys.exit("没有通过的 preflight，不开跑（ENV-BLOCKED）")
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
        + ("PASS: every line carries exactly the 42-key contract\n" if ok
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
        if getattr(args, "delete_sim", False) and state.get("simCreatedByPreflight"):
            sh(["xcrun", "simctl", "delete", sim], check=False)
            state["simDeleted"] = True
    state["pid"] = 0
    state["checks"]["cleanup"] = {"ok": True, "detail": "app terminated; evidence kept", "at": now()}
    write_state(run_id, state)
    if getattr(args, "preflight_only", False):
        print("cleanup: preflight-only run, evidence kept at", rd)
        return 0
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


# ---------------------------------------------------------------------------
# preflight：QA 启动 omp 前的环境预检（v0.6.5）。任何一项不过就非零退出，不开跑。
# ---------------------------------------------------------------------------

BUILDS = Path("/Volumes/Data/verify-builds/posture-lab")
SIM_DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
CRASH_DIR = Path.home() / "Library" / "Logs" / "DiagnosticReports"
OCR_SOURCE = Path(__file__).resolve().parent / "ocr.swift"
# 系统权限弹窗上才会出现的字样；App 自己的界面不会有这些词。
ALERT_WORDS = ("想访问", "想要访问", "would like to access", "Would Like to Access",
               "不允许", "Don’t Allow", "Don't Allow")


def sha256_file(path: Path) -> str:
    import hashlib
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def crash_reports() -> list[str]:
    if not CRASH_DIR.exists():
        return []
    return sorted(p.name for p in CRASH_DIR.glob("PostureLab*.ips"))


def plist_value(plist: Path, key: str) -> str:
    r = sh(["plutil", "-extract", key, "raw", str(plist)], check=False)
    return r.stdout.strip() if r.returncode == 0 else ""


def next_run_id(slug: str) -> str:
    """slug 已经是 r<N>-xxx 就原样用；否则取 tmp/verify 下最大的 N 加一。"""
    import re
    if re.match(r"^r\d+-", slug):
        return slug
    numbers = [int(m.group(1)) for p in RUNS.iterdir() if (m := re.match(r"^r(\d+)-", p.name))] \
        if RUNS.exists() else []
    return f"r{max(numbers, default=0) + 1}-{slug}"


def create_sim(run_id: str) -> str:
    """给本轮单独建一台 iPhone 17；按运行时从新到旧尝试，第一个兼容的为准。"""
    data = json.loads(sh_out(["xcrun", "simctl", "list", "-j", "runtimes"]))
    runtimes = [r["identifier"] for r in data.get("runtimes", [])
                if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS")]
    for runtime in reversed(runtimes):
        r = sh(["xcrun", "simctl", "create", f"pl-{run_id}", SIM_DEVICE_TYPE, runtime], check=False)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    return ""


def ocr(binary: Path, image: Path) -> list[str]:
    r = sh([str(binary), str(image)], check=False, timeout=120)
    lines = []
    for line in r.stdout.splitlines():
        if line.startswith("[") and "]" in line:
            text = line.split("]", 1)[1].strip()
            # 形如 "0.98  文本"
            parts = text.split(None, 1)
            if len(parts) == 2:
                lines.append(parts[1])
    return lines


def command_preflight(args) -> int:
    run_id = args.run or next_run_id(args.slug)
    rd = run_dir(run_id)
    rd.mkdir(parents=True, exist_ok=True)
    pf_dir = rd / "preflight"
    pf_dir.mkdir(parents=True, exist_ok=True)
    result: dict = {"runId": run_id, "startedAt": now(), "expected": {
        "sha": args.sha, "version": args.version, "build": args.build}, "checks": {}, "frozen": {}}
    checks = result["checks"]

    def record(name: str, ok: bool, detail) -> bool:
        checks[name] = {"ok": bool(ok), "detail": detail, "at": now()}
        print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}")
        return bool(ok)

    def finish() -> int:
        result["finishedAt"] = now()
        result["ok"] = bool(checks) and all(c["ok"] for c in checks.values()) and not result.get("aborted")
        (rd / "preflight.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        state = json.loads(state_file(run_id).read_text()) if state_file(run_id).exists() else {
            "runId": run_id, "target": "sim", "bundleId": BUNDLE, "startedAt": now(), "checks": {}}
        state.update({k: v for k, v in result["frozen"].items() if k in (
            "gitSha", "udid", "deviceId", "appPath", "snapshotSha256", "binarySha256",
            "version", "build", "bootedByUs", "simCreatedByPreflight", "crashBaseline")})
        state["target"] = "sim"
        state["bundleId"] = BUNDLE
        state["preflight"] = {"ok": result["ok"], "file": "preflight.json"}
        write_state(run_id, state)
        print(f"preflight {'OK' if result['ok'] else 'FAILED'}: {rd / 'preflight.json'}")
        return 0 if result["ok"] else 1

    def abort(reason: str) -> int:
        result["aborted"] = reason
        print(f"ABORT {reason}")
        return finish()

    # 6. 崩溃报告基线（最先记，后面的启动都算在基线之后）。
    baseline = crash_reports()
    result["frozen"]["crashBaseline"] = {"count": len(baseline), "files": baseline}
    record("crashBaseline", True, f"{len(baseline)} 份 PostureLab*.ips")

    # 1. 工具链、simctl、磁盘。
    xv = sh(["xcodebuild", "-version"], check=False)
    first = xv.stdout.splitlines()[0] if xv.stdout else ""
    record("toolchain", xv.returncode == 0 and first.startswith("Xcode 27")
           and Path(DEVELOPER_DIR).exists(), f"DEVELOPER_DIR={DEVELOPER_DIR} {first}")
    sc = sh(["xcrun", "simctl", "list", "runtimes"], check=False)
    record("simctl", sc.returncode == 0 and "iOS" in sc.stdout, "xcrun simctl list runtimes")
    free = {str(p): shutil.disk_usage(p).free // (1 << 30) for p in (Path("/Volumes/Data"), Path.home())}
    record("diskFree", all(v >= args.min_free_gb for v in free.values()),
           {"freeGB": free, "minGB": args.min_free_gb})
    if not all(checks[k]["ok"] for k in ("toolchain", "simctl", "diskFree")):
        return abort("工具链或磁盘不满足")

    # 2. git archive 快照 + 本轮专属目录构建；不碰共享 worktree，也不用 /tmp/pl-verify-build。
    full = sh(["git", "rev-parse", "--verify", f"{args.sha}^{{commit}}"], check=False).stdout.strip()
    if not record("sha", bool(full), full or f"无法解析 {args.sha}"):
        return abort("SHA 无效")
    result["frozen"]["gitSha"] = full
    base = BUILDS / run_id
    if base.exists():
        shutil.rmtree(base)
    src = base / "src"
    src.mkdir(parents=True)
    tarball = base / "snapshot.tar"
    sh(["git", "archive", "--format=tar", "-o", str(tarball), full])
    sh(["tar", "-xf", str(tarball), "-C", str(src)])
    result["frozen"]["snapshotSha256"] = sha256_file(tarball)
    result["frozen"]["buildDir"] = str(base)
    record("snapshot", (src / "PostureLab.xcodeproj").exists(), f"{tarball} -> {src}")

    # 4. 本轮专属模拟器。
    udid = create_sim(run_id)
    if not record("simulatorCreated", bool(udid), udid or "simctl create 失败"):
        return abort("建模拟器失败")
    result["frozen"].update({"udid": udid, "deviceId": udid, "simCreatedByPreflight": True,
                             "bootedByUs": True})
    sh(["xcrun", "simctl", "boot", udid], check=False)
    bs = sh(["xcrun", "simctl", "bootstatus", udid, "-b"], check=False, timeout=600)
    if not record("simulatorBooted", bs.returncode == 0 and sim_booted(udid), udid):
        return abort("模拟器没有 boot 完成")

    build_log = rd / "logs" / "preflight-build.log"
    dd = base / "dd"
    b = subprocess.run(["xcodebuild", "-project", str(src / "PostureLab.xcodeproj"),
                        "-scheme", "PostureLab", "-destination", f"platform=iOS Simulator,id={udid}",
                        "-derivedDataPath", str(dd), "build"],
                       cwd=src, env=env(), text=True, capture_output=True, timeout=3600)
    build_log.parent.mkdir(parents=True, exist_ok=True)
    build_log.write_text(b.stdout + b.stderr + f"\n[exit {b.returncode}]\n")
    app = dd / "Build" / "Products" / "Debug-iphonesimulator" / "PostureLab.app"
    if not record("build", b.returncode == 0 and app.exists(), str(build_log.relative_to(ROOT))):
        return abort("构建失败")
    binary = app / "PostureLab"
    result["frozen"]["appPath"] = str(app)
    result["frozen"]["binarySha256"] = sha256_file(binary)

    # 3. 版本号：构建产物一次，装进模拟器后再读一次。
    built_v, built_b = plist_value(app / "Info.plist", "CFBundleShortVersionString"), \
        plist_value(app / "Info.plist", "CFBundleVersion")
    if not record("versionBuilt", built_v == args.version and built_b == args.build,
                  f"产物 {built_v} ({built_b})，预期 {args.version} ({args.build})"):
        return abort("产物版本号不符")
    sh(["xcrun", "simctl", "install", udid, str(app)])
    installed = Path(sh_out(["xcrun", "simctl", "get_app_container", udid, BUNDLE, "app"]))
    inst_v, inst_b = plist_value(installed / "Info.plist", "CFBundleShortVersionString"), \
        plist_value(installed / "Info.plist", "CFBundleVersion")
    inst_hash = sha256_file(installed / "PostureLab")
    record("versionInstalled", inst_v == args.version and inst_b == args.build
           and inst_hash == result["frozen"]["binarySha256"],
           f"已安装 {inst_v} ({inst_b})，二进制哈希{'一致' if inst_hash == result['frozen']['binarySha256'] else '不一致'}")
    result["frozen"].update({"version": inst_v, "build": inst_b})

    # 5. 相机预授权，启动后截图，OCR 确认没有系统弹窗。
    ocr_bin = base / "ocr"
    oc = sh(["swiftc", "-O", "-o", str(ocr_bin), str(OCR_SOURCE)], check=False, timeout=600)
    record("ocrTool", oc.returncode == 0 and ocr_bin.exists(), str(ocr_bin))
    grant = sh(["xcrun", "simctl", "privacy", udid, "grant", "camera", BUNDLE], check=False)
    record("cameraGranted", grant.returncode == 0, (grant.stdout + grant.stderr).strip() or "ok")
    launch_sim(udid, [])
    time.sleep(6)
    shot = pf_dir / "launch.png"
    shot_ok = screenshot(udid, shot)
    texts = ocr(ocr_bin, shot) if shot_ok and ocr_bin.exists() else []
    alerts = [t for t in texts if any(w in t for w in ALERT_WORDS)]
    (pf_dir / "launch-ocr.txt").write_text("\n".join(texts) + "\n")
    record("noAlertOnLaunch", shot_ok and bool(texts) and not alerts,
           {"screenshot": str(shot.relative_to(rd)), "ocrLines": len(texts), "alertText": alerts})
    terminate_sim(udid)

    # 7. 每种取证方法在一个短用例上试一次，必须拿到非空值。
    case = ["-scenario", "pomodoroDay", "-focusMinutes", "1", "-shortBreakMinutes", "1",
            "-voice", "0", "-debug", "1"]
    launch_sim(udid, case)
    time.sleep(12)
    shot = pf_dir / "case.png"
    shot_ok = screenshot(udid, shot)
    record("evidence:screenshot", shot_ok and shot.stat().st_size > 0 if shot_ok else False,
           {"file": str(shot.relative_to(rd)), "bytes": shot.stat().st_size if shot_ok else 0})
    texts = ocr(ocr_bin, shot) if shot_ok and ocr_bin.exists() else []
    (pf_dir / "case-ocr.txt").write_text("\n".join(texts) + "\n")
    record("evidence:ocr", bool(texts), {"lines": len(texts), "sample": texts[:5]})
    container = sh(["xcrun", "simctl", "get_app_container", udid, BUNDLE, "data"], check=False).stdout.strip()
    docs = pf_dir / "Documents"
    copy_documents(container, docs) if container else None
    files = [p for p in docs.rglob("*") if p.is_file() and p.stat().st_size > 0] if docs.exists() else []
    record("evidence:sandboxCopy", bool(files),
           {"container": container, "nonEmptyFiles": len(files)})
    log = newest_log(pf_dir)
    fields: dict = {}
    if log is not None:
        rows = [json.loads(l) for l in log.read_text().splitlines() if l.strip()]
        last = rows[-1] if rows else {}
        fields = {"rows": len(rows), "keys": len(last), "lastEvent": last.get("event"),
                  "remaining_seconds": next((r["remaining_seconds"] for r in reversed(rows)
                                             if r.get("remaining_seconds") is not None), None)}
    record("evidence:debugLogField", bool(fields) and fields.get("keys") == len(LOG_KEYS)
           and bool(fields.get("lastEvent")) and fields.get("remaining_seconds") is not None, fields)
    idle_logs = sorted(docs.glob("debug/idle-*.jsonl")) if docs.exists() else []
    idle_rows = [json.loads(l) for p in idle_logs for l in p.read_text().splitlines() if l.strip()]
    record("evidence:idleTimerField",
           any(isinstance(r.get("idle_timer_disabled"), bool) for r in idle_rows),
           {"rows": idle_rows[:4]})
    terminate_sim(udid)

    # 6（收尾）. 预检本身不允许制造崩溃。
    after = crash_reports()
    new = sorted(set(after) - set(baseline))
    record("noNewCrash", not new, {"new": new})
    return finish()


def main() -> int:
    parser = argparse.ArgumentParser(description="PostureLab 验证运行器")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("up", "doctor", "drive", "evidence", "down"):
        p = sub.add_parser(name)
        p.add_argument("--run", default=None)
        if name == "up":
            p.add_argument("--target", choices=["sim", "device"], default="sim")
            p.add_argument("--udid", default=None)
            p.add_argument("--launch", nargs="*", default=None)
        if name == "doctor":
            p.add_argument("--version", default=None, help="预期 CFBundleShortVersionString；默认取 preflight.json")
            p.add_argument("--build", default=None, help="预期 CFBundleVersion；默认取 preflight.json")
        if name == "down":
            p.add_argument("--delete-sim", action="store_true", help="删掉 preflight 建的本轮模拟器")
            p.add_argument("--preflight-only", action="store_true", help="只跑过 preflight，不检查场景证据")
    pf = sub.add_parser("preflight", help="开跑前环境预检；不过就非零退出")
    pf.add_argument("--sha", required=True)
    pf.add_argument("--version", required=True)
    pf.add_argument("--build", required=True)
    pf.add_argument("--slug", required=True)
    pf.add_argument("--run", default=None, help="默认 r<下一个N>-<slug>；slug 本身是 r<N>-xxx 时直接用")
    pf.add_argument("--min-free-gb", type=int, default=20)
    args = parser.parse_args()
    if args.command == "up" and args.run is None:
        parser.error("up 需要 --run <run-id>")
    return {
        "preflight": command_preflight,
        "up": command_up,
        "doctor": command_doctor,
        "drive": command_drive,
        "evidence": command_evidence,
        "down": command_down,
    }[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
