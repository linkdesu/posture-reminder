import Foundation

/// 屏幕常亮的取证时刻：专注开始、暂停、继续、专注结束、切到后台、回到前台。
///
/// v0.6.6 新增 `resume`（手动「继续」或无人自动暂停后人回来自动恢复）与 `foreground`（scene 重新
/// 变为 active）。所有时刻都在状态真正生效、常亮值已写到应用之后才记。
///
/// v0.6.5：QA 用 lldb 读不到 `UIApplication.isIdleTimerDisabled`（r15），于是 DEBUG 构建在这四个时刻
/// 把**实际写到应用上的值**记一行到 `Documents/debug/idle-*.jsonl`。这是独立文件、独立键名，和
/// `docs/qa-log-schema.md` 的 42 键契约无关。纯函数，测试与控制器共用同一套判定。
enum IdleTimerLogTrigger: String, Equatable {
  case focusStart = "focus_start"
  case pause = "pause"
  case resume = "resume"
  case focusEnd = "focus_end"
  case background = "background"
  case foreground = "foreground"

  /// 判定所需的那一小块会话状态。
  struct State: Equatable {
    /// 一个专注已点「开始」且尚未关闭。
    var focusOpen: Bool
    /// 打开的专注被暂停（手动暂停或无人自动暂停）。
    var paused: Bool
    /// 场景在前台。
    var sceneActive: Bool

    /// 应用刚启动、什么都还没发生时的样子。
    static let launch = State(focusOpen: false, paused: false, sceneActive: true)
  }

  /// 从 `old` 变到 `new` 时该记哪几行，按发生顺序。状态没变就不记。
  static func triggers(from old: State?, to new: State) -> [IdleTimerLogTrigger] {
    let old = old ?? .launch
    var result: [IdleTimerLogTrigger] = []
    if !old.focusOpen && new.focusOpen { result.append(.focusStart) }
    if new.focusOpen && new.paused && !(old.focusOpen && old.paused) { result.append(.pause) }
    if old.focusOpen && old.paused && new.focusOpen && !new.paused { result.append(.resume) }
    if old.focusOpen && !new.focusOpen { result.append(.focusEnd) }
    if old.sceneActive && !new.sceneActive { result.append(.background) }
    if !old.sceneActive && new.sceneActive { result.append(.foreground) }
    return result
  }

  /// 一行 JSONL；`t` 是墙钟毫秒，`idle_timer_disabled` 是应用上实际的值。
  static func line(trigger: IdleTimerLogTrigger, idleTimerDisabled: Bool, epochSeconds: TimeInterval) -> String {
    let ms = Int((epochSeconds * 1000).rounded())
    return "{\"t\":\(ms),\"trigger\":\"\(trigger.rawValue)\",\"idle_timer_disabled\":\(idleTimerDisabled)}"
  }
}
