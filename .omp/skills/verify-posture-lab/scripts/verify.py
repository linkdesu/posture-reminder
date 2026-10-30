#!/usr/bin/env python3
"""PostureLab 验证运行器：构建、启动、健康检查、场景驱动、取证与清理。

用法：
  .omp/skills/verify-posture-lab/scripts/verify.py preflight --sha <SHA> --version <x.y.z> --build <N> --slug <slug>
  .omp/skills/verify-posture-lab/scripts/verify.py up --run <run-id>
  .omp/skills/verify-posture-lab/scripts/verify.py doctor --run <run-id> [--version x.y.z --build N]
  .omp/skills/verify-posture-lab/scripts/verify.py drive --run <run-id> [all|pause|break-count|abandon-count|settings-scroll|settings-toggle|upgrade-063]
  .omp/skills/verify-posture-lab/scripts/verify.py case --run <run-id> <用例名>...   （list-cases 列出全部）
  .omp/skills/verify-posture-lab/scripts/verify.py png|ascii <png>...
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
DEFAULT_SIM = ""  # 模拟器一律用 preflight 冻结的固定模拟器 pl-verify
DEFAULT_DEVICE = "00008110-001271181AD3801E"
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
# 所有入口（preflight/up/doctor/drive/case/evidence/down…）都从这里起步：非交互 shell 里也能直接
# 调 xcrun simctl / xcresulttool，子进程一律继承。
os.environ["DEVELOPER_DIR"] = DEVELOPER_DIR
# 固定的验收模拟器：每轮复用，不新建、不删除；一轮结束只关机。
FIXED_SIM_NAME = "pl-verify"

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
                       run_id: str, end_at: float | None = None) -> dict:
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
    if end_at is not None:
        # 例如 pause：脚本要跑完（35 秒）再收证据、结束进程，否则历史还没落盘（r16 观察项）。
        wait = end_at - (time.time() - t0)
        if wait > 0:
            time.sleep(wait)
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
    blockers = [d for d in booted_blockers() if d["udid"] != sim]
    if blockers:
        check(state, "onlyFixedSimBooted", False, {"booted": blockers})
        write_state(run_id, state)
        sys.exit("ENV-BLOCKED：有 pl-verify 以外的模拟器在 Booted：" +
                 "，".join(f"{d['name']} {d['udid']}" for d in blockers))
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
         [(30, "absence-pause.png")], 35),
        ("settings",
         ["-settings", "1"],
         [(5, "settings.png")]),
    ]
    only = getattr(args, "scenario", "all")
    if only in DRIVE_EXTRA:
        return DRIVE_EXTRA[only](run_id, state, sim)
    for scenario, launch, shots, *end in scenarios:
        if only not in ("all", scenario):
            continue
        provenance = launch_and_capture(sim, scenario, launch, shots, run_id,
                                        end_at=end[0] if end else None)
        state.setdefault("scenarios", {})[scenario] = provenance
        write_state(run_id, state)
    if only != "all":
        return 0

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


CORE_SCENARIOS = ("pomodoro-focus", "posture-voice", "pause", "report", "settings")


def ran_scenarios(rd: Path, state: dict) -> set[str]:
    """本批真跑过的核心场景：state.json 里有记录，或场景目录里有 provenance / 持久化结果。
    分批跑（例如只跑 drive pause）时，没跑的场景不在这里，evidence / down 都不判它。"""
    ran = set(state.get("scenarios", {}))
    for name in CORE_SCENARIOS:
        sdir = rd / "scenarios" / name
        if (sdir / "provenance.json").exists() or (sdir / "report-persistence.json").exists():
            ran.add(name)
    return ran & set(CORE_SCENARIOS)


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

    # ADR-0008 的彩色帧静态边界：白名单、禁止面与授权文案一起判，和 offline 一样是源码性质。
    privacy = rd / "audits" / "privacy.txt"
    r = sh([sys.executable, "scripts/audit-privacy.py"], check=False)
    privacy.write_text(r.stdout + r.stderr + f"\n[exit {r.returncode}]\n")
    results["privacy"] = r.returncode == 0

    ran = ran_scenarios(rd, state)
    skipped = [name for name in CORE_SCENARIOS if name not in ran]
    for scenario in CORE_SCENARIOS:
        if scenario not in ran:
            continue  # 本批没跑：不判，记进 skipped，不再算失败
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

    # drive 扩展场景与 case 用例由各自子命令判过，这里只汇总本批真跑过的那些。
    for name, entry in sorted(state.get("checks", {}).items()):
        if name.startswith(("drive:", "case:")):
            results[name] = bool(entry.get("ok"))
    batch = [name for name in results if name not in ("offline", "privacy")]
    # ran 列出本批真跑过的全部场景：核心场景名 + drive:<场景> + case:<用例>。
    ran_all = sorted(ran) + sorted(name for name in state.get("checks", {})
                                   if name.startswith(("drive:", "case:")))
    if not batch:
        results["batch:nonEmpty"] = False  # 一个场景都没跑，不能算通过
    summary = {"when": now(), "runId": run_id, "results": results,
               "ran": ran_all, "skipped": skipped,
               "ok": all(results.values())}
    (rd / "verification.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    state.setdefault("checks", {})["evidence"] = {
        "ok": summary["ok"], "detail": results, "at": now()}
    write_state(run_id, state)
    print(json.dumps(results, ensure_ascii=False, indent=2))
    if skipped:
        print("本批未跑、不判：" + "，".join(skipped))
    return 0 if summary["ok"] else 1


def command_down(args) -> int:
    run_id = resolve_run(args.run)
    state = read_state(run_id)
    rd = run_dir(run_id)
    if state["target"] == "sim":
        sim = state["udid"]
        terminate_sim(sim)
        # 固定模拟器 pl-verify：一轮结束只关机，不删除。
        sh(["xcrun", "simctl", "shutdown", sim], check=False)
        state["simShutdown"] = not sim_booted(sim)
    state["pid"] = 0
    state["checks"]["cleanup"] = {"ok": True, "detail": "app terminated; evidence kept", "at": now()}
    write_state(run_id, state)
    if getattr(args, "preflight_only", False):
        print("cleanup: preflight-only run, evidence kept at", rd)
        return 0
    # 只要求本批真跑过的东西留下证据：没跑 up 就不要 launch 截图，没跑 pomodoro-focus 就不要它的文件。
    expected = ["state.json", "verification.json", "audits/offline.txt"]
    if "launch" in state.get("checks", {}):
        expected.append("launch/pomodoro_main.png")
    if "pomodoro-focus" in ran_scenarios(rd, state):
        expected += ["scenarios/pomodoro-focus/mid-focus.png",
                     "scenarios/pomodoro-focus/provenance.json"]
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
    """slug 已经是 r<N>-xxx 就原样用；tl- 开头（TL 自测 smoke）原样用、不占 r 序号；
    否则取 tmp/verify 下最大的 N 加一。"""
    import re
    if re.match(r"^r\d+-", slug) or slug.startswith("tl-"):
        return slug
    numbers = [int(m.group(1)) for p in RUNS.iterdir() if (m := re.match(r"^r(\d+)-", p.name))] \
        if RUNS.exists() else []
    return f"r{max(numbers, default=0) + 1}-{slug}"


def all_sims() -> list[dict]:
    data = json.loads(sh_out(["xcrun", "simctl", "list", "-j", "devices"], check=False) or "{}")
    return [{"name": d.get("name", ""), "udid": d["udid"], "state": d.get("state", "")}
            for devices in data.get("devices", {}).values() for d in devices]


def fixed_sim() -> str:
    """固定模拟器 pl-verify 的 UDID；没有就建一台（iPhone 17，按运行时从新到旧取第一个兼容的）。
    每轮复用，绝不删除。"""
    for d in all_sims():
        if d["name"] == FIXED_SIM_NAME:
            return d["udid"]
    data = json.loads(sh_out(["xcrun", "simctl", "list", "-j", "runtimes"]))
    runtimes = [r["identifier"] for r in data.get("runtimes", [])
                if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS")]
    for runtime in reversed(runtimes):
        r = sh(["xcrun", "simctl", "create", FIXED_SIM_NAME, SIM_DEVICE_TYPE, runtime], check=False)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    return ""


def booted_blockers() -> list[dict]:
    """开跑前的 Booted 设备：超过一台，或有任何一台不是 pl-verify，就全部列出（ENV-BLOCKED）。"""
    booted = [{"name": d["name"], "udid": d["udid"]} for d in all_sims() if d["state"] == "Booted"]
    if len(booted) > 1 or any(d["name"] != FIXED_SIM_NAME for d in booted):
        return booted
    return []


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


# 本次 preflight 的现场，供退出清理用（正常退出、失败、中断都走 finally）。
PREFLIGHT_CTX: dict = {}


def shutdown_sim(udid: str) -> bool:
    sh(["xcrun", "simctl", "terminate", udid, BUNDLE], check=False)
    sh(["xcrun", "simctl", "shutdown", udid], check=False)
    return not sim_booted(udid)


def preflight_cleanup(run_id: str, udid: str) -> dict:
    """预检结束（通过、失败、中断都一样）：固定模拟器保留、只关机；up 会再把它开起来。"""
    if not udid:
        return {"action": "none"}
    return {"action": "shutdown" if shutdown_sim(udid) else "shutdown-failed", "udid": udid,
            "name": FIXED_SIM_NAME}


def command_preflight(args) -> int:
    import signal

    def on_signal(signum, _frame):
        raise SystemExit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, on_signal)
    PREFLIGHT_CTX.clear()
    code = 1
    try:
        code = _preflight(args)
        return code
    except KeyboardInterrupt:
        code = 130
        print("ABORT 收到中断信号")
        return code
    finally:
        run_id = PREFLIGHT_CTX.get("run_id")
        udid = PREFLIGHT_CTX.get("udid", "")
        cleanup = preflight_cleanup(run_id or "", udid)
        print(f"simCleanup: {cleanup}")
        if run_id:
            path = run_dir(run_id) / "preflight.json"
            if path.exists():
                data = json.loads(path.read_text())
                data["simCleanup"] = cleanup
                if code != 0:
                    data["ok"] = False
                path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
            if state_file(run_id).exists():
                st = json.loads(state_file(run_id).read_text())
                st["simShutdown"] = cleanup.get("action") == "shutdown"
                write_state(run_id, st)


def _preflight(args) -> int:
    run_id = args.run or next_run_id(args.slug)
    PREFLIGHT_CTX["run_id"] = run_id
    if os.environ.get("PL_PREFLIGHT_RUNFILE"):
        Path(os.environ["PL_PREFLIGHT_RUNFILE"]).write_text(run_id + "\n")
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
            "version", "build", "bootedByUs", "simName", "crashBaseline", "xctestrun", "buildDir")})
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

    # 0. 开着的模拟器：超过一台，或有不是 pl-verify 的，ENV-BLOCKED，列出名称和 UDID，不动它们。
    blockers = booted_blockers()
    result["frozen"]["bootedBlockers"] = blockers
    if not record("onlyFixedSimBooted", not blockers,
                  {"booted": blockers} if blockers else f"没有 {FIXED_SIM_NAME} 以外的模拟器在 Booted"):
        result["envBlocked"] = True
        return abort("ENV-BLOCKED：有多台或非 pl-verify 的模拟器处于 Booted（不自动处理，请人工关机）："
                     + "，".join(f"{d['name']} {d['udid']}" for d in blockers))

    # 4. 固定模拟器 pl-verify：复用，不新建、不删除。
    udid = fixed_sim()
    PREFLIGHT_CTX["udid"] = udid
    if udid:
        # 先落盘 UDID，Python 被强杀时 shell 的 trap 也能找到并把它关机。
        st = json.loads(state_file(run_id).read_text()) if state_file(run_id).exists() else {
            "runId": run_id, "target": "sim", "bundleId": BUNDLE, "checks": {}}
        st.update({"udid": udid, "deviceId": udid, "simName": FIXED_SIM_NAME})
        write_state(run_id, st)
    if not record("fixedSim", bool(udid), f"{FIXED_SIM_NAME} {udid}" if udid else "找不到也建不出 pl-verify"):
        return abort("固定模拟器不可用")
    result["frozen"].update({"udid": udid, "deviceId": udid, "simName": FIXED_SIM_NAME,
                             "bootedByUs": True})
    sh(["xcrun", "simctl", "boot", udid], check=False)
    bs = sh(["xcrun", "simctl", "bootstatus", udid, "-b"], check=False, timeout=600)
    if not record("simulatorBooted", bs.returncode == 0 and sim_booted(udid), udid):
        return abort("模拟器没有 boot 完成")

    build_log = rd / "logs" / "preflight-build.log"
    dd = base / "dd"
    b = subprocess.run(["xcodebuild", "-project", str(src / "PostureLab.xcodeproj"),
                        "-scheme", "PostureLab", "-destination", f"platform=iOS Simulator,id={udid}",
                        "-derivedDataPath", str(dd), "build-for-testing"],
                       cwd=src, env=env(), text=True, capture_output=True, timeout=3600)
    build_log.parent.mkdir(parents=True, exist_ok=True)
    build_log.write_text(b.stdout + b.stderr + f"\n[exit {b.returncode}]\n")
    app = dd / "Build" / "Products" / "Debug-iphonesimulator" / "PostureLab.app"
    if not record("build", b.returncode == 0 and app.exists(), str(build_log.relative_to(ROOT))):
        return abort("构建失败")
    binary = app / "PostureLab"
    result["frozen"]["appPath"] = str(app)
    xctestrun = sorted((dd / "Build" / "Products").glob("*.xctestrun"))
    result["frozen"]["xctestrun"] = str(xctestrun[0]) if xctestrun else ""
    record("xctestrun", bool(xctestrun), result["frozen"]["xctestrun"] or "build-for-testing 没产出 .xctestrun")
    result["frozen"]["binarySha256"] = sha256_file(binary)

    # 3. 版本号：构建产物一次，装进模拟器后再读一次。
    built_v, built_b = plist_value(app / "Info.plist", "CFBundleShortVersionString"), \
        plist_value(app / "Info.plist", "CFBundleVersion")
    if not record("versionBuilt", built_v == args.version and built_b == args.build,
                  f"产物 {built_v} ({built_b})，预期 {args.version} ({args.build})"):
        return abort("产物版本号不符")
    # 固定模拟器是复用的：先卸载，保证本轮沙盒是干净的。
    sh(["xcrun", "simctl", "uninstall", udid, BUNDLE], check=False)
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
    # 每次启动（每个进程）各写一个 idle-<启动时刻>.jsonl；preflight 在同一容器里启动了两次
    # （无参启动查弹窗 + 短用例），所以按文件分开列，不要把两次启动的行混成一串。
    by_file = {p.name: [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
               for p in idle_logs}
    idle_rows = [r for rows in by_file.values() for r in rows]
    record("evidence:idleTimerField",
           any(isinstance(r.get("idle_timer_disabled"), bool) for r in idle_rows),
           {"files": by_file})
    terminate_sim(udid)

    # 6（收尾）. 预检本身不允许制造崩溃。
    after = crash_reports()
    new = sorted(set(after) - set(baseline))
    record("noNewCrash", not new, {"new": new})
    return finish()


def command_preflight_cleanup(args) -> int:
    """shell trap 的兜底：把本轮用的固定模拟器关机（不删除）。幂等。"""
    if not state_file(args.run).exists():
        return 0
    st = json.loads(state_file(args.run).read_text())
    udid = st.get("udid", "")
    if udid and sim_booted(udid):
        print(f"trap: 关机 {FIXED_SIM_NAME} {udid}：{'ok' if shutdown_sim(udid) else 'failed'}")
    return 0


# ---------------------------------------------------------------------------
# 扩展驱动（v0.6.7 起）：XCUITest 入口、升级路径、休息计数，以及 r16 临时脚本沉淀下来的
# 正式用例。omp 不得自己写驱动脚本——缺什么用例，先登记到 features/*.md，再加到这里。
# ---------------------------------------------------------------------------

LEGACY_063_SHA = "c9d5f42"   # 0.6.3 (9) 最后一个提交，r16 升级路径用的同一个
UI_TEST_CLASS = "PostureLabUITests/VerifyDriveUITests"


def frozen_ocr(run_id: str) -> Path | None:
    pf = load_preflight(run_id)
    if not pf:
        return None
    binary = Path(pf["frozen"].get("buildDir", "")) / "ocr"
    return binary if binary.exists() else None


def scenario_dir(run_id: str, name: str) -> Path:
    out = run_dir(run_id) / "scenarios" / name
    out.mkdir(parents=True, exist_ok=True)
    return out


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def read_defaults(sim: str) -> dict:
    """读回 App 的 UserDefaults 真值：App 数据容器里的 Library/Preferences/<bundle>.plist
    （`simctl spawn defaults` 读的是模拟器全局域，读不到沙盒 App 的偏好）。"""
    import plistlib
    c = sh(["xcrun", "simctl", "get_app_container", sim, BUNDLE, "data"], check=False)
    if c.returncode != 0:
        return {}
    f = Path(c.stdout.strip()) / "Library" / "Preferences" / f"{BUNDLE}.plist"
    for _ in range(10):  # cfprefsd 落盘有延迟
        if f.is_file():
            try:
                return plistlib.loads(f.read_bytes())
            except Exception:
                pass
        time.sleep(0.5)
    return {}


def settings_blob(defaults: dict) -> dict:
    raw = defaults.get("pomodoro.settings")
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode("utf-8", "replace")
    try:
        return json.loads(raw) if isinstance(raw, str) else (raw or {})
    except json.JSONDecodeError:
        return {}


def installed_version(sim: str) -> tuple[str, str]:
    app = sh(["xcrun", "simctl", "get_app_container", sim, BUNDLE, "app"], check=False)
    if app.returncode != 0:
        return "", ""
    plist = Path(app.stdout.strip()) / "Info.plist"
    return plist_value(plist, "CFBundleShortVersionString"), plist_value(plist, "CFBundleVersion")


def run_xcuitest(run_id: str, sim: str, test: str, out: Path, *,
                 legacy_bundle: str | None = None, legacy_app: Path | None = None) -> dict:
    """用 preflight 的 build-for-testing 产物跑一个 VerifyDriveUITests 用例，导出附件。
    legacy_bundle 时把 xctestrun 里的被测 App 指向 legacy_app，xcodebuild 装的仍是旧版。"""
    import plistlib
    pf = load_preflight(run_id)
    xctestrun = Path((pf or {}).get("frozen", {}).get("xctestrun", ""))
    if not xctestrun.is_file():
        return {"ok": False, "detail": "preflight 没有 .xctestrun（需 build-for-testing）"}
    if legacy_bundle:
        data = plistlib.loads(xctestrun.read_bytes())

        def point(node):
            # xcodebuild 要求 UITargetAppPath，所以不能删：把被测 App 换成旧版，装的仍是 0.6.3。
            if isinstance(node, dict):
                if "UITargetAppPath" in node:
                    node["UITargetAppPath"] = str(legacy_app)
                if "DependentProductPaths" in node:
                    node["DependentProductPaths"] = [str(legacy_app) if q.endswith("/PostureLab.app") else q
                                                     for q in node["DependentProductPaths"]]
                for value in node.values():
                    point(value)
            elif isinstance(node, list):
                for value in node:
                    point(value)
        point(data)
        patched = xctestrun.with_name(f"legacy-{os.getpid()}.xctestrun")
        patched.write_bytes(plistlib.dumps(data))
        xctestrun = patched
    result_bundle = out / f"{test}.xcresult"
    if result_bundle.exists():
        shutil.rmtree(result_bundle)
    e = env()
    if legacy_bundle:
        e["TEST_RUNNER_PL_DRIVE_LEGACY_BUNDLE"] = legacy_bundle
    cmd = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
           "-destination", f"platform=iOS Simulator,id={sim}",
           f"-only-testing:{UI_TEST_CLASS}/{test}", "-resultBundlePath", str(result_bundle)]
    r = subprocess.run(cmd, cwd=ROOT, env=e, text=True, capture_output=True, timeout=1800)
    (out / f"{test}.log").write_text("$ " + " ".join(cmd) + "\n\n" + r.stdout + r.stderr
                                      + f"\n[exit {r.returncode}]\n")
    attachments = out / "attachments"
    if attachments.exists():
        shutil.rmtree(attachments)
    attachments.mkdir(parents=True)
    named: dict[str, str] = {}
    if result_bundle.exists():
        sh(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result_bundle),
            "--output-path", str(attachments)], check=False)
        manifest = attachments / "manifest.json"
        if manifest.exists():
            for test_entry in json.loads(manifest.read_text()):
                for att in test_entry.get("attachments", []):
                    src = attachments / att.get("exportedFileName", "")
                    human = att.get("suggestedHumanReadableName", src.name)
                    # 形如 drive-settings-bottom_0_<uuid>.png → drive-settings-bottom.png
                    stem = human.split("_0_")[0]
                    dest = out / (stem + src.suffix)
                    if src.exists():
                        shutil.copy2(src, dest)
                        named[stem] = str(dest.relative_to(run_dir(run_id)))
    import re
    skipped = bool(re.search(r"Test Case .*" + re.escape(test) + r".* skipped", r.stdout))
    result = {"ok": r.returncode == 0 and not skipped, "exit": r.returncode, "skipped": skipped,
              "test": test, "xcresult": str(result_bundle.relative_to(run_dir(run_id))),
              "attachments": named}
    xcuitest_provenance(run_id, sim, out, test, result, legacy_bundle=legacy_bundle)
    return result


# XCUITest 用例在 app.launch() 前设置的启动参数（与 PostureLabUITests/VerifyDriveUITests.swift 一致）。
XCUITEST_LAUNCH_ARGS = {
    "testDriveSettingsScrollCountsTenSettings": ["-settings", "1"],
    "testDriveSettingsToggleFlipsAutoStartBreak": ["-settings", "1"],
    "testDriveLegacyKeepScreenAwakeOff": ["-settings", "1"],
    "testDriveAbandonDoesNotCountToday": ["-scenario", "pomodoroDay", "-holdStart", "1",
                                          "-focusMinutes", "1", "-debug", "0"],
}


def xcuitest_provenance(run_id: str, sim: str, out: Path, test: str, result: dict, *,
                        legacy_bundle: str | None = None) -> None:
    """XCUITest 驱动的场景也留下 launch-args.txt、provenance.json、sandbox-audit.json，
    给运行时沙盒审计（AC14/AC19）留证据；和 launch_and_capture 的产物同名同格式。"""
    args = XCUITEST_LAUNCH_ARGS.get(test, [])
    (out / "launch-args.txt").write_text(" ".join(args) + "\n")
    c = sh(["xcrun", "simctl", "get_app_container", sim, BUNDLE, "data"], check=False)
    container = c.stdout.strip() if c.returncode == 0 else ""
    audit_exit = None
    if container:
        audit = audit_sandbox(container, out / "sandbox-audit.json")
        (out / "sandbox-audit.txt").write_text(audit.stdout + audit.stderr + f"\n[exit {audit.returncode}]\n")
        audit_exit = audit.returncode
    version, build = installed_version(sim)
    write_json(out / "provenance.json", {
        "scenario": out.name, "driver": "xcuitest", "test": f"{UI_TEST_CLASS}/{test}",
        "launchArgs": args, "testExit": result.get("exit"), "testSkipped": result.get("skipped"),
        "legacyBundle": legacy_bundle, "installed": f"{version} ({build})",
        "gitSha": FROZEN_SHA, "container": container, "sandboxAuditExit": audit_exit,
        "xcresult": result.get("xcresult"), "when": now()})


def kv_text(path: Path) -> dict:
    if not path.exists():
        return {}
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)


def drive_settings_scroll(run_id: str, state: dict, sim: str) -> int:
    """XCUITest 滚到设置页下半屏截图，逐项数出番茄钟 10 项，并确认没有「屏幕常亮」行。"""
    out = scenario_dir(run_id, "settings-scroll")
    install_sim(sim)
    test = run_xcuitest(run_id, sim, "testDriveSettingsScrollCountsTenSettings", out)
    counted = kv_text(out / "drive-settings-count.txt")
    texts = []
    ocr_bin = frozen_ocr(run_id)
    if ocr_bin and (out / "drive-settings-bottom.png").exists():
        texts = ocr(ocr_bin, out / "drive-settings-bottom.png")
        (out / "ocr-bottom.txt").write_text("\n".join(texts) + "\n")
    ok = test["ok"] and counted.get("count") == "10" and counted.get("keepScreenAwakeRow") == "false" \
        and (out / "drive-settings-bottom.png").exists()
    result = {"ok": ok, "test": test, "count": counted.get("count"), "found": counted.get("found"),
              "keepScreenAwakeRow": counted.get("keepScreenAwakeRow"), "ocrBottom": texts, "when": now()}
    write_json(out / "settings-scroll.json", result)
    check(state, "drive:settings-scroll", ok, f"count={counted.get('count')} test exit={test.get('exit')}")
    write_state(run_id, state)
    return 0 if ok else 1


def drive_settings_toggle(run_id: str, state: dict, sim: str) -> int:
    """XCUITest 真点一次「自动开始休息」，再从模拟器读回 UserDefaults，确认存储里的值变了。"""
    out = scenario_dir(run_id, "settings-toggle")
    install_sim(sim)
    before_blob = settings_blob(read_defaults(sim))
    test = run_xcuitest(run_id, sim, "testDriveSettingsToggleFlipsAutoStartBreak", out)
    terminate_sim(sim)
    time.sleep(1)
    after_blob = settings_blob(read_defaults(sim))
    ui = kv_text(out / "drive-toggle-values.txt")
    stored = after_blob.get("autoStartBreak")
    expected = ui.get("after") == "1"
    ok = test["ok"] and ui.get("before") != ui.get("after") and isinstance(stored, bool) \
        and stored == expected and before_blob.get("autoStartBreak") != stored
    result = {"ok": ok, "test": test, "ui": ui,
              "storedBefore": before_blob.get("autoStartBreak"), "storedAfter": stored,
              "blobAfter": after_blob, "when": now()}
    write_json(out / "settings-toggle.json", result)
    check(state, "drive:settings-toggle", ok,
          f"界面 {ui.get('before')}→{ui.get('after')}，存储 {before_blob.get('autoStartBreak')}→{stored}")
    write_state(run_id, state)
    return 0 if ok else 1


def build_legacy_063(sim: str) -> Path | None:
    base = BUILDS / "legacy-063"
    app = base / "dd" / "Build" / "Products" / "Debug-iphonesimulator" / "PostureLab.app"
    if app.exists() and plist_value(app / "Info.plist", "CFBundleShortVersionString") == "0.6.3":
        return app
    if base.exists():
        shutil.rmtree(base)
    (base / "src").mkdir(parents=True)
    sh(["git", "archive", "--format=tar", "-o", str(base / "snapshot.tar"), LEGACY_063_SHA])
    sh(["tar", "-xf", str(base / "snapshot.tar"), "-C", str(base / "src")])
    r = subprocess.run(["xcodebuild", "-project", str(base / "src" / "PostureLab.xcodeproj"),
                        "-scheme", "PostureLab", "-destination", f"platform=iOS Simulator,id={sim}",
                        "-derivedDataPath", str(base / "dd"), "build"],
                       cwd=base / "src", env=env(), text=True, capture_output=True, timeout=3600)
    (base / "build.log").write_text(r.stdout + r.stderr + f"\n[exit {r.returncode}]\n")
    return app if r.returncode == 0 and app.exists() else None


def drive_upgrade_063(run_id: str, state: dict, sim: str) -> int:
    """升级路径：0.6.3 界面上真点「屏幕常亮」关掉 → 读回存储 → 覆盖安装冻结的新版 → 设置读回、
    无常亮行、专注时 idle focus_start=true。"""
    out = scenario_dir(run_id, "upgrade-063")
    steps: dict = {}
    legacy = build_legacy_063(sim)
    steps["legacyBuild"] = {"ok": legacy is not None, "app": str(legacy), "sha": LEGACY_063_SHA}
    if legacy is None:
        write_json(out / "upgrade.json", {"ok": False, "steps": steps})
        check(state, "drive:upgrade-063", False, "0.6.3 构建失败")
        write_state(run_id, state)
        return 1
    terminate_sim(sim)
    sh(["xcrun", "simctl", "uninstall", sim, BUNDLE], check=False)
    sh(["xcrun", "simctl", "install", sim, str(legacy)])
    sh(["xcrun", "simctl", "privacy", sim, "grant", "camera", BUNDLE], check=False)
    steps["legacyInstalled"] = dict(zip(("version", "build"), installed_version(sim)))
    test = run_xcuitest(run_id, sim, "testDriveLegacyKeepScreenAwakeOff", out, legacy_bundle=BUNDLE,
                        legacy_app=legacy)
    steps["legacyTap"] = {**test, "ui": kv_text(out / "drive-legacy-values.txt")}
    terminate_sim(sim)
    time.sleep(1)
    steps["stillLegacyAfterTest"] = dict(zip(("version", "build"), installed_version(sim)))
    blob = settings_blob(read_defaults(sim))
    steps["legacyStored"] = {"keepScreenAwake": blob.get("keepScreenAwake"), "blob": blob}
    # 覆盖安装（不卸载）冻结的新版。
    sh(["xcrun", "simctl", "install", sim, str(FROZEN_APP)])
    sh(["xcrun", "simctl", "privacy", sim, "grant", "camera", BUNDLE], check=False)
    steps["upgradedInstalled"] = dict(zip(("version", "build"), installed_version(sim)))
    blob_after = settings_blob(read_defaults(sim))
    steps["blobSurvives"] = {"keepScreenAwake": blob_after.get("keepScreenAwake"), "blob": blob_after}
    launch_sim(sim, ["-settings", "1"])
    time.sleep(6)
    screenshot(sim, out / "settings-after-upgrade.png")
    texts = ocr(frozen_ocr(run_id), out / "settings-after-upgrade.png") if frozen_ocr(run_id) else []
    (out / "ocr-settings-after-upgrade.txt").write_text("\n".join(texts) + "\n")
    terminate_sim(sim)
    steps["noKeepAwakeRow"] = {"ok": bool(texts) and not any("常亮" in t for t in texts), "ocrLines": len(texts)}
    launch_sim(sim, ["-scenario", "pomodoroDay", "-focusMinutes", "1", "-debug", "0", "-voice", "0",
                     "-endSound", "none"])
    time.sleep(12)
    screenshot(sim, out / "focus-after-upgrade.png")
    copy_documents(container_sim(sim), out / "Documents")
    terminate_sim(sim)
    rows = [json.loads(l) for p in sorted((out / "Documents").glob("debug/idle-*.jsonl"))
            for l in p.read_text().splitlines() if l.strip()]
    focus = [r for r in rows if r.get("trigger") == "focus_start"]
    steps["focusKeepsAwake"] = {"ok": bool(focus) and all(r.get("idle_timer_disabled") is True for r in focus),
                                "focusStart": focus}
    expected_v = (load_preflight(run_id) or {}).get("expected", {})
    ok = (steps["legacyInstalled"].get("version") == "0.6.3"
          and test["ok"] and steps["legacyTap"]["ui"].get("after") == "0"
          and steps["stillLegacyAfterTest"].get("version") == "0.6.3"
          and blob.get("keepScreenAwake") is False
          and steps["upgradedInstalled"].get("version") == expected_v.get("version")
          and steps["upgradedInstalled"].get("build") == expected_v.get("build")
          and blob_after.get("keepScreenAwake") is False
          and steps["noKeepAwakeRow"]["ok"] and steps["focusKeepsAwake"]["ok"])
    write_json(out / "upgrade.json", {"ok": ok, "steps": steps, "when": now()})
    check(state, "drive:upgrade-063", ok, {k: v.get("ok", v) if isinstance(v, dict) else v
                                           for k, v in steps.items() if k in ("legacyTap", "noKeepAwakeRow", "focusKeepsAwake")})
    write_state(run_id, state)
    return 0 if ok else 1


def today_count(texts: list[str]) -> tuple[int, int] | None:
    import re
    for t in texts:
        m = re.search(r"今天\s*(\d+)\s*/\s*(\d+)", t.replace(" ", ""))
        if m:
            return int(m.group(1)), int(m.group(2))
    return None


def drive_break_count(run_id: str, state: dict, sim: str) -> int:
    """0.6.7：倒计时归零那一刻「今天 x/目标」就加一——休息中截图必须已是 1；下一段专注开始后
    仍是 1（不重复加）。"""
    out = scenario_dir(run_id, "break-count")
    args = ["-scenario", "pomodoroDay", "-focusMinutes", "1", "-shortBreakMinutes", "1",
            "-endSound", "none", "-debug", "0", "-voice", "0"]
    (out / "launch-args.txt").write_text(" ".join(args) + "\n")
    install_sim(sim)
    t0 = time.time()
    launch_sim(sim, args)
    shots = [(20, "focus.png"), (75, "break.png"), (135, "next-focus.png")]
    ocr_bin = frozen_ocr(run_id)
    counts: dict = {}
    for delay, name in shots:
        wait = delay - (time.time() - t0)
        if wait > 0:
            time.sleep(wait)
        screenshot(sim, out / name)
        texts = ocr(ocr_bin, out / name) if ocr_bin else []
        (out / f"ocr-{Path(name).stem}.txt").write_text("\n".join(texts) + "\n")
        counts[Path(name).stem] = {"today": today_count(texts), "break": any("休息" in t for t in texts)}
    copy_documents(container_sim(sim), out / "Documents")
    terminate_sim(sim)
    c = {k: (v["today"] or (None, None))[0] for k, v in counts.items()}
    ok = c.get("focus") == 0 and c.get("break") == 1 and counts["break"]["break"] and c.get("next-focus") == 1
    write_json(out / "break-count.json", {"ok": ok, "counts": counts, "when": now()})
    check(state, "drive:break-count", ok, f"专注中 {c.get('focus')} → 休息中 {c.get('break')} → 下一专注 {c.get('next-focus')}")
    write_state(run_id, state)
    return 0 if ok else 1


def judge_abandon_count(ui: dict, ocr_before, ocr_after, expected_goal: int | None = None) -> tuple[bool, str]:
    """离开计数的判定：真点了「离开」；界面与截图 OCR 读到的分子前后相等且一致；
    分母 goal 在界面、离开前后两张截图里一致，并等于设置里的每日目标 expected_goal。"""
    before, after, goal = ui.get("before"), ui.get("after"), ui.get("goal")
    reasons = []
    if ui.get("endTapped") != "true":
        reasons.append("没有真点到「离开」")
    if before in (None, "nil") or before != after:
        reasons.append(f"界面计数 {before}→{after}")
    ob = ocr_before[0] if ocr_before else None
    oa = ocr_after[0] if ocr_after else None
    if ob is None or oa is None or ob != oa:
        reasons.append(f"截图 OCR 计数 {ob}→{oa}")
    elif str(oa) != str(after):
        reasons.append(f"OCR {oa} 与界面 {after} 不一致")
    gb = ocr_before[1] if ocr_before else None
    ga = ocr_after[1] if ocr_after else None
    if goal in (None, "nil") or str(gb) != str(goal) or str(ga) != str(goal):
        reasons.append(f"分母不一致：界面 {goal}，OCR {gb}→{ga}")
    elif expected_goal is not None and str(goal) != str(expected_goal):
        reasons.append(f"分母 {goal} 不等于设置的每日目标 {expected_goal}")
    ok = not reasons
    return ok, (f"离开前 {before}/{goal} → 离开后 {after}/{goal}（OCR {ob}/{gb}→{oa}/{ga}）" if ok
                else "；".join(reasons))


DEFAULT_DAILY_GOAL = 4  # PomodoroSettings.dailyGoal 的默认值


def drive_abandon_count(run_id: str, state: dict, sim: str) -> int:
    """XCUITest 真点「开始专注」再真点「离开」提前结束，读主页「今天 x/目标」：不能加一；
    历史里应有一条 abandoned、没有 completed。"""
    out = scenario_dir(run_id, "abandon-count")
    install_sim(sim)
    test = run_xcuitest(run_id, sim, "testDriveAbandonDoesNotCountToday", out)
    ui = kv_text(out / "drive-abandon-values.txt")
    ocr_bin = frozen_ocr(run_id)
    counts = {}
    for stem in ("drive-abandon-before", "drive-abandon-after"):
        png = out / f"{stem}.png"
        texts = ocr(ocr_bin, png) if ocr_bin and png.exists() else []
        (out / f"ocr-{stem}.txt").write_text("\n".join(texts) + "\n")
        counts[stem] = today_count(texts)
    copy_documents(container_sim(sim), out / "Documents")
    terminate_sim(sim)
    # 每日目标：App 偏好里存过就用存的，没存过就是默认值。
    expected_goal = settings_blob(read_defaults(sim)).get("dailyGoal", DEFAULT_DAILY_GOAL)
    history = history_file(out)
    records = json.loads(history.read_text()) if history.exists() else []
    outcomes = [r.get("outcome") for r in records]
    ok, detail = judge_abandon_count(ui, counts["drive-abandon-before"], counts["drive-abandon-after"],
                                     expected_goal)
    history_ok = outcomes.count("abandoned") >= 1 and "completed" not in outcomes
    ok = ok and history_ok and test["ok"]
    write_json(out / "abandon-count.json", {"ok": ok, "test": test, "ui": ui, "ocr": counts,
                                            "historyOutcomes": outcomes, "expectedGoal": expected_goal,
                                            "when": now()})
    check(state, "drive:abandon-count", ok, f"{detail}；历史 {outcomes}；XCUITest exit={test.get('exit')}")
    write_state(run_id, state)
    return 0 if ok else 1


DRIVE_EXTRA = {
    "abandon-count": drive_abandon_count,
    "break-count": drive_break_count,
    "settings-scroll": drive_settings_scroll,
    "settings-toggle": drive_settings_toggle,
    "upgrade-063": drive_upgrade_063,
}

# r16 由 omp 临时写的 r16.py / run_cases.sh 覆盖的用例，沉淀为正式用例（对应 features/*.md）。
# keep=True 沿用上一个用例的沙盒（不重装）；时间都是相对启动的秒数。
CASES: dict[str, dict] = {
    "ac12-manual-pause": {"args": "-scenario longRun -focusMinutes 1 -shortBreakMinutes 1 -autopause 10:10 "
                          "-presetSettings autoStartBreak=1,autoStartFocus=1 -debug 0 -voice 0 -endSound none",
                          "shots": [(15, "manual-pause.png")], "wait": 145, "end": "after-resume.png"},
    "ac12-manual-report": {"args": "-report day", "keep": True, "wait": 6, "end": "report-manual-pause.png",
                           "after": "ac12-manual-pause"},
    "no-person-occlusion": {"args": "-scenario occlusion -focusMinutes 1 -debug 1 -voice 0",
                            "wait": 25, "end": "occlusion.png"},
    "no-person-occlusion-report": {"args": "-report day", "keep": True, "wait": 6,
                                   "end": "report-no-person.png", "after": "no-person-occlusion"},
    "pause-clean": {"args": "-scenario pauseWhileBreach -focusMinutes 1 -debug 1 -voice 0",
                    "shots": [(30, "absence-pause.png")], "wait": 35},
    "ac14-end-chime": {"args": "-scenario pomodoroDay -focusMinutes 1 -shortBreakMinutes 1 -endSound chime "
                       "-debug 0 -voice 0", "wait": 130, "end": "after-chime.png"},
    "ac14-end-none": {"args": "-scenario pomodoroDay -focusMinutes 1 -shortBreakMinutes 1 -endSound none "
                      "-debug 0 -voice 0", "wait": 130, "end": "after-none.png"},
    "ac14-goal": {"args": "-scenario pomodoroDay -focusMinutes 1 -shortBreakMinutes 1 -presetSettings dailyGoal=6 "
                  "-debug 0 -voice 0 -endSound none", "wait": 70, "end": "home-goal6.png"},
    "ac14-goal-report": {"args": "-seedHistory 30 -presetSettings dailyGoal=6 -report day", "wait": 8,
                         "end": "report-day-goal6.png"},
    "ac10-debug-on": {"args": "-scenario debugOffMonitoring -debug 1", "bg": [8], "fg": [12], "wait": 20,
                      "end": "debug-on.png"},
    "ac10-debug-off": {"args": "-scenario debugOffMonitoring -debug 0", "wait": 20, "end": "debug-off.png"},
    "ac9-parked": {"args": "-scenario headDown -holdStart 1 -focusMinutes 5 -debug 0", "bg": [5], "fg": [8],
                   "wait": 10, "end": "parked.png", "png": "parked.png"},
    "idle-focus": {"args": "-scenario pomodoroDay -focusMinutes 1 -shortBreakMinutes 1 -debug 0 -voice 0 "
                   "-endSound none", "shots": [(40, "focus-running.png")], "bg": [20, 70], "fg": [24, 74],
                   "wait": 88, "end": "break-running.png"},
    "ac6-week": {"args": "-seedHistory 30 -report week", "wait": 8, "end": "report-week.png"},
    "ac6-month": {"args": "-seedHistory 30 -report month", "wait": 8, "end": "report-month.png"},
    "full-day-detecting": {"args": "-scenario pomodoroDay -focusMinutes 1 -shortBreakMinutes 1 "
                           "-firstSampleDelay 1.4 -debug 1 -voice 0 -endSound none",
                           "shots": [(20, "focus1-breach.png"), (75, "break1.png"), (140, "focus2.png"),
                                     (250, "focus3.png")], "wait": 375, "end": "break3.png"},
}


def run_case(run_id: str, sim: str, name: str, spec: dict) -> dict:
    out = scenario_dir(run_id, name)
    launch_args = spec["args"].split()
    (out / "launch-args.txt").write_text(" ".join(launch_args) + "\n")
    if not spec.get("keep"):
        install_sim(sim)
    t0 = time.time()
    pid = launch_sim(sim, launch_args)
    timeline = [(float(d), "shot", n) for d, n in spec.get("shots", [])]
    timeline += [(float(d), "bg", "") for d in spec.get("bg", [])]
    timeline += [(float(d), "fg", "") for d in spec.get("fg", [])]
    events = []
    for delay, kind, payload in sorted(timeline):
        wait = delay - (time.time() - t0)
        if wait > 0:
            time.sleep(wait)
        if kind == "shot":
            ok = screenshot(sim, out / payload)
        elif kind == "bg":
            ok = sh(["xcrun", "simctl", "launch", sim, "com.apple.Preferences"], check=False).returncode == 0
        else:
            ok = launch_sim(sim, []) >= 0
        events.append({"at": round(time.time() - t0, 1), "kind": kind, "payload": payload, "ok": ok})
        print(f"{'PASS' if ok else 'FAIL'} {name} {kind} {payload} at {time.time() - t0:.1f}s")
    if spec.get("wait") is not None:
        wait = spec["wait"] - (time.time() - t0)
        if wait > 0:
            time.sleep(wait)
    if spec.get("end"):
        events.append({"at": round(time.time() - t0, 1), "kind": "shot", "payload": spec["end"],
                       "ok": screenshot(sim, out / spec["end"])})
    container = container_sim(sim)
    (out / "container.txt").write_text(container + "\n")
    copy_documents(container, out / "Documents")
    audit = audit_sandbox(container, out / "sandbox-audit.json")
    (out / "sandbox-audit.txt").write_text(audit.stdout + audit.stderr + f"\n[exit {audit.returncode}]\n")
    terminate_sim(sim)
    ocr_bin = frozen_ocr(run_id)
    if ocr_bin:
        for png in sorted(out.glob("*.png")):
            (out / f"ocr-{png.stem}.txt").write_text("\n".join(ocr(ocr_bin, png)) + "\n")
    if spec.get("png") and (out / spec["png"]).exists():
        write_json(out / "cloud-geometry.json", png_stats(out / spec["png"]))
        (out / "cloud-ascii.txt").write_text(ascii_art(out / spec["png"]) + "\n")
    provenance = {"case": name, "launchArgs": launch_args, "keptSandbox": bool(spec.get("keep")),
                  "pid": pid, "gitSha": FROZEN_SHA, "container": container, "events": events,
                  "sandboxAuditExit": audit.returncode, "when": now(),
                  "elapsedSeconds": round(time.time() - t0, 1)}
    write_json(out / "provenance.json", provenance)
    return provenance


def command_case(args) -> int:
    run_id = resolve_run(args.run)
    state = read_state(run_id)
    if load_preflight(run_id) is None:
        sys.exit("没有通过的 preflight，不开跑（ENV-BLOCKED）")
    names = list(CASES) if args.names == ["all"] else args.names
    unknown = [n for n in names if n not in CASES]
    if unknown:
        sys.exit(f"未登记的用例：{unknown}。先在 features/*.md 登记、再加进 verify.py 的 CASES；"
                 "omp 不得自己写脚本。")
    sim = state["udid"]
    code = 0
    for name in names:
        after = CASES[name].get("after")
        if after and after not in names and not (run_dir(run_id) / "scenarios" / after).exists():
            print(f"FAIL {name}: 要先跑 {after}（沿用它的沙盒）")
            code = 1
            continue
        provenance = run_case(run_id, sim, name, CASES[name])
        state.setdefault("cases", {})[name] = provenance
        audit_ok = provenance["sandboxAuditExit"] == 0
        check(state, f"case:{name}", audit_ok, f"elapsed={provenance['elapsedSeconds']}s "
              f"sandboxAudit exit={provenance['sandboxAuditExit']}")
        code |= 0 if audit_ok else 1
        write_state(run_id, state)
    return code


def command_list_cases(args) -> int:
    for name, spec in CASES.items():
        print(f"{name:28s} {spec['args']}  wait={spec.get('wait')}s"
              + (f"  keep(after {spec.get('after')})" if spec.get("keep") else ""))
    for name in DRIVE_EXTRA:
        print(f"drive {name}")
    return 0


# --- PNG 像素统计（点云占屏比例、叠加层区域；r16.py 沉淀） --------------------

def decode_png(path: Path):
    import zlib
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos = 8
    width = height = depth = color = None
    idat = bytearray()
    while pos < len(data):
        length = int.from_bytes(data[pos:pos + 4], "big")
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width = int.from_bytes(body[0:4], "big")
            height = int.from_bytes(body[4:8], "big")
            depth, color = body[8], body[9]
            assert body[12] == 0, "interlaced PNG unsupported"
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    assert depth == 8 and color in (2, 6), f"unsupported PNG depth={depth} color={color}"
    channels = 3 if color == 2 else 4
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    rows, previous, index = [], bytearray(stride), 0
    for _ in range(height):
        filter_type = raw[index]
        index += 1
        line = bytearray(raw[index:index + stride])
        index += stride
        if filter_type == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = previous[i]
                c = previous[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if (pa <= pb and pa <= pc) else (b if pb <= pc else c))) & 0xFF
        rows.append(line)
        previous = line
    return width, height, channels, rows


def png_stats(path: Path) -> dict:
    width, height, channels, rows = decode_png(path)

    def pixel(x, y):
        base = x * channels
        return tuple(rows[y][base:base + 3])

    background = pixel(2, 2)
    count = 0
    min_x, min_y, max_x, max_y = width, height, -1, -1
    for y in range(0, height, 2):
        for x in range(0, width, 2):
            rgb = pixel(x, y)
            if all(abs(rgb[i] - background[i]) <= 6 for i in range(3)):
                continue
            count += 1
            min_x, max_x = min(min_x, x), max(max_x, x)
            min_y, max_y = min(min_y, y), max(max_y, y)
    total = (width // 2) * (height // 2)
    return {"file": str(path), "width": width, "height": height, "background": list(background),
            "foregroundRatio": round(count / total, 4),
            "bbox": None if max_x < 0 else [min_x, min_y, max_x, max_y],
            "bboxAreaRatio": 0 if max_x < 0 else round(((max_x - min_x) * (max_y - min_y)) / (width * height), 4)}


def ascii_art(path: Path, cols: int = 60, rows_n: int = 60) -> str:
    width, height, channels, data = decode_png(path)
    ramp = " .:-=+*#%@"
    out = []
    for row in range(rows_n):
        line = []
        for col in range(cols):
            x0, x1 = col * width // cols, max(col * width // cols + 1, (col + 1) * width // cols)
            y0, y1 = row * height // rows_n, max(row * height // rows_n + 1, (row + 1) * height // rows_n)
            total = n = 0
            for y in range(y0, y1, max(1, (y1 - y0) // 6)):
                for x in range(x0, x1, max(1, (x1 - x0) // 6)):
                    base = x * channels
                    total += (data[y][base] * 299 + data[y][base + 1] * 587 + data[y][base + 2] * 114) // 1000
                    n += 1
            line.append(ramp[min(len(ramp) - 1, (total // max(1, n)) * len(ramp) // 256)])
        out.append("".join(line))
    return "\n".join(out)


def command_png(args) -> int:
    stats = [png_stats(Path(p)) for p in args.files]
    text = json.dumps(stats, ensure_ascii=False, indent=2)
    if args.json:
        Path(args.json).write_text(text + "\n")
    print(text)
    return 0


def command_ascii(args) -> int:
    for path in args.files:
        print(f"--- {path} ---")
        print(ascii_art(Path(path), args.cols, args.rows))
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
            p.add_argument("--launch", nargs="*", default=None)
        if name == "doctor":
            p.add_argument("--version", default=None, help="预期 CFBundleShortVersionString；默认取 preflight.json")
            p.add_argument("--build", default=None, help="预期 CFBundleVersion；默认取 preflight.json")
        if name == "drive":
            p.add_argument("scenario", nargs="?", default="all",
                           choices=["all", "pomodoro-focus", "posture-voice", "pause", "settings",
                                    *DRIVE_EXTRA.keys()])
        if name == "down":
            p.add_argument("--preflight-only", action="store_true", help="只跑过 preflight，不检查场景证据")
    pf = sub.add_parser("preflight", help="开跑前环境预检；不过就非零退出")
    pf.add_argument("--sha", required=True)
    pf.add_argument("--version", required=True)
    pf.add_argument("--build", required=True)
    pf.add_argument("--slug", required=True)
    pf.add_argument("--run", default=None, help="默认 r<下一个N>-<slug>；slug 本身是 r<N>-xxx 或 tl-xxx 时直接用")
    pf.add_argument("--min-free-gb", type=int, default=20)
    pc = sub.add_parser("preflight-cleanup", help="shell trap 兜底：把固定模拟器关机（不删除）")
    pc.add_argument("--run", required=True)
    cs = sub.add_parser("case", help="跑 features/*.md 里登记的扩展用例（list-cases 列出全部）")
    cs.add_argument("--run", default=None)
    cs.add_argument("names", nargs="+", help="用例名，或 all")
    sub.add_parser("list-cases", help="列出 case 子命令可跑的用例")
    pn = sub.add_parser("png", help="截图像素统计（点云包围盒、占屏比例）")
    pn.add_argument("files", nargs="+")
    pn.add_argument("--json")
    asc = sub.add_parser("ascii", help="截图的 ASCII 密度图")
    asc.add_argument("files", nargs="+")
    asc.add_argument("--cols", type=int, default=60)
    asc.add_argument("--rows", type=int, default=60)
    args = parser.parse_args()
    if args.command == "up" and args.run is None:
        parser.error("up 需要 --run <run-id>")
    return {
        "preflight": command_preflight,
        "preflight-cleanup": command_preflight_cleanup,
        "up": command_up,
        "doctor": command_doctor,
        "drive": command_drive,
        "evidence": command_evidence,
        "down": command_down,
        "case": command_case,
        "list-cases": command_list_cases,
        "png": command_png,
        "ascii": command_ascii,
    }[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
