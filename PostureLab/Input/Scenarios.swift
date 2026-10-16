import Foundation

/// Scripted input scenarios, used by QA in place of a real person.
enum Scenario: String, CaseIterable, Equatable {
  case approach
  case shortApproach
  case headDown
  case absence

  var displayName: String {
    switch self {
    case .approach: return "靠近视距循环"
    case .shortApproach: return "短暂靠近"
    case .headDown: return "持续低头"
    case .absence: return "离开画面"
    }
  }

  /// Total scenario length in seconds. The coordinator ends the simulated run with it.
  var duration: TimeInterval {
    switch self {
    case .approach: return 37
    case .shortApproach: return 16
    case .headDown: return 22
    case .absence: return 20
    }
  }

  /// The sampled value at `t`. Past the end of the scenario the last frame repeats.
  func sample(at t: TimeInterval) -> PostureSample {
    // Snap onto the 10Hz grid so two calls with the same `t` always agree.
    let t = (t * Self.sampleRate).rounded() / Self.sampleRate

    switch self {
    case .approach:
      let distance: Double
      if t < 2 {
        distance = Self.baselineDistanceCM
      } else if t < 22 {
        distance = Self.nearDistanceCM
      } else if t < 32 {
        distance = Self.baselineDistanceCM
      } else {
        distance = Self.nearDistanceCM
      }
      return PostureSample(t: t, distanceCM: distance, pitchDeg: Self.baselinePitchDeg)

    case .shortApproach:
      let near = t >= 2 && t < 6
      return PostureSample(t: t,
                           distanceCM: near ? Self.nearDistanceCM : Self.baselineDistanceCM,
                           pitchDeg: Self.baselinePitchDeg)

    case .headDown:
      return PostureSample(t: t,
                           distanceCM: Self.baselineDistanceCM,
                           pitchDeg: t >= 2 ? Self.headDownPitchDeg : Self.baselinePitchDeg)

    case .absence:
      if t >= 2 && t < 12 {
        return PostureSample(t: t, distanceCM: nil, pitchDeg: nil)
      }
      return PostureSample(t: t, distanceCM: Self.baselineDistanceCM, pitchDeg: Self.baselinePitchDeg)
    }
  }

  private static let sampleRate: Double = 10

  /// The coordinator calibrates the session to exactly these two baselines.
  private static let baselineDistanceCM: Double = 40
  private static let baselinePitchDeg: Double = 0

  private static let nearDistanceCM: Double = 20
  private static let headDownPitchDeg: Double = -30
}
