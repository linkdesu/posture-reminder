# ADR-0002：JSONL 日志是与 QA 的契约——snake_case、Unix 纪元毫秒 ts、每行 38 个键

- **日期**：2026-10-17
- **状态**：已接受

> **v0.6 注记（2026-10-29）**：本 ADR 保留原文（标题与正文里的「38 个键」是 v0.5 及以前的历史记录，不作修改）。v0.6 起每行携带 **42 个键**，新增 `segment_kind`、`segment_start`、`segment_end`、`segment_seconds`；事件表新增 `segment`——识别中段关闭时写一行，该行只有这四个键非 `null`，其余行为 `null`。当前契约以 `docs/qa-log-schema.md` 为准。

## 背景

QA 远程验收这个应用：他们读取 JSONL 调试日志与截图证据，不观看屏幕。因此日志不是调试便利，而是与 QA 脚本之间的**契约**——schema 变更破坏脚本的程度，与行为变更相同。

领域有自己的 Swift 词汇（`PostureStatus.noPerson`、`MonitoringEvent.speechPlayed`、`SessionSummary.tooCloseCount` 等），与日志词汇（`no_person`、`speech_played`、`near_count` 等）不同。不能为了统一而重命名代码。

## 决策

日志 schema 固定如下：

- 键名使用 **snake_case**；每一行都携带完整键集（**38 个键**）。`LogRecord` 自定义 `encode(to:)`，在每行写出全部键——缺失值写成 JSON `null`。不得改用 `encodeIfPresent`，否则键集会随行变化并破坏契约。
- `ts` 是 Unix 纪元毫秒，在**每一行**都填写。`t` 是会话开始后的秒数，只有携带会话时间的事件才填写。
- `event` 的取值为各 case 的 snake_case 名称：`session_started`、`config`、`calibration_done`、`screen_shown`、`sample`、`status_changed`、`features`、`view_mode`、`reminder`、`speech_timeout`、`speech_unavailable`、`speech_played`、`pomodoro_tick`、`cue_played`、`paused`、`resumed`、`session_ended`。
- v0.3 增加了 `features`（`highlighted_feature`、`feature_values`）与 `view_mode`（`view_mode`、`overlay_on`、`avatar_on`）。v0.4/v0.5 增加了 `pomodoro_tick`（`remaining_seconds`、`phase`）、`speech_played`、`cue_played`（`message`）、`posture_stats`，以及番茄钟每个专注阶段写出的一对 `session_started`/`session_ended`。
- 体态音频是**预录 WAV 片段包**——每个可发声体态一条语音，另加阶段提示音。应用内没有系统 TTS，因此不存在合成开始或合成超时的歧义：`speech_played` 与 `cue_played` 只在片段真正开始播放时写出；资源缺失时写 `speech_unavailable`（提示音则什么都不写）。
- **领域词汇映射只发生在日志边界**：Swift 标识符保留代码中的名字。完整的 Swift ↔ JSONL 映射表位于 `docs/qa-log-schema.md`，它是日志词汇的唯一事实来源；`GLOSSARY.md` 保持领域语言，不承载实现路径。

## 影响

- QA 可以从任意会话的任意一行读到统一 schema；解析就是每行一个键完整的扁平 JSON 对象。
- Swift 代码库保持自己的命名；`PostureLab/` 中没有标识符被塑造成日志键的样子。
- 任何 schema 变更（新增、重命名或删除键）都是**对 QA 契约的破坏性变更**，落地前必须与 QA 协调。
- 如果 `docs/qa-log-schema.md` 的映射表与代码漂移，即使行为正确，日志也是错的。
