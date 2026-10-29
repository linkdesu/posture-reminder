---
name: verify-posture-lab
description: 驱动 PostureLab iOS 模拟器或 iPhone 13 真机，端到端验证番茄钟、8 种体态监测、预录 WAV 语音提醒、设置页、统计页、离线与沙盒隐私边界及 42-key JSONL 日志契约，并采集可复查证据。
---

# PostureLab 验证技能

PostureLab 是纯离线的儿童专注与阅读坐姿应用。本技能用于真实启动构建产物、按用户路径驱动它、采集证据并清理现场。先读 `features/README.md` 选择特性，再按对应文件执行；不要用内部 setter 或测试专用入口代替用户路径。

## Preflight（开跑前必做）

**开跑前必须先跑 preflight；preflight 不过就不开跑。** 由 QA 在启动 omp 之前运行，omp 只在 preflight 通过的这一轮目录里取证：

```sh
cd /Volumes/Data/worktrees/posture-lab/depth-pose
scripts/verify-preflight.sh <目标SHA> <预期版本号> <预期build号> <轮次slug>
# 例：scripts/verify-preflight.sh 1a2b3c4 0.6.5 11 r16-v065-sim
```

等价于 `verify.py preflight --sha … --version … --build … --slug …`。slug 已经是 `r<N>-xxx` 时直接作为轮次目录；否则取 `tmp/verify/` 下最大的 N 加一。结果写入 `tmp/verify/<run-id>/preflight.json`，并把冻结值并入 `state.json`。任何一项不过都以非零码退出，`preflight.json.ok` 为 `false`。

检查项（按执行顺序）：

1. 记下 `~/Library/Logs/DiagnosticReports/PostureLab*.ips` 崩溃报告基线；
2. 工具链是 Xcode 27（`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`）、`simctl` 可用、`/Volumes/Data` 与用户目录剩余空间都不少于 20 GB（`--min-free-gb` 可调）；
3. 用 `git archive <SHA>` 导出代码快照，解到本轮专属目录 `/Volumes/Data/verify-builds/posture-lab/<run-id>/src` 并在那里构建（DerivedData 在同目录 `dd/`）。不碰共享 worktree 的未提交改动，也不用 `/tmp/pl-verify-build`；
4. 给本轮单独建一台模拟器（`pl-<run-id>`，iPhone 17），boot 完成后把 UDID 写进 `state.json`；
5. 产物 `Info.plist` 的版本号与 build 号必须等于预期值；装进模拟器后再读一次已安装的 `Info.plist`，并核对已安装二进制的哈希；
6. `simctl privacy grant camera` 预授权，无参启动后截图，OCR 确认没有系统权限弹窗；
7. 每种取证方法在一个 12 秒的短用例上试一次，必须拿到非空值：截图、OCR、拷贝沙盒 `Documents/`、读 debug 日志字段（`session-*.jsonl` 的 42 键与 `remaining_seconds`；`idle-*.jsonl` 的 `idle_timer_disabled`）；
8. 预检期间不得新增崩溃报告；
9. 把 SHA、快照哈希（`snapshot.tar` 的 sha256）、二进制哈希和 UDID 冻结进 `preflight.json.frozen`。

之后的 `up`、`drive` 只安装 preflight 冻结的那份产物（`frozen.appPath`），每次重装后自动预授权相机；没有通过的 preflight 时 `up`、`drive` 直接拒绝运行。轮次结束用 `verify.py down --run <run-id> --delete-sim` 删掉本轮模拟器。

## Launch

前置：

- macOS 与 Xcode 27；本机 `xcode-select -p` 可能指向 CommandLineTools，因此每条命令都显式设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。
- 默认模拟器 UDID：`C12DA589-2444-4F2E-A943-4D6BAFB02BF1`（iPhone 17）。真机：`00008110-001271181AD3801E`（iPhone 13），需解锁。
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
  --terminate-existing --device 00008110-001271181AD3801E me.xieal.posturelab
```

真机拉取沙盒：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device copy from \
  --device 00008110-001271181AD3801E --domain-type appDataContainer \
  --domain-identifier me.xieal.posturelab --source Documents \
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
- `pause`：`-scenario pauseWhileBreach -focusMinutes 1 -debug 0`，30 秒截图，覆盖无人暂停。
- `settings`：`-settings 1`，截图设置页。
- `report`：先 `-seedHistory 30 -report day` 截图并复制历史；然后杀进程、**不重装**、以 `-report day` 重开，证明历史来自磁盘。

每次启动都记录 `launch-args.txt`、`provenance.json`、截图、`Documents/` 与 `sandbox-audit.json`。详细特性入口见 `features/`。

XCUITest 只用于模拟器无法用 launch argument 表达的真实点击（例如设置页 10 项参数逐项修改、手动输入数字与杀进程重启持久化）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project PostureLab.xcodeproj -scheme PostureLab \
  -destination "platform=iOS Simulator,id=C12DA589-2444-4F2E-A943-4D6BAFB02BF1" \
  -only-testing:PostureLabUITests/SettingsPersistenceUITests test
```

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

证据标准：

- 驱动真实用户路径（启动参数、真实控件、真实杀进程重启），不用内部 setter 或测试后门。
- 同时保留动作与结果：截图、JSONL、历史文件、审计 JSON，而不是只看最终屏幕。
- 逐行校验 42-key JSONL 契约（v0.6 起含事件 `segment`：识别中段关闭时一行，该行只有 `segment_*` 四个键非 `null`）；用 `scripts/verify-session.py`、`scripts/verify-pomodoro.py`、`scripts/verify-acceptance.py` 复算，不信任应用自报。
- 隐私用 `scripts/audit-offline.py`（源码）与 `scripts/audit-sandbox.py`（运行时容器）双重审计。
- 如果当前实现与 `GLOSSARY.md` / ADR-0001..0005 的已确认规则不一致（Q1 默认启动页、Q2 `pausedSeconds` 对账、Q3 静默校准、Q4 点云/实验级提醒），如实报失败并写入对应特性的 `Gotchas`；不要弱化断言来换取通过。

## Cleanup

```sh
.omp/skills/verify-posture-lab/scripts/verify.py down --run r9-skill-smoke
```

`down` 只终止本次验证启动的 App；只有 `state.json.bootedByUs` 为真时才关闭模拟器。它不删除 `tmp/verify/<run-id>/`，并在退出前确认 `state.json`、截图、JSONL、审计输出仍然存在。

清理后再次确认：

```sh
ls tmp/verify/r9-skill-smoke/scenarios/pomodoro-focus/Documents/debug/session-*.jsonl
ls tmp/verify/r9-skill-smoke/launch/pomodoro_main.png
```

真机清理只终止本次启动的进程；不要按进程名批量结束其他 App。

## Helpers

- `scripts/verify.py`：本技能的唯一编排器，子命令 `preflight`、`up`、`doctor`、`drive`、`evidence`、`down`；除 `preflight` 外都接受 `--run <run-id>`。
- `scripts/ocr.swift`：Vision OCR，preflight 用 `swiftc` 编译到本轮构建目录后使用。
- 仓库 `scripts/verify-preflight.sh`：preflight 的包装，参数依次是目标 SHA、预期版本号、预期 build 号、轮次 slug。
- `scripts/audit-offline.py`、`scripts/audit-sandbox.py`、`scripts/verify-session.py`、`scripts/verify-pomodoro.py`、`scripts/verify-acceptance.py`、`scripts/check-overlay.py`：仓库既有验收脚本，由 `verify.py` 以显式路径调用。
- `features/`：特性地图；先读 `features/README.md`，再按需打开对应文件。
