---
name: verify-posture-lab
description: 驱动 PostureLab iOS 模拟器或 iPhone 13 真机，端到端验证番茄钟、8 种体态监测、预录 WAV 语音提醒、设置页、统计页、离线与沙盒隐私边界及 38-key JSONL 日志契约，并采集可复查证据。
---

# PostureLab 验证技能

PostureLab 是纯离线的儿童专注与阅读坐姿应用。本技能用于真实启动构建产物、按用户路径驱动它、采集证据并清理现场。先读 `features/README.md` 选择特性，再按对应文件执行；不要用内部 setter 或测试专用入口代替用户路径。

## Launch

前置：

- macOS 与 Xcode 27；本机 `xcode-select -p` 可能指向 CommandLineTools，因此每条命令都显式设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。
- 默认模拟器 UDID：`C12DA589-2444-4F2E-A943-4D6BAFB02BF1`（iPhone 17）。真机：`00008110-001271181AD3801E`（iPhone 13），需解锁。
- Bundle id：`me.xieal.posturelab`。

模拟器从干净数据目录启动：

```sh
cd /Volumes/Data/worktrees/posture-lab/v0.4-v0.5-sim
.omp/skills/verify-posture-lab/scripts/verify.py up --run r9-skill-smoke
```

`up` 会：

1. 启动并等待模拟器；
2. 用 `xcodebuild -project PostureLab.xcodeproj -scheme PostureLab -destination "platform=iOS Simulator,id=<udid>" -derivedDataPath /tmp/pl-verify-build build` 构建；
3. 卸载/安装 `PostureLab.app`，以 `-pomodoro 1` 启动；
4. 把 pid、容器路径、gitSha、branch、target、时间戳和检查结果写入 `tmp/verify/<run-id>/state.json`；
5. 更新 `tmp/verify/latest` 软链接，截图 `launch/home.png`。

就绪判据：`state.json` 有非空 `pid` 与 `appContainerDataPath`，`launch/home.png` 存在，且 `doctor` 全绿。只是进程存在不算就绪。

真机：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project PostureLab.xcodeproj -scheme PostureLab \
  -destination "id=00008110-001271181AD3801E" \
  -allowProvisioningUpdates -derivedDataPath /tmp/pl-verify-device build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app \
  --device 00008110-001271181AD3801E /tmp/pl-verify-device/Build/Products/Debug-iphoneos/PostureLab.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device process launch \
  --terminate-existing --device 00008110-001271181AD3801E me.xieal.posturelab -- -pomodoro 1
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
.omp/skills/verify-posture-lab/scripts/verify.py doctor --run r9-skill-smoke
```

检查：模拟器已启动、App 进程在跑、数据容器可读、`CFBundleShortVersionString` 可读、当前 `git rev-parse HEAD` 与 `state.json` 的 `gitSha` 一致。结果写入 `tmp/verify/<run-id>/doctor.json`，并汇总进 `state.json.checks.doctor`。

Doctor 失败时先修复环境（解锁真机、重新 boot、重新 install），不要在错误的实例上取证。

## Drive

一次完整驱动（每个场景都重装以隔离数据）：

```sh
.omp/skills/verify-posture-lab/scripts/verify.py drive --run r9-skill-smoke
```

运行器会执行：

- `pomodoro-focus`：`-pomodoro 1 -scenario pomodoroDay -focusMinutes 1 -shortBreakMinutes 1 -voice 1 -debug 1 -endSound chime`，在 35 秒、70 秒与 130 秒截图；130 秒时休息结束，历史写入第一条完成记录；70 秒日志快照用于历史对账。
- `posture-voice`：`-pomodoro 1 -scenario deskLean -focusMinutes 1 -shortBreakMinutes 1 -voice 1 -debug 1`，30 秒截图，覆盖多体态串行语音与二级播放。
- `pause`：`-pomodoro 1 -scenario pauseWhileBreach -focusMinutes 1 -debug 0`，30 秒截图，覆盖无人暂停。
- `settings`：`-pomodoro 1 -settings 1`，截图设置页。
- `report`：先 `-pomodoro 1 -seedHistory 30 -report day` 截图并复制历史；然后杀进程、**不重装**、以 `-pomodoro 1 -report day` 重开，证明历史来自磁盘。

每次启动都记录 `launch-args.txt`、`provenance.json`、截图、`Documents/` 与 `sandbox-audit.json`。详细特性入口见 `features/`。

XCUITest 只用于模拟器无法用 launch argument 表达的真实点击（例如设置页 12 项参数逐项修改与杀进程重启持久化）：

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
├── launch/home.png
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
- 逐行校验 38-key JSONL 契约；用 `scripts/verify-session.py`、`scripts/verify-pomodoro.py`、`scripts/verify-acceptance.py` 复算，不信任应用自报。
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
ls tmp/verify/r9-skill-smoke/launch/home.png
```

真机清理只终止本次启动的进程；不要按进程名批量结束其他 App。

## Helpers

- `scripts/verify.py`：本技能的唯一编排器，子命令 `up`、`doctor`、`drive`、`evidence`、`down`；所有子命令接受 `--run <run-id>`。
- `scripts/audit-offline.py`、`scripts/audit-sandbox.py`、`scripts/verify-session.py`、`scripts/verify-pomodoro.py`、`scripts/verify-acceptance.py`、`scripts/check-overlay.py`：仓库既有验收脚本，由 `verify.py` 以显式路径调用。
- `features/`：特性地图；先读 `features/README.md`，再按需打开对应文件。
