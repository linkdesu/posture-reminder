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

  // v0.3: one positive and one "just short of the threshold" counter-example for each new posture.
  case headTilt
  case headTiltMiss
  case deskLean
  case deskLeanMiss
  case chinRest
  case chinRestMiss
  case headForward
  case headForwardMiss
  case slouch
  case slouchMiss

  var displayName: String {
    switch self {
    case .approach: return "靠近视距循环"
    case .headDown: return "持续低头"
    case .left: return "离开画面"
    case .shortApproach: return "短暂靠近"
    case .occlusion: return "人脸丢失"
    case .cooldown: return "冷却期内再次靠近"
    case .longRun: return "30 分钟长跑"
    case .headTilt: return "持续歪头"
    case .headTiltMiss: return "歪头差一点"
    case .deskLean: return "趴在桌上"
    case .deskLeanMiss: return "趴桌差一点"
    case .chinRest: return "持续托腮"
    case .chinRestMiss: return "托腮差一点"
    case .headForward: return "持续头前伸"
    case .headForwardMiss: return "头前伸差一点"
    case .slouch: return "持续驼背"
    case .slouchMiss: return "驼背差一点"
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
    case .headTilt, .headTiltMiss: return 26
    case .deskLean, .deskLeanMiss: return 26
    case .chinRest, .chinRestMiss: return 30
    case .headForward, .headForwardMiss: return 26
    case .slouch, .slouchMiss: return 26
    }
  }

  /// The sampled value at `t`: the scripted face reading plus the fake body `BodyRig` poses for it,
  /// so every sample carries joints and depth as well. Past the end of the scenario the last frame
  /// repeats.
  func sample(at t: TimeInterval) -> PostureSample {
    // Snap onto the 10Hz grid so two calls with the same `t` always agree.
    let t = (t * Self.sampleRate).rounded() / Self.sampleRate

    let script = script(at: t)
    let geometry = BodyRig.geometry(script.pose, distanceCM: script.distanceCM)
    return PostureSample(t: t,
                         distanceCM: script.distanceCM,
                         pitchDeg: script.pitchDeg,
                         rollDeg: script.rollDeg,
                         joints: geometry.joints,
                         depth: geometry.depth,
                         depthAvailable: geometry.depth != nil)
  }

  /// What the script says at `t`: the pose the rig strikes, and the face reading laid on top of the
  /// rig's geometry.
  private struct Script {
    var pose: BodyPose
    var distanceCM: Double?
    var pitchDeg: Double?
    var rollDeg: Double?
  }

  private func script(at t: TimeInterval) -> Script {
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
      return Script(pose: distance < Self.baselineDistanceCM ? .near : .upright,
                    distanceCM: distance,
                    pitchDeg: Self.baselinePitchDeg,
                    rollDeg: 0)

    case .headDown:
      let down = t >= 2
      return Script(pose: down ? .headDown : .upright,
                    distanceCM: Self.baselineDistanceCM,
                    pitchDeg: down ? Self.headDownPitchDeg : Self.baselinePitchDeg,
                    rollDeg: 0)

    case .left, .occlusion:
      // Both lose the face for the same ten seconds, and a lost face means no body either: the
      // reading clock pauses and the state has to read `no_person` while it does.
      if t >= 2 && t < 12 {
        return Script(pose: .absent, distanceCM: nil, pitchDeg: nil, rollDeg: nil)
      }
      return Script(pose: .upright,
                    distanceCM: Self.baselineDistanceCM,
                    pitchDeg: Self.baselinePitchDeg,
                    rollDeg: 0)

    case .shortApproach:
      let near = t >= 2 && t < 5
      return Script(pose: near ? .near : .upright,
                    distanceCM: near ? Self.nearDistanceCM : Self.baselineDistanceCM,
                    pitchDeg: Self.baselinePitchDeg,
                    rollDeg: 0)

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
      return Script(pose: distance < Self.baselineDistanceCM ? .near : .upright,
                    distanceCM: distance,
                    pitchDeg: Self.baselinePitchDeg,
                    rollDeg: 0)

    case .longRun:
      let phase = t.truncatingRemainder(dividingBy: Self.longRunCycle)
      let distance = phase < 40 || phase >= 80 ? Self.baselineDistanceCM : Self.nearDistanceCM
      let pitch = phase >= 100 && phase < 110 ? Self.deepHeadDownPitchDeg : Self.baselinePitchDeg
      // The pose follows the script; the deep head down wins over leaning in.
      let pose: BodyPose = pitch < 0 ? .headDown
        : (distance < Self.baselineDistanceCM ? .near : .upright)
      return Script(pose: pose, distanceCM: distance, pitchDeg: pitch, rollDeg: 0)

    case .headTilt:
      let tilted = t >= 2
      return Script(pose: tilted ? .headTilt : .upright,
                    distanceCM: Self.baselineDistanceCM,
                    pitchDeg: Self.baselinePitchDeg,
                    rollDeg: tilted ? Self.headTiltRollDeg : 0)

    case .headTiltMiss:
      let tilted = t >= 2
      return Script(pose: tilted ? .nearMissHeadTilt : .upright,
                    distanceCM: Self.baselineDistanceCM,
                    pitchDeg: Self.baselinePitchDeg,
                    rollDeg: tilted ? Self.nearMissHeadTiltRollDeg : 0)

    case .deskLean:
      // Face down on the desk, still in frame at 18 cm; the deep pitch is what carries the desk-lean
      // rule's second half while the face is present.
      let leaning = t >= 2
      return Script(pose: leaning ? .deskLean : .upright,
                    distanceCM: leaning ? Self.deskLeanDistanceCM : Self.baselineDistanceCM,
                    pitchDeg: leaning ? Self.deskLeanPitchDeg : Self.baselinePitchDeg,
                    rollDeg: 0)

    case .deskLeanMiss:
      let leaning = t >= 2
      return Script(pose: leaning ? .nearMissDeskLean : .upright,
                    distanceCM: leaning ? Self.nearMissDistanceCM : Self.baselineDistanceCM,
                    pitchDeg: leaning ? Self.nearMissDeskLeanPitchDeg : Self.baselinePitchDeg,
                    rollDeg: 0)

    case .chinRest:
      return Script(pose: t >= 2 ? .chinRest : .upright,
                    distanceCM: Self.baselineDistanceCM,
                    pitchDeg: Self.baselinePitchDeg,
                    rollDeg: 0)

    case .chinRestMiss:
      return Script(pose: t >= 2 ? .nearMissChinRest : .upright,
                    distanceCM: Self.baselineDistanceCM,
                    pitchDeg: Self.baselinePitchDeg,
                    rollDeg: 0)

    case .headForward:
      return Script(pose: t >= 2 ? .headForward : .upright,
                    distanceCM: Self.baselineDistanceCM,
                    pitchDeg: Self.baselinePitchDeg,
                    rollDeg: 0)

    case .headForwardMiss:
      return Script(pose: t >= 2 ? .nearMissHeadForward : .upright,
                    distanceCM: Self.baselineDistanceCM,
                    pitchDeg: Self.baselinePitchDeg,
                    rollDeg: 0)

    case .slouch:
      return Script(pose: t >= 2 ? .slouch : .upright,
                    distanceCM: Self.baselineDistanceCM,
                    pitchDeg: Self.baselinePitchDeg,
                    rollDeg: 0)

    case .slouchMiss:
      return Script(pose: t >= 2 ? .nearMissSlouch : .upright,
                    distanceCM: Self.baselineDistanceCM,
                    pitchDeg: Self.baselinePitchDeg,
                    rollDeg: 0)
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

  /// The tilt the scenario reports. `BodyRig` rotates the head and drops a shoulder by the same
  /// angles, so the reported roll and the posed skeleton agree. 22.5° and 15° are 1.5x the medium
  /// roll and shoulder thresholds, 12° and 8° are 0.8x of them.
  private static let headTiltRollDeg: Double = 22.5
  private static let nearMissHeadTiltRollDeg: Double = 12

  /// Desk lean needs the body in frame *and* either a pitch more than twice the medium threshold
  /// below the baseline or a lost face. This scenario keeps the face — 18 cm from the screen — so the
  /// pitch carries that half of the rule: −45° is well past the 2 x 20° it asks for.
  private static let deskLeanDistanceCM: Double = 18
  private static let deskLeanPitchDeg: Double = -45

  /// The counter-example stops short of *every* medium threshold, not just its own posture's:
  /// 37.5 cm is 30 / 0.8, outside the distance threshold, and −16° is 0.8x the 20° pitch threshold.
  /// These anchors are pinned against the medium thresholds and are outside them at low and high
  /// too, because `PostureThresholds.forSensitivity` moves only distance and pitch (contract §16.2).
  private static let nearMissDistanceCM: Double = 37.5
  private static let nearMissDeskLeanPitchDeg: Double = -16
}
