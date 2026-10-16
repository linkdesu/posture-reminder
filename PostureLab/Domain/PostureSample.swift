import Foundation

/// One camera tick. `nil` distance/pitch means the face was not detected.
struct PostureSample: Equatable {
  var t: TimeInterval
  var distanceCM: Double?
  var pitchDeg: Double?

  var facePresent: Bool { distanceCM != nil && pitchDeg != nil }
}

/// The single value the monitoring screen displays.
enum PostureStatus: String, Equatable, CaseIterable {
  case good = "good"
  case tooClose = "too_close"
  case headDown = "head_down"
  case absent = "absent"

  var displayName: String {
    switch self {
    case .good: return "良好"
    case .tooClose: return "太近"
    case .headDown: return "低头"
    case .absent: return "未检测到人"
    }
  }
}

enum ReminderKind: String, Equatable, CaseIterable {
  case tooClose = "too_close"
  case headDown = "head_down"
}

enum ReminderLevel: Int, Equatable {
  case gentle = 1
  case voice = 2
}
