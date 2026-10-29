# 代理协作说明

PostureLab——iOS 17、仅 iPhone 的阅读坐姿伴侣应用（Swift/SwiftUI，使用 xcodegen 构建）。纯离线运行；原型目标设备为带 TrueDepth 人脸追踪的 iPhone 13。

## 目录结构

- `PostureLab/Domain/`——纯逻辑：`PostureSample`、`PostureClassifier`（基线、特征、判定）、`MonitoringEngine`（按体态拆分的、由注入时间驱动的回合状态机）、`MonitoringEvent`/`LogRecord`、`Sensitivity`、`SessionSummary`、`SampleSource`。番茄钟一侧包括：`PomodoroEngine`（阶段状态机）、`PomodoroRecord`、`PomodoroHistory`（统计聚合）、`PomodoroSettings`、`PomodoroSettingsStore`、`PomodoroStore`（本机历史）。
- `PostureLab/Input/`——`SampleSource` 的各实现：真实 ARKit 人脸追踪、脚本化 `Scenario` 数据源，以及 `BodyRig`（为无摄像头运行提供确定性的合成关节点与 24×32 深度帧）。
- `PostureLab/Session/`——`SessionController`（生命周期、番茄钟协调、暂停接线）与 `ReminderPlayer`（预录音频与提示音）。
- `PostureLab/Views/`——孩子侧番茄钟界面（`PomodoroView`）、设置页（`PomodoroSettingsView`）、统计页（`ReportView`）、`AvatarView`/`BodyCloud`、`DebugOverlayView`，以及共享的 `PosturePalette`；`RootView` 只在主页、设置页与统计页之间切换。
- `PostureLab/Resources/Audio/`——每个可发声体态一条**占位** WAV，文件名使用该体态的 `rawValue`，另有阶段结束提示音。占位文件由脚本生成、并非真人录音；替换为真实录音时保留原文件名。应用内没有文字转语音。
- `PostureLabTests/`——单元测试；它们只走单一测试缝（样本序列 → 引擎；见 ADR-0001）。

应用无参启动即进入番茄钟主页 `pomodoro_main`：番茄钟是用户侧唯一主流程，旧的「开始阅读」入口流程（主页 → 校准 → 监测 → 小结与阅读设置）已退役（ADR-0006），`-pomodoro` 启动参数也已删除。`-settings 1` 直接打开番茄钟设置页，`-report day|week|month` 直接打开统计页；脚本场景（`-scenario`、`-focusMinutes` 等）同样直接落在番茄钟上。番茄钟中关闭一级提示音，只播放二级预录语音——这是 ADR-0004 的零注意力打扰规则；阶段结束提示音是独立的、非体态提醒的音频路径，设置页的试听只发声、不写 `cue_played`。

## 规范与约定

- **文档语言（硬性规则）**：仓库内所有文档（包括 AGENTS.md、GLOSSARY.md、docs/adr/、docs/agents/、docs/qa-log-schema.md、模块 README 以及通过 to-spec / to-tickets / pr 发布的 GitHub Issue、Spec、Ticket 和 PR 描述）必须统一使用中文编写与维护；仅代码标识符、日志 JSON 键名、Git 标签与 CLI 命令保留英文原名。
- JSONL 日志 schema 是与 QA 的契约——snake_case 键名、`ts` 为 epoch 毫秒、每行都带完整的 **38 个键**。v0.3 增加了 `features` 与 `view_mode`；v0.4/v0.5 增加了 `pomodoro_tick`（`remaining_seconds`、`phase`）、`speech_played`、`cue_played`、`posture_stats`，以及每个专注阶段一对 `session_started`/`session_ended`。共有八种体态（含 `shoulder_tilt`），实验级体态永不发声。修改 schema 必须先让 QA 知情（ADR-0002）；阅读 `docs/qa-log-schema.md` 以解释一次会话日志。
- 领域词汇见 `GLOSSARY.md`。难以逆转的决策存放在 `docs/adr/`：请阅读 ADR-0001（测试缝）、ADR-0002（日志契约）、ADR-0003（双层状态机与暂停硬门控）、ADR-0004（非侵入式预录提醒）、ADR-0005（纯离线与 3D 人形点云隐私边界）与 ADR-0006（番茄钟主页是唯一入口）。

## 代理技能与工作流

**文档语言（硬性规则，适用于全部技能与工作流）**：仓库内所有文档（包括 AGENTS.md、GLOSSARY.md、docs/adr/、docs/agents/、docs/qa-log-schema.md、模块 README 以及通过 to-spec / to-tickets / pr 发布的 GitHub Issue、Spec、Ticket 和 PR 描述）必须统一使用中文编写与维护；仅代码标识符、日志 JSON 键名、Git 标签与 CLI 命令保留英文原名。技能产出的 Issue、Spec、Ticket、PR 描述、ADR 与词汇表条目同样适用。

### Issue 跟踪

议题与规格以 GitHub issue 的形式存放在 `linkdesu/posture-reminder`（即 `origin` 远端），通过 `gh` CLI 操作。见 `docs/agents/issue-tracker.md`。Issue 与 Spec 正文一律使用中文。

### 分流标签

五个规范分流角色与各自的标签字符串一一对应（`needs-triage`、`needs-info`、`ready-for-agent`、`ready-for-human`、`wontfix`）。见 `docs/agents/triage-labels.md`。

### 领域文档

单上下文布局：根目录的 `GLOSSARY.md`，ADR 位于 `docs/adr/`。见 `docs/agents/domain.md`。GLOSSARY 与 ADR 一律使用中文维护。
