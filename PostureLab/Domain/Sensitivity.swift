import Foundation

enum Sensitivity: String, CaseIterable, Equatable {
  case low
  case medium
  case high

  var distanceThresholdCM: Double {
    switch self {
    case .low: return 25
    case .medium: return 30
    case .high: return 35
    }
  }

  var pitchThresholdDeg: Double {
    switch self {
    case .low: return 25
    case .medium: return 20
    case .high: return 15
    }
  }

  var displayName: String {
    switch self {
    case .low: return "低"
    case .medium: return "中"
    case .high: return "高"
    }
  }
}
