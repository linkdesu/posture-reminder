import Foundation

/// One camera tick. `nil` distance/pitch means the face was not detected.
struct PostureSample: Equatable {
  var t: TimeInterval
  var distanceCM: Double?
  var pitchDeg: Double?

  // v0.3: all optional / defaulted so the existing call sites keep compiling.
  var rollDeg: Double? = nil
  var joints: [JointID: JointSample] = [:]
  var depth: DepthFrame? = nil
  var depthAvailable: Bool = false
  /// Points sampled straight from the segmented depth frame.
  var cloud: [BodyPoint] = []
  /// Joints the source could not measure on this frame.
  var unavailableJoints: Set<JointID> = []

  /// Vision 这一帧是否看到人（模型报出的 observation 存在，且没有过期）。脚本 rig 没有 Vision，
  /// 保持 nil，由距离回退。0.6.8 (16) 起「在场/暂停」看这个，不看深度：真机日志里出现过 4.9 秒没有
  /// 检测到人却没有暂停事件的情况，那次深度一直有 600 点，按深度判在场就永远不停表。
  var personPresent: Bool? = nil

  /// 是否有人在场。有 Vision 结论时以它为准；没有（脚本源、Vision 尚未跑第一帧）才退回距离。
  var facePresent: Bool { personPresent ?? (distanceCM != nil) }
  /// Whether the body is still in frame. Leaning on the desk has to stay apart from having got up.
  var bodyPresent: Bool { !joints.isEmpty }

  /// 肩线是否可用：两个肩关节都在、且来源没有把它们标成不可用。
  ///
  /// 不可用时 `PostureKind.requiresShoulderLine` 的体态一律不判——既不发声，也不进时间轴与统计。
  var hasShoulderLine: Bool {
    joints[.leftShoulder] != nil
      && joints[.rightShoulder] != nil
      && !unavailableJoints.contains(.leftShoulder)
      && !unavailableJoints.contains(.rightShoulder)
  }
}

/// The single value the monitoring screen displays: doing fine, nobody there, or the posture that
/// currently wins. Not a mirror of `PostureKind` — the vocabulary lives in exactly one place.
enum PostureStatus: Equatable {
  case good
  case noPerson
  case posture(PostureKind)

  /// The `state` value of every log line, read back by QA scripts.
  var rawValue: String {
    switch self {
    case .good: return "good"
    case .noPerson: return "no_person"
    case .posture(let kind): return kind.rawValue
    }
  }

  /// Parses a `state` value back, so tests and QA scripts can round-trip it.
  init?(rawValue: String) {
    switch rawValue {
    case "good": self = .good
    case "no_person": self = .noPerson
    default:
      guard let kind = PostureKind(rawValue: rawValue) else { return nil }
      self = .posture(kind)
    }
  }

  var displayName: String {
    switch self {
    case .good: return "良好"
    case .noPerson: return "不在画面"
    case .posture(let kind): return kind.displayName
    }
  }
}

enum ReminderLevel: Int, Equatable {
  case gentle = 1
  case voice = 2
}
