import Foundation

/// A measurable feature the verdict is built from. The debug overlay shows one row per feature and
/// paints the breached ones red.
enum PostureFeature: String, CaseIterable, Equatable {
  case distance = "distance"                // cm, smaller is worse
  case headPitch = "head_pitch"             // degrees below the baseline
  case headRoll = "head_roll"               // absolute degrees away from the baseline
  case shoulderTilt = "shoulder_tilt"       // absolute degrees the shoulder line is off the baseline line
  case headHeightDrop = "head_height_drop"  // normalized drop below the baseline head height, larger is worse
  case handToFace = "hand_to_face"          // normalized wrist-to-nose distance, smaller is worse
  case headForward = "head_forward"         // metres the head came closer than the baseline, larger is worse
  case slouch = "slouch"                    // slouch proxy ratio, larger is worse

  var displayName: String {
    switch self {
    case .distance: return "距离"
    case .headPitch: return "俯仰"
    case .headRoll: return "歪头"
    case .shoulderTilt: return "肩线"
    case .headHeightDrop: return "头高"
    case .handToFace: return "手到脸"
    case .headForward: return "头前伸"
    case .slouch: return "驼背"
    }
  }

  /// Whether a smaller value is the bad direction for this feature.
  var isSmallerWorse: Bool {
    switch self {
    case .distance, .handToFace: return true
    case .headPitch, .headRoll, .shoulderTilt, .headHeightDrop, .headForward, .slouch: return false
    }
  }
}

/// One feature's reading for one sample. Value, threshold and the baseline it was measured against
/// all travel together, so the overlay and the log can use a reading as-is.
struct FeatureReading: Equatable {
  var feature: PostureFeature
  var value: Double
  var threshold: Double
  var baseline: Double?
  var isOverThreshold: Bool

  /// 0...1, how close the value sits to its threshold; the overlay's red/amber/green.
  var severity: Double
}

extension FeatureReading {
  /// 1 at the threshold, 0 once the value is a whole threshold clear of it on the safe side, clamped
  /// in between except that anything past the threshold stays at 1 (red).
  ///
  /// A feature whose inputs are missing never comes through here: the classifier builds it with
  /// `severity: 0` by hand, so an absent measurement can never look like an alarm.
  static func severity(feature: PostureFeature, value: Double, threshold: Double) -> Double {
    guard threshold > 0 else { return 0 }
    let ratio = value / threshold
    return feature.isSmallerWorse ? min(1, max(0, 2 - ratio)) : min(1, max(0, ratio))
  }
}

/// The result of one verdict.
struct PostureAssessment: Equatable {
  var readings: [FeatureReading]
  var breached: [PostureKind: Bool]
  /// The highest-priority breaching posture; nil when nothing breached.
  var dominant: PostureKind?
  /// The feature to highlight right now (the log's `highlighted_feature`, the red overlay row).
  var highlighted: PostureFeature?
}

/// Per-kind thresholds. All relative to the calibration baseline, per the PRD.
struct PostureThresholds: Equatable {
  var distanceCM: Double
  var pitchDeg: Double
  var rollDeg: Double
  var shoulderTiltDeg: Double
  var headHeightDrop: Double
  var handToFace: Double
  var headForwardM: Double
  var slouchRatio: Double

  static func forSensitivity(_ s: Sensitivity) -> PostureThresholds {
    PostureThresholds(distanceCM: s.distanceThresholdCM,
                      pitchDeg: s.pitchThresholdDeg,
                      rollDeg: 15,
                      shoulderTiltDeg: 10,
                      headHeightDrop: 0.10,
                      handToFace: 0.10,
                      headForwardM: 0.05,
                      slouchRatio: 0.12)
  }
}
