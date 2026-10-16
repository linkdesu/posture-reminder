import Foundation

/// Scripted input scenarios, used by QA in place of a real person.
enum Scenario: String, CaseIterable, Equatable {
  case approach
  case headDown
  case left
  case shortApproach
  case occlusion
  case cooldown
  case longRun

  var displayName: String {
    switch self {
    case .approach: return "靠近视距循环"
    case .headDown: return "持续低头"
    case .left: return "离开画面"
    case .shortApproach: return "短暂靠近"
    case .occlusion: return "人脸丢失"
    case .cooldown: return "冷却期内再次靠近"
    case .longRun: return "30 分钟长跑"
    }
  }

  /// Total scenario length in seconds. The coordinator ends the simulated run with it.
  var duration: TimeInterval {
    switch self {
    case .approach: return 36
    case .headDown: return 22
    case .left: return 20
    case .shortApproach: return 16
    case .occlusion: return 20
    case .cooldown: return 45
    case .longRun: return 1800
    }
  }

  /// The sampled value at `t`. Past the end of the scenario the last frame repeats.
  func sample(at t: TimeInterval) -> PostureSample {
    // Snap onto the 10Hz grid so two calls with the same `t` always agree.
    let t = (t * Self.sampleRate).rounded() / Self.sampleRate

    switch self {
    case .approach:
      let distance: Double
      if t < 1 {
        distance = Self.baselineDistanceCM
      } else if t < 6 {
        distance = 40 - 4 * (t - 1)
      } else if t < 26 {
        distance = Self.nearDistanceCM
      } else if t < 31 {
        distance = 20 + 4 * (t - 26)
      } else {
        distance = Self.baselineDistanceCM
      }
      return PostureSample(t: t, distanceCM: distance, pitchDeg: Self.baselinePitchDeg)

    case .headDown:
      return PostureSample(t: t,
                           distanceCM: Self.baselineDistanceCM,
                           pitchDeg: t >= 2 ? Self.headDownPitchDeg : Self.baselinePitchDeg)

    case .left, .occlusion:
      if t >= 2 && t < 12 {
        return PostureSample(t: t, distanceCM: nil, pitchDeg: nil)
      }
      return PostureSample(t: t, distanceCM: Self.baselineDistanceCM, pitchDeg: Self.baselinePitchDeg)

    case .shortApproach:
      let near = t >= 2 && t < 5
      return PostureSample(t: t,
                           distanceCM: near ? Self.nearDistanceCM : Self.baselineDistanceCM,
                           pitchDeg: Self.baselinePitchDeg)

    case .cooldown:
      let distance: Double
      if t < 1 {
        distance = Self.baselineDistanceCM
      } else if t < 6 {
        distance = 40 - 4 * (t - 1)
      } else if t < 24 {
        distance = Self.nearDistanceCM
      } else if t < 29 {
        distance = 20 + 4 * (t - 24)
      } else if t < 30 {
        distance = Self.baselineDistanceCM
      } else if t < 33 {
        distance = 40 - 20 * (t - 30) / 3
      } else {
        distance = Self.nearDistanceCM
      }
      return PostureSample(t: t, distanceCM: distance, pitchDeg: Self.baselinePitchDeg)

    case .longRun:
      let phase = t.truncatingRemainder(dividingBy: Self.longRunCycle)
      let distance = phase < 40 || phase >= 80 ? Self.baselineDistanceCM : Self.nearDistanceCM
      let pitch = phase >= 100 && phase < 110 ? Self.deepHeadDownPitchDeg : Self.baselinePitchDeg
      return PostureSample(t: t, distanceCM: distance, pitchDeg: pitch)
    }
  }

  private static let sampleRate: Double = 10

  private static let baselineDistanceCM: Double = 40
  private static let baselinePitchDeg: Double = 0

  private static let nearDistanceCM: Double = 20
  private static let headDownPitchDeg: Double = -25
  private static let deepHeadDownPitchDeg: Double = -30

  /// Length of one `longRun` cycle; the scenario repeats it on a 1800 second run.
  private static let longRunCycle: TimeInterval = 120
}
