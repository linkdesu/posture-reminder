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

  /// Whether a head was measured. A depth-only source always has a distance when it has a head;
  /// pitch may be unavailable on a frame whose head band is too noisy to fit a plane through, and
  /// that must not turn a sitting child into an absent one.
  var facePresent: Bool { distanceCM != nil }
  /// Whether the body is still in frame. Leaning on the desk has to stay apart from having got up.
  var bodyPresent: Bool { !joints.isEmpty }
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
