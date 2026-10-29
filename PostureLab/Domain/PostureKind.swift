import Foundation

/// How far a posture is trusted. Decides whether it may speak and whether it is on by default.
enum PostureTier: String, Equatable {
  case stable        // trusted: on by default, may speak
  case medium        // on by default, may speak, false positives watched closely
  case experimental  // off by default: highlight and log only, never speaks
}

/// The eight postures. `rawValue` is the `alert_type` / `state` value in the log.
enum PostureKind: String, CaseIterable, Equatable {
  case deskLean = "desk_lean"
  case near = "near"
  case headForward = "head_forward"
  case slouch = "slouch"
  case headDown = "head_down"
  case headTilt = "head_tilt"
  case shoulderTilt = "shoulder_tilt"
  case chinRest = "chin_rest"

  var tier: PostureTier {
    switch self {
    case .near, .headDown, .headTilt, .shoulderTilt: return .stable
    case .deskLean, .chinRest: return .medium
    case .headForward, .slouch: return .experimental
    }
  }

  /// Lower wins. Every breaching posture is timed and logged, and this order decides which
  /// queued voice line the player speaks first, one at a time.
  var priority: Int {
    switch self {
    case .deskLean: return 1
    case .near: return 2
    case .headForward: return 3
    case .slouch: return 4
    case .headDown: return 5
    case .headTilt: return 6
    case .shoulderTilt: return 7
    case .chinRest: return 8
    }
  }

  /// 肩部不可用时必须闭嘴的体态。
  ///
  /// 高低肩直接读两肩连线，驼背的一个代理读两肩的归一化宽度；歪头本身只读头部横滚、不读肩线，
  /// 但产品口径（pr-PM，0.6.2）要求肩线不可用时一并闭嘴：拿不到可信的肩线时，上半身几何整体
  /// 不值得提醒，宁可漏报不可误报。这三项既不发声，也不进时间轴与统计。
  var requiresShoulderLine: Bool {
    switch self {
    case .shoulderTilt, .slouch, .headTilt: return true
    default: return false
    }
  }

  var displayName: String {
    switch self {
    case .deskLean: return "趴桌"
    case .near: return "太近"
    case .headForward: return "头前伸"
    case .slouch: return "驼背"
    case .headDown: return "低头"
    case .headTilt: return "歪头"
    case .shoulderTilt: return "高低肩"
    case .chinRest: return "托腮"
    }
  }

  /// The level-2 voice line. An experimental posture returns nil, which is what "never speaks" means.
  var voiceLine: String? {
    switch self {
    case .near: return "离书太近啦，坐直一点哦"
    case .headDown: return "头抬起来一点哦"
    case .headTilt: return "头别歪哦，坐正一点"
    case .shoulderTilt: return "肩膀放松，两边放平哦"
    case .deskLean: return "快坐起来，别趴在桌上哦"
    case .chinRest: return "手放下，坐正一点哦"
    case .headForward, .slouch: return nil
    }
  }

  /// Only the experimental tier starts off.
  var isEnabledByDefault: Bool { tier != .experimental }
}
