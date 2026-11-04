import Foundation

/// The end-of-phase sound a batch of engine events calls for.
///
/// `GLOSSARY.md` 的「阶段提示音」属于**自然结束**的阶段：专注倒计时归零（`.completed`）与休息倒计时
/// 归零（`.phaseEnded`）都要响。孩子自己结束的专注（`abandoned` / `interrupted`）和被跳过的休息
/// （`breakSkipped`）不响——那不是阶段走完，而是有人把它结束了；`EndSound.none` 是一个真实的静音
/// 选择，什么都不响。规则放在这里而不是写在控制器里，是因为它是产品口径，应该能脱离播放器与计时器
/// 被读、被测试。
enum PhaseEndCue {
  /// One cue per batch: a batch is one instant of the countdown, so at most one phase ended in it.
  static func cues(for events: [PomodoroEvent], endSound: EndSound) -> [PomodoroCue] {
    guard let cue = endSound.cue else { return [] }
    let ended = events.contains { event in
      switch event {
      case .completed, .phaseEnded: return true
      case .phaseChanged, .abandoned, .interrupted, .breakSkipped, .finishedAll: return false
      }
    }
    return ended ? [cue] : []
  }
}

extension EndSound {
  /// The clip behind a choice; `none` is a real choice and has no clip.
  var cue: PomodoroCue? {
    switch self {
    case .soft: return .endSoft
    case .chime: return .endChime
    case EndSound.none: return nil
    }
  }
}
