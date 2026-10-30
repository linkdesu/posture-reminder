---
name: verify-posture-lab
description: 驱动 PostureLab iOS 模拟器或 iPhone 13 真机，端到端验证番茄钟、8 种体态监测、预录 WAV 语音提醒、设置页、统计页、离线与沙盒隐私边界及 43-key JSONL 日志契约（含真机 device-logs 判定），并采集可复查证据。
---

# PostureLab 验证技能

PostureLab 是纯离线的儿童专注与阅读坐姿应用。本技能用于真实启动构建产物、按用户路径驱动它、采集证据并清理现场。先读 `features/README.md` 选择特性，再按对应文件执行；不要用内部 setter 或测试专用入口代替用户路径。

## Preflight（开跑前必做）

**开跑前必须先跑 preflight；preflight 不过就不开跑。** 由 QA 在启动 omp 之前运行，omp 只在 preflight 通过的这一轮目录里取证：

```sh
cd /Volumes/Data/worktrees/posture-lab/depth-pose
scripts/verify-preflight.sh <目标SHA> <预期版本号> <预期build号> <轮次slug>
# 例：scripts/verify-preflight.sh 1a2b3c4 0.6.7 13 r17-v067-sim
```

等价于 `verify.py preflight --sha … --version … --build … --slug …`。slug 已经是 `r<N>-xxx` 时直接作为轮次目录；`tl-` 开头的是 TL 自测 smoke，也直接作为目录名，不占 r 序号；否则取 `tmp/verify/` 下最大的 N 加一。结果写入 `tmp/verify/<run-id>/preflight.json`，并把冻结值并入 `state.json`。任何一项不过都以非零码退出，`preflight.json.ok` 为 `false`。

检查项（按执行顺序）：

1. 记下 `~/Library/Logs/DiagnosticReports/PostureLab*.ips` 崩溃报告基线；
1a. 若处于 Booted 的模拟器**超过一台**，或有**任何一台不是 `pl-verify`**，判 **ENV-BLOCKED**，在 `preflight.json` 的 `frozen.bootedBlockers` 和输出里列出名称和 UDID，**不自动关、不自动删**，交给人工处理后重跑预检；
2. 工具链是 Xcode 27（`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`）、`simctl` 可用、`/Volumes/Data` 与用户目录剩余空间都不少于 20 GB（`--min-free-gb` 可调）；
3. 用 `git archive <SHA>` 导出代码快照，解到本轮专属目录 `/Volumes/Data/verify-builds/posture-lab/<run-id>/src` 并在那里构建（DerivedData 在同目录 `dd/`）。不碰共享 worktree 的未提交改动，也不用 `/tmp/pl-verify-build`；
4. 只用**固定模拟器 `pl-verify`**（iPhone 17，iOS 27.0）：每轮复用，不新建、不删除（不存在时才建一次）；先卸载 App 保证沙盒干净，boot 完成后把 UDID 写进 `state.json`。构建用 `build-for-testing`，同一份冻结产物里带 `.xctestrun`，供 `drive` 的 XCUITest 入口使用；
5. 产物 `Info.plist` 的版本号与 build 号必须等于预期值；装进模拟器后再读一次已安装的 `Info.plist`，并核对已安装二进制的哈希；
6. `simctl privacy grant camera` 预授权，无参启动后截图，OCR 确认没有系统权限弹窗；
7. 每种取证方法在一个 12 秒的短用例上试一次，必须拿到非空值：截图、OCR、拷贝沙盒 `Documents/`、读 debug 日志字段（`session-*.jsonl` 的 43 键与 `remaining_seconds`；`idle-*.jsonl` 的 `idle_timer_disabled`）；
8. 预检期间不得新增崩溃报告；
9. 把 SHA、快照哈希（`snapshot.tar` 的 sha256）、二进制哈希和 UDID 冻结进 `preflight.json.frozen`。

**固定模拟器的收尾**：`verify.py preflight` 用 `finally` 兜住正常退出、失败、Ctrl-C 与 TERM/HUP，`verify-preflight.sh` 再用 `trap … EXIT INT TERM HUP` 调 `verify.py preflight-cleanup --run <run-id>` 兜底。规则只有一条：**`pl-verify` 永远保留，只关机**。预检（含只跑预检、dry-run、失败、中断）结束时关机，结果写在 `preflight.json.simCleanup`（`shutdown`）；`up` 会再把它开起来；一轮结束 `verify.py down --run <run-id>` 也只关机。`--keep-sim`、`--delete-sim` 已删除。

之后的 `up`、`drive`、`case` 只安装 preflight 冻结的那份产物（`frozen.appPath`），每次重装后自动预授权相机；没有通过的 preflight 时直接拒绝运行。`up` 开机前同样检查：有 `pl-verify` 以外的模拟器在 Booted 就 ENV-BLOCKED。

**工具链**：`verify.py` 在进程启动时就设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，`preflight`/`up`/`doctor`/`drive`/`case`/`evidence`/`down`/`audit` 等所有入口及其子进程都继承它，非交互 shell 里也能直接调 `xcrun simctl`。

## Launch

前置：

- macOS 与 Xcode 27；本机 `xcode-select -p` 可能指向 CommandLineTools，因此每条命令都显式设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。
- 模拟器：固定的 `pl-verify`（UDID 见 `preflight.json.frozen.udid`）。真机：`00008110-001271181AD3801E`（iPhone 13），需解锁。
- Bundle id：`me.xieal.posturelab.depth`（深度版）。

模拟器从干净数据目录启动：

```sh
cd /Volumes/Data/worktrees/posture-lab/depth-pose
.omp/skills/verify-posture-lab/scripts/verify.py up --run r9-skill-smoke
```

`up` 会：

1. 启动并等待模拟器；
2. 不再构建：安装 preflight 冻结的 `frozen.appPath`（模拟器也用 preflight 建的那台）；
3. 卸载/安装 `PostureLab.app` 并预授权相机，无参启动（应用直接进入番茄钟主页 `pomodoro_main`）；
4. 把 pid、容器路径、gitSha、branch、target、时间戳和检查结果写入 `tmp/verify/<run-id>/state.json`；
5. 更新 `tmp/verify/latest` 软链接，截图 `launch/pomodoro_main.png`。

就绪判据：`state.json` 有非空 `pid` 与 `appContainerDataPath`，`launch/pomodoro_main.png` 存在，且 `doctor` 全绿。只是进程存在不算就绪。

真机：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project PostureLab.xcodeproj -scheme PostureLab \
  -destination "id=00008110-001271181AD3801E" \
  -allowProvisioningUpdates -derivedDataPath /tmp/pl-verify-device build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app \
  --device 00008110-001271181AD3801E /tmp/pl-verify-device/Build/Products/Debug-iphoneos/PostureLab.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device process launch \
  --terminate-existing --device 00008110-001271181AD3801E me.xieal.posturelab.depth
```

真机拉取沙盒：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device copy from \
  --device 00008110-001271181AD3801E --domain-type appDataContainer \
  --domain-identifier me.xieal.posturelab.depth --source Documents \
  --destination tmp/verify/<run-id>/device
```

## Doctor

只读健康检查。任何异常先跑它，不要盲目重启：

```sh
.omp/skills/verify-posture-lab/scripts/verify.py doctor --run r9-skill-smoke [--version 0.6.5 --build 11]
```

检查：preflight 已通过、模拟器已启动、App 进程在跑、数据容器可读；已安装的版本号与 build 号**等于预期值**（`--version`/`--build`，默认取 `preflight.json.expected`），不是「读得出来就算过」；`state.json` 的 `gitSha` 等于 preflight 冻结的**快照 SHA**（不看共享 worktree 的 HEAD）；已安装二进制哈希等于冻结的 `binarySha256`。结果写入 `tmp/verify/<run-id>/doctor.json`，并汇总进 `state.json.checks.doctor`。

Doctor 失败时，环境异常标 ENV-BLOCKED 或 BLOCKED，禁止临场修环境（不重新 boot、不重新 install、不重建、不改代码），也不要在错误的实例上取证；把失败项和 `doctor.json` 写进报告，交回 QA 重新跑 preflight。

## Drive

一次完整驱动（每个场景都重装以隔离数据）：

```sh
.omp/skills/verify-posture-lab/scripts/verify.py drive --run r9-skill-smoke
```

运行器会执行：

- `pomodoro-focus`：`-scenario pomodoroDay -focusMinutes 1 -shortBreakMinutes 1 -voice 1 -debug 1 -endSound chime`，在 35 秒、70 秒与 130 秒截图；130 秒时休息结束，历史写入第一条完成记录；70 秒日志快照用于历史对账。
- `posture-voice`：`-scenario deskLean -focusMinutes 1 -shortBreakMinutes 1 -voice 1 -debug 1`，30 秒截图，覆盖多体态串行语音与二级播放。
- `pause`：`-scenario pauseWhileBreach -focusMinutes 1 -debug 0`，30 秒截图，**等满 35 秒**（脚本跑完、历史落盘）再收证据、结束进程，覆盖无人暂停。
- `settings`：`-settings 1`，截图设置页。
- `report`：先 `-seedHistory 30 -report day` 截图并复制历史；然后杀进程、**不重装**、以 `-report day` 重开，证明历史来自磁盘。

每次启动都记录 `launch-args.txt`、`provenance.json`、截图、`Documents/` 与 `sandbox-audit.json`。详细特性入口见 `features/`。

`drive` 也可以只跑一个场景：`verify.py drive --run <run-id> <场景>`，场景是 `pomodoro-focus`、`posture-voice`、`pause`、`settings`，以及下面这些（v0.6.7 起）：

| 场景 | 做什么 | 判据（`scenarios/<场景>/*.json`） |
|---|---|---|
| `break-count` | `pomodoroDay` 1 分钟专注，在 20 s（专注中）、75 s（休息中）、135 s（下一段专注）截图并 OCR | 「今天 x/目标」依次为 0 → **1**（休息中已加一）→ 1（不重复加） |
| `abandon-count` | XCUITest `VerifyDriveUITests/testDriveAbandonDoesNotCountToday`：停驻在 1 分钟专注上，**真点**「开始专注」，跑 5 s 后**真点**「离开」提前结束，读主页「今日目标」标签前后两次，并对前后截图 OCR「今天 x/目标」；再从 `Documents/pomodoro-history.json` 读回记录 | 界面与 OCR 计数前后相等（不加一）；分母 goal 在界面与前后截图里一致且等于设置的每日目标（未设置时为默认 4）；历史里至少一条 `abandoned`、没有 `completed`（`abandon-count.json.ok`） |
| `settings-scroll` | XCUITest `VerifyDriveUITests/testDriveSettingsScrollCountsTenSettings`：逐项滚到并数出番茄钟 10 项，滚到下半屏截图 | `count=10`、无「屏幕常亮」行，`drive-settings-bottom.png` 存在 |
| `settings-toggle` | XCUITest 真点一次「自动开始休息」，再从 App 数据容器的 `Library/Preferences/me.xieal.posturelab.depth.plist` 读回 `pomodoro.settings` | 界面值变了，**存储里的 `autoStartBreak` 也变了**且与界面一致 |
| `upgrade-063` | 构建 0.6.3（`c9d5f42`，缓存在 `verify-builds/posture-lab/legacy-063`）→ 装上 → XCUITest 在 **0.6.3 的界面上真点**「屏幕常亮」关掉 → 读回存储 `keepScreenAwake=false` → 覆盖安装冻结新版 → 设置页无常亮行、旧 key 存活、专注 `focus_start` 为 true | `upgrade.json.ok` |

XCUITest 驱动的场景（`abandon-count`、`settings-scroll`、`settings-toggle`、`upgrade-063`）跑完后同样在场景目录留下 `launch-args.txt`（用例里的启动参数）、`provenance.json`（`driver=xcuitest`、用例名、已装版本、容器路径、`sandboxAuditExit`）和 `sandbox-audit.json` / `sandbox-audit.txt`，作为运行时沙盒审计（AC14/AC19）的证据。

XCUITest 入口用 preflight 的 `build-for-testing` 产物跑 `xcodebuild test-without-building -xctestrun …`，截图与文本是 `.keepAlways` 附件，`verify.py` 用 `xcresulttool export attachments` 导出到场景目录。升级场景会从 `.xctestrun` 里去掉被测 App，免得 xcodebuild 用新版覆盖已装的 0.6.3。不再直接写 plist 伪造旧版设置。

### 扩展用例（`verify.py case`）

r16 由 omp 临时写的 `r16.py` / `run_cases.sh` 覆盖的用例已沉淀为正式子命令，并登记在 `features/*.md`：

```sh
.omp/skills/verify-posture-lab/scripts/verify.py list-cases
.omp/skills/verify-posture-lab/scripts/verify.py case --run <run-id> ac12-manual-pause ac12-manual-report
.omp/skills/verify-posture-lab/scripts/verify.py case --run <run-id> all
.omp/skills/verify-posture-lab/scripts/verify.py png scenarios/ac9-parked/parked.png --json out.json   # 点云包围盒/占屏比
.omp/skills/verify-posture-lab/scripts/verify.py ascii scenarios/ac9-parked/parked.png
```

每个用例都会：（除 `keep` 用例外）重装冻结产物、按时间表截图 / 切后台 / 回前台、等满计划时长、导出 `Documents/` 与沙盒审计、OCR 每张截图、写 `provenance.json`。`*-report` 用例沿用前一个用例的沙盒，要和它一起跑。

**omp 不得自己写脚本**（不得在 `tmp/verify/**/tools/` 或任何地方新建驱动脚本、Python/Shell 片段）。需要的用例不在 `list-cases` 里，就停下来报 BLOCKED，由 QA 先登记到 `features/*.md`、TL 加进 `verify.py`。

## Evidence

```sh
.omp/skills/verify-posture-lab/scripts/verify.py evidence --run r9-skill-smoke
```

证据目录：

```
tmp/verify/<run-id>/
├── state.json
├── doctor.json
├── verification.json
├── launch/pomodoro_main.png
├── audits/offline.txt
└── scenarios/<scenario>/
    ├── launch-args.txt
    ├── provenance.json
    ├── *.png
    ├── Documents/debug/session-*.jsonl
    ├── Documents/pomodoro-history.json
    ├── sandbox-audit.json
    └── verification/*.txt
```

**分批运行**：`evidence` 只判本批真跑过的核心场景（`pomodoro-focus`、`posture-voice`、`pause`、`report`、`settings`，以 `state.json` 的记录或场景目录里的 `provenance.json` 为准），没跑的列在 `verification.json.skipped`，不算失败；`ran` 列出本批真跑过的全部场景：核心场景名，加上 `drive:<场景>` 与 `case:<用例>`；本批跑过的 `drive:*` / `case:*` 判定一并汇总进 `results`。一个场景都没跑时 `ok=false`。

证据标准：

- 驱动真实用户路径（启动参数、真实控件、真实杀进程重启），不用内部 setter 或测试后门。
- 同时保留动作与结果：截图、JSONL、历史文件、审计 JSON，而不是只看最终屏幕。
- 逐行校验 43-key JSONL 契约（v0.6 起含事件 `segment`：识别中段关闭时一行，该行只有 `segment_*` 四个键非 `null`；v0.6.8 起含事件 `thermal`：降级起止各一行，只有 `thermal_degraded` 非 `null`）；用 `scripts/verify-session.py`、`scripts/verify-pomodoro.py`、`scripts/verify-acceptance.py` 复算，不信任应用自报。
- 隐私用 `scripts/audit-offline.py`（源码）与 `scripts/audit-sandbox.py`（运行时容器）双重审计。
- 如果当前实现与 `GLOSSARY.md` / ADR-0001..0005 的已确认规则不一致（Q1 默认启动页、Q2 `pausedSeconds` 对账、Q3 静默校准、Q4 点云/实验级提醒），如实报失败并写入对应特性的 `Gotchas`；不要弱化断言来换取通过。

## 真机日志判定（`device-logs`）

0.6.8 起关节来自前置摄像头 Vision，模拟器没有前置彩色摄像头，所以关节准确率、点云帧间隔、发热
降级、耗电与真实彩色帧的隐私只能真机验。`device-logs` 负责这一段取证与判定：

```sh
# 拷真机 Documents/debug 并判五条标准（设备 UDID 默认 00008110-001271181AD3801E）
.omp/skills/verify-posture-lab/scripts/verify.py device-logs --run <run-id> [--focus-seconds 600]

# 已经拷好时直接判本地目录，不连真机
.omp/skills/verify-posture-lab/scripts/verify.py device-logs --run <run-id> --dir tmp/verify/<run-id>/device/Documents/debug
```

它把 `Documents/debug` 拷到 `tmp/verify/<run-id>/device/Documents/debug`，读 `session-*.jsonl`、
`perf-*.jsonl`、`joints-*.jsonl`，按 0.6.8 的验收口径逐条打印 `PASS`/`FAIL`/`SKIP` 并写
`device/verdict.json`：

| 判定 | 依据 | 门槛 |
|---|---|---|
| `upper-body-only` | `joints-*.jsonl` 的 `joints` 键集合 | ⊆ 鼻/双眼/双耳/颈/双肩；出现髋、root、肘、腕即 FAIL |
| `shoulders-not-on-head` | `shoulders_invalidated` | 帧数 = 0 |
| `shoulders-available-ratio` | 未过期关节帧按 `status_changed` 窗口分组 | 坐直 ≥ 80%，歪头 ≥ 50%，低头 ≥ 50%；窗口内无证据记 SKIP |
| `cloud-smooth` | 未降级秒的 `cloud_gap_p95_ms` / `cloud_gap_max_ms` / `cloud_points` | p95 ≤ 40 ms、最长 ≤ 200 ms、点数 = 600 |
| `degradation` | `thermal` 行配对的降级时段 | 正常室温 10 分钟专注里降级时长 ≤ 20%，逐段打印开始时间与时长 |

自测（不连真机）：`python3 .omp/skills/verify-posture-lab/scripts/test_device_logs.py`。

## 验收结论模板

一轮验收的结论按这几节写，最后一节必须单独列「模拟器测不到的项」：

1. 版本与产物：版本号、build 号、二进制哈希、冻结 SHA。
2. 模拟器证据：`verification.json` 的逐项结果、沙盒审计、离线与彩色帧边界审计。
3. 真机证据：`device-logs` 五条判定与 `verdict.json`。
4. **模拟器测不到的项**（只能真机验，模拟器上没有对应硬件，缺这一节等于结论不完整）：
   - 关节准确率：双肩可用帧占比（坐直 ≥ 80%、歪头与低头各 ≥ 50%）、「肩点落在头上」的帧数（必须为 0）；
   - 点云更新间隔：未降级时 p95 ≤ 40 ms、最长间隔 ≤ 200 ms；
   - 发热降级：10 分钟专注里降级时长与占比（> 20% 判失败）、`thermal` 行是否成对；
   - 耗电：`perf-*.jsonl` 的 `battery_level` 首末差；
   - 真实彩色帧的隐私：单帧缓冲、无预览、无图片/视频文件、无联网（模拟器没有前置彩色摄像头，只能靠静态审计 + 真机沙盒审计）。

## Cleanup

```sh
.omp/skills/verify-posture-lab/scripts/verify.py down --run r9-skill-smoke
```

`down` 只终止本次验证启动的 App，并把 `pl-verify` 关机（不删除）。它不删除 `tmp/verify/<run-id>/`，并在退出前确认证据仍然存在：总是要求 `state.json`、`verification.json`、`audits/offline.txt`；本批跑过 `up` 才要求 `launch/pomodoro_main.png`，跑过 `pomodoro-focus` 才要求它的截图与 `provenance.json`。分批没跑的场景不会让 `down` 以 1 退出。

清理后再次确认：

```sh
ls tmp/verify/r9-skill-smoke/scenarios/pomodoro-focus/Documents/debug/session-*.jsonl
ls tmp/verify/r9-skill-smoke/launch/pomodoro_main.png
```

真机清理只终止本次启动的进程；不要按进程名批量结束其他 App。

## Helpers

- `scripts/verify.py`：本技能的唯一编排器，子命令 `preflight`、`preflight-cleanup`、`up`、`doctor`、`drive [场景]`、`case`、`list-cases`、`png`、`ascii`、`evidence`、`down`。
- 仓库 `scripts/test_audit_sandbox.py`：`audit-sandbox.py` 的自测（系统文件白名单不误报、真违规 exit 1）。
- `.omp/skills/verify-posture-lab/scripts/test_verify.py`（与 `verify.py` 同目录，不在仓库 `scripts/` 下；运行 `python3 .omp/skills/verify-posture-lab/scripts/test_verify.py`）：`verify.py` 的自测（不碰模拟器）：分批 `evidence` / `down` 只判本批场景、`abandon-count` 的判定（含分母）、XCUITest 场景的 provenance / 沙盒审计产物、`ran` 字段。
- 仓库 `scripts/test_verify_session.py`：`verify-session.py` AC6 的自测：多番茄日志按 `session_started` 分段、每个 `session_ended` 只和本段样本比对；没有 `session_ended` 的短日志记 SKIP（`--expect-summary` 时 FAIL）；数字真错仍 FAIL。
- `scripts/ocr.swift`：Vision OCR，preflight 用 `swiftc` 编译到本轮构建目录后使用。
- 仓库 `scripts/verify-preflight.sh`：preflight 的包装，参数依次是目标 SHA、预期版本号、预期 build 号、轮次 slug。
- `scripts/audit-offline.py`、`scripts/audit-sandbox.py`、`scripts/verify-session.py`、`scripts/verify-pomodoro.py`、`scripts/verify-acceptance.py`、`scripts/check-overlay.py`：仓库既有验收脚本，由 `verify.py` 以显式路径调用。
- `features/`：特性地图；先读 `features/README.md`，再按需打开对应文件。
