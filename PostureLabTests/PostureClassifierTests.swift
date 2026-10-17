import XCTest
@testable import PostureLab

/// The classifier is pinned at the medium sensitivity: it is the table both the rig's positive and
/// its near-miss poses are built on, and the one QA replays.
private let mediumThresholds = PostureThresholds.forSensitivity(.medium)

/// Distance and pitch come from calibration; the body fields are filled with the upright reference
/// geometry, which is the layout `BodyRig.geometry(.upright, distanceCM:)` reproduces.
private let uprightBaseline = PostureBaseline.from(calibration: CalibrationResult(distanceCM: 40, pitchDeg: 0))

/// A sample built the way the scripted scenarios build one: joints and depth from `BodyRig`, the
/// face values from the scenario's own timeline.
private func rigged(_ pose: BodyPose,
                    distanceCM: Double? = 40,
                    pitchDeg: Double? = 0,
                    rollDeg: Double? = nil) -> PostureSample {
  let geometry = BodyRig.geometry(pose, distanceCM: distanceCM)
  return PostureSample(t: 0,
                       distanceCM: distanceCM,
                       pitchDeg: pitchDeg,
                       rollDeg: rollDeg,
                       joints: geometry.joints,
                       depth: geometry.depth,
                       depthAvailable: geometry.depth != nil)
}

/// A sample with no joint data at all, so every body-derived feature is uncomputable. The face
/// fields stay the caller's choice, which is what separates "face gone, body present" from "nobody
/// in frame".
private func noBody(distanceCM: Double?, pitchDeg: Double?) -> PostureSample {
  PostureSample(t: 0, distanceCM: distanceCM, pitchDeg: pitchDeg)
}

private func assess(_ sample: PostureSample,
                    thresholds: PostureThresholds = mediumThresholds,
                    reference: PostureBaseline = uprightBaseline) -> PostureAssessment {
  PostureClassifier.assess(sample, baseline: reference, thresholds: thresholds)
}

private func reading(_ assessment: PostureAssessment, _ feature: PostureFeature) -> FeatureReading {
  guard let reading = assessment.readings.first(where: { $0.feature == feature }) else {
    preconditionFailure("\(feature) is missing from the assessment")
  }
  return reading
}

final class PostureClassifierTests: XCTestCase {
  /// The whole file compares against this table, so the numbers live in one place.
  func testMediumThresholdTable() {
    XCTAssertEqual(mediumThresholds.distanceCM, 30.0, accuracy: 0.0001)
    XCTAssertEqual(mediumThresholds.pitchDeg, 20.0, accuracy: 0.0001)
    XCTAssertEqual(mediumThresholds.rollDeg, 15.0, accuracy: 0.0001)
    XCTAssertEqual(mediumThresholds.shoulderTiltDeg, 10.0, accuracy: 0.0001)
    XCTAssertEqual(mediumThresholds.headHeightDrop, 0.10, accuracy: 0.0001)
    XCTAssertEqual(mediumThresholds.handToFace, 0.10, accuracy: 0.0001)
    XCTAssertEqual(mediumThresholds.headForwardM, 0.05, accuracy: 0.0001)
    XCTAssertEqual(mediumThresholds.slouchRatio, 0.12, accuracy: 0.0001)
  }

  /// Calibration only carries distance and pitch; the rest is the upright reference geometry.
  func testBaselineCompletesCalibrationWithTheUprightGeometry() throws {
    XCTAssertEqual(uprightBaseline.distanceCM, 40.0, accuracy: 0.0001)
    XCTAssertEqual(uprightBaseline.pitchDeg, 0.0, accuracy: 0.0001)
    XCTAssertEqual(uprightBaseline.rollDeg, 0.0, accuracy: 0.0001)
    XCTAssertEqual(uprightBaseline.shoulderTiltDeg, 0.0, accuracy: 0.0001)
    XCTAssertEqual(uprightBaseline.headHeight, 0.30, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(uprightBaseline.headDepthM), 0.35, accuracy: 0.0001)
    XCTAssertEqual(uprightBaseline.shoulderWidth, 0.20, accuracy: 0.0001)
    XCTAssertEqual(uprightBaseline.neckToRoot, 0.20, accuracy: 0.0001)
  }

  /// A clean upright frame: all eight features reported in `allCases` order, all seven kinds
  /// reported as not breached, nothing to highlight.
  func testUprightFrameBreachesNothing() {
    let assessment = assess(rigged(.upright))

    XCTAssertEqual(assessment.readings.count, 8)
    XCTAssertEqual(assessment.readings.map(\.feature), PostureFeature.allCases)
    XCTAssertEqual(assessment.breached.count, 7)
    for kind in PostureKind.allCases {
      XCTAssertEqual(assessment.breached[kind], false, "\(kind) breached an upright frame")
    }
    XCTAssertNil(assessment.dominant)
    XCTAssertNil(assessment.highlighted)
  }

  // MARK: - One test per rule

  func testNearNeedsTheFaceCloserThanThirtyCentimetres() {
    let breach = assess(rigged(.near, distanceCM: 20))
    XCTAssertEqual(breach.breached[.near], true)
    let near = reading(breach, .distance)
    XCTAssertEqual(near.value, 20.0, accuracy: 0.0001)
    XCTAssertEqual(near.threshold, 30.0, accuracy: 0.0001)
    XCTAssertTrue(near.isOverThreshold)
    XCTAssertEqual(near.severity, 1.0, accuracy: 0.0001)

    let miss = assess(rigged(.nearMissDistance, distanceCM: 37.5))
    XCTAssertEqual(miss.breached[.near], false)
    let far = reading(miss, .distance)
    XCTAssertEqual(far.value, 37.5, accuracy: 0.0001)
    XCTAssertEqual(far.threshold, 30.0, accuracy: 0.0001)
    XCTAssertFalse(far.isOverThreshold)
    XCTAssertEqual(far.severity, 0.75, accuracy: 0.0001)
  }

  func testHeadDownNeedsThePitchThirtyDegreesBelowTheBaseline() {
    let breach = assess(rigged(.headDown, pitchDeg: -30))
    XCTAssertEqual(breach.breached[.headDown], true)
    let pitch = reading(breach, .headPitch)
    XCTAssertEqual(pitch.value, 30.0, accuracy: 0.0001)
    XCTAssertEqual(pitch.threshold, 20.0, accuracy: 0.0001)
    XCTAssertTrue(pitch.isOverThreshold)
    XCTAssertEqual(pitch.severity, 1.0, accuracy: 0.0001)

    let miss = assess(rigged(.nearMissHeadDown, pitchDeg: -16))
    XCTAssertEqual(miss.breached[.headDown], false)
    let smallPitch = reading(miss, .headPitch)
    XCTAssertEqual(smallPitch.value, 16.0, accuracy: 0.0001)
    XCTAssertFalse(smallPitch.isOverThreshold)
    XCTAssertEqual(smallPitch.severity, 0.8, accuracy: 0.0001)
  }

  /// Head tilt has two signals: the head roll the scenario reports, and the shoulder line the rig
  /// rotates. Either one is enough.
  func testHeadTiltBreachesOnHeadRollOrShoulderLine() {
    let roll = assess(rigged(.headTilt, rollDeg: 22.5))
    XCTAssertEqual(roll.breached[.headTilt], true)
    let headRoll = reading(roll, .headRoll)
    XCTAssertEqual(headRoll.value, 22.5, accuracy: 0.0001)
    XCTAssertEqual(headRoll.threshold, 15.0, accuracy: 0.0001)
    XCTAssertTrue(headRoll.isOverThreshold)
    XCTAssertEqual(headRoll.severity, 1.0, accuracy: 0.0001)

    let rollMiss = assess(rigged(.nearMissHeadTilt, rollDeg: 12))
    XCTAssertEqual(rollMiss.breached[.headTilt], false)
    let smallRoll = reading(rollMiss, .headRoll)
    XCTAssertEqual(smallRoll.value, 12.0, accuracy: 0.0001)
    XCTAssertFalse(smallRoll.isOverThreshold)
    XCTAssertEqual(smallRoll.severity, 0.8, accuracy: 0.0001)

    // No roll reported: the rig's dropped shoulder has to carry the rule on its own.
    let shoulders = assess(rigged(.headTilt))
    XCTAssertEqual(shoulders.breached[.headTilt], true)
    XCTAssertTrue(reading(shoulders, .shoulderTilt).isOverThreshold)
    XCTAssertEqual(reading(shoulders, .shoulderTilt).severity, 1.0, accuracy: 0.0001)
    XCTAssertEqual(reading(shoulders, .headRoll).value, 7.5, accuracy: 0.0001)
    XCTAssertFalse(reading(shoulders, .headRoll).isOverThreshold)

    let shoulderMiss = assess(rigged(.nearMissHeadTilt))
    XCTAssertEqual(shoulderMiss.breached[.headTilt], false)
    XCTAssertFalse(reading(shoulderMiss, .shoulderTilt).isOverThreshold)
  }

  /// Desk lean needs a dropped head *and* either a deep pitch or a lost face.
  func testDeskLeanNeedsTheDroppedHeadPlusAPitchOrALostFace() {
    let breach = assess(rigged(.deskLean, distanceCM: 20, pitchDeg: -45))
    XCTAssertEqual(breach.breached[.deskLean], true)
    let drop = reading(breach, .headHeightDrop)
    XCTAssertEqual(drop.value, 0.42, accuracy: 0.03)
    XCTAssertEqual(drop.threshold, 0.10, accuracy: 0.0001)
    XCTAssertTrue(drop.isOverThreshold)
    XCTAssertEqual(drop.severity, 1.0, accuracy: 0.0001)

    // Face gone, body still in frame: the pitch branch is not needed.
    let faceGone = assess(rigged(.deskLean, distanceCM: nil, pitchDeg: nil))
    XCTAssertEqual(faceGone.breached[.deskLean], true)
    XCTAssertEqual(reading(faceGone, .headHeightDrop).value, 0.42, accuracy: 0.03)

    let miss = assess(rigged(.nearMissDeskLean, distanceCM: 20, pitchDeg: -45))
    XCTAssertEqual(miss.breached[.deskLean], false)
    XCTAssertEqual(reading(miss, .headHeightDrop).value, 0.08, accuracy: 0.02)
    XCTAssertFalse(reading(miss, .headHeightDrop).isOverThreshold)
  }

  /// The rule that keeps desk lean apart from walking away: no body, no desk lean, however the
  /// face reads.
  func testDeskLeanNeedsABodyEvenWhenTheFaceIsGone() {
    let assessment = assess(noBody(distanceCM: nil, pitchDeg: nil))

    XCTAssertEqual(assessment.breached[.deskLean], false)
    for kind in PostureKind.allCases {
      XCTAssertEqual(assessment.breached[kind], false, "\(kind) breached an empty frame")
    }
    XCTAssertNil(assessment.dominant)
    XCTAssertNil(assessment.highlighted)
  }

  func testChinRestNeedsAWristWithinTheFaceThreshold() {
    let breach = assess(rigged(.chinRest))
    XCTAssertEqual(breach.breached[.chinRest], true)
    let hand = reading(breach, .handToFace)
    XCTAssertEqual(hand.value, 0.06, accuracy: 0.005)
    XCTAssertEqual(hand.threshold, 0.10, accuracy: 0.0001)
    XCTAssertTrue(hand.isOverThreshold)
    XCTAssertEqual(hand.severity, 1.0, accuracy: 0.0001)

    let miss = assess(rigged(.nearMissChinRest))
    XCTAssertEqual(miss.breached[.chinRest], false)
    let away = reading(miss, .handToFace)
    XCTAssertEqual(away.value, 0.125, accuracy: 0.005)
    XCTAssertFalse(away.isOverThreshold)
    XCTAssertEqual(away.severity, 0.75, accuracy: 0.05)
  }

  /// Head forward is a depth rule: it needs a head depth in the sample and in the baseline.
  func testHeadForwardNeedsBothHeadDepths() {
    let breach = assess(rigged(.headForward))
    XCTAssertEqual(breach.breached[.headForward], true)
    let forward = reading(breach, .headForward)
    XCTAssertEqual(forward.value, 0.06, accuracy: 0.005)
    XCTAssertEqual(forward.threshold, 0.05, accuracy: 0.0001)
    XCTAssertTrue(forward.isOverThreshold)
    XCTAssertEqual(forward.severity, 1.0, accuracy: 0.0001)

    let miss = assess(rigged(.nearMissHeadForward))
    XCTAssertEqual(miss.breached[.headForward], false)
    XCTAssertEqual(reading(miss, .headForward).value, 0.04, accuracy: 0.005)
    XCTAssertFalse(reading(miss, .headForward).isOverThreshold)

    // No joints in the frame: no head depth to compare against the baseline, so no breach.
    let depthless = assess(noBody(distanceCM: 40, pitchDeg: 0))
    XCTAssertEqual(depthless.breached[.headForward], false)
    XCTAssertEqual(reading(depthless, .headForward).value, 0.025, accuracy: 0.0001)
  }

  /// Slouch is a proxy ratio: narrower shoulders or a shorter neck-to-root both count.
  func testSlouchNeedsTheTorsoProxyPastTheRatio() {
    let breach = assess(rigged(.slouch))
    XCTAssertEqual(breach.breached[.slouch], true)
    let slouch = reading(breach, .slouch)
    XCTAssertEqual(slouch.value, 0.15, accuracy: 0.005)
    XCTAssertEqual(slouch.threshold, 0.12, accuracy: 0.0001)
    XCTAssertTrue(slouch.isOverThreshold)
    XCTAssertEqual(slouch.severity, 1.0, accuracy: 0.0001)

    let miss = assess(rigged(.nearMissSlouch))
    XCTAssertEqual(miss.breached[.slouch], false)
    XCTAssertEqual(reading(miss, .slouch).value, 0.096, accuracy: 0.005)
    XCTAssertFalse(reading(miss, .slouch).isOverThreshold)
  }

  /// A feature that cannot be computed is never over threshold, and reports half its threshold so
  /// the overlay still has a bar to draw.
  func testUncomputableFeaturesAreNeverOverThreshold() {
    let assessment = assess(noBody(distanceCM: 40, pitchDeg: 0))

    XCTAssertEqual(assessment.readings.count, 8)
    for reading in assessment.readings {
      XCTAssertFalse(reading.isOverThreshold, "\(reading.feature) breached without its inputs")
    }
    XCTAssertEqual(reading(assessment, .distance).value, 40.0, accuracy: 0.0001)
    XCTAssertEqual(reading(assessment, .headPitch).value, 0.0, accuracy: 0.0001)
    XCTAssertEqual(reading(assessment, .headRoll).value, 7.5, accuracy: 0.0001)
    XCTAssertEqual(reading(assessment, .shoulderTilt).value, 5.0, accuracy: 0.0001)
    XCTAssertEqual(reading(assessment, .headHeightDrop).value, 0.05, accuracy: 0.0001)
    XCTAssertEqual(reading(assessment, .handToFace).value, 0.05, accuracy: 0.0001)
    XCTAssertEqual(reading(assessment, .headForward).value, 0.025, accuracy: 0.0001)
    XCTAssertEqual(reading(assessment, .slouch).value, 0.06, accuracy: 0.0001)
    for feature in [PostureFeature.headRoll, .shoulderTilt, .headHeightDrop, .handToFace, .headForward, .slouch] {
      XCTAssertEqual(reading(assessment, feature).severity, 0.0, accuracy: 0.0001)
    }
    XCTAssertNil(assessment.dominant)
    XCTAssertNil(assessment.highlighted)
    for kind in PostureKind.allCases {
      XCTAssertEqual(assessment.breached[kind], false, "\(kind) breached without its inputs")
    }
  }

  /// Every kind's positive pose breaches at the medium table, so no rule is left without cover.
  func testEveryKindBreachesAtTheMediumTable() {
    let breaching: [(PostureKind, PostureSample)] = [
      (.deskLean, rigged(.deskLean, distanceCM: 20, pitchDeg: -45)),
      (.near, rigged(.near, distanceCM: 20)),
      (.headForward, rigged(.headForward)),
      (.slouch, rigged(.slouch)),
      (.headDown, rigged(.headDown, pitchDeg: -30)),
      (.headTilt, rigged(.headTilt, rollDeg: 22.5)),
      (.chinRest, rigged(.chinRest)),
    ]

    XCTAssertEqual(breaching.count, PostureKind.allCases.count)
    for (kind, sample) in breaching {
      XCTAssertEqual(assess(sample).breached[kind], true, "\(kind) did not breach its own pose")
    }
  }

  func testExperimentalKindsHaveNoVoiceLine() {
    XCTAssertEqual(PostureKind.slouch.tier, .experimental)
    XCTAssertNil(PostureKind.slouch.voiceLine)
    XCTAssertEqual(PostureKind.headForward.tier, .experimental)
    XCTAssertNil(PostureKind.headForward.voiceLine)

    XCTAssertEqual(PostureKind.near.tier, .stable)
    XCTAssertEqual(PostureKind.headDown.tier, .stable)
    XCTAssertEqual(PostureKind.headTilt.tier, .stable)
    XCTAssertEqual(PostureKind.deskLean.tier, .medium)
    XCTAssertEqual(PostureKind.chinRest.tier, .medium)

    XCTAssertEqual(PostureKind.near.voiceLine, "离书太近啦，坐直一点哦")
    XCTAssertEqual(PostureKind.headDown.voiceLine, "头抬起来一点哦")
    XCTAssertEqual(PostureKind.headTilt.voiceLine, "头别歪哦，坐正一点")
    XCTAssertEqual(PostureKind.deskLean.voiceLine, "快坐起来，别趴在桌上哦")
    XCTAssertEqual(PostureKind.chinRest.voiceLine, "手放下，坐正一点哦")
    XCTAssertFalse(PostureKind.slouch.isEnabledByDefault)
    XCTAssertTrue(PostureKind.near.isEnabledByDefault)
  }

  // MARK: - Roll-up

  /// Several kinds breach that frame (desk lean, near, head forward, head down); desk lean wins on
  /// priority, not on the size of its readings.
  func testDominantPicksTheHighestPriorityBreach() {
    let assessment = assess(rigged(.deskLean, distanceCM: 20, pitchDeg: -45))

    XCTAssertEqual(assessment.breached[.deskLean], true)
    XCTAssertEqual(assessment.breached[.near], true)
    XCTAssertEqual(assessment.breached[.headDown], true)
    XCTAssertEqual(assessment.dominant, .deskLean)
    XCTAssertEqual(reading(assessment, .distance).severity, 1.0, accuracy: 0.0001)
    XCTAssertEqual(reading(assessment, .headPitch).value, 45.0, accuracy: 0.0001)
  }

  /// Same again with near and head down only: near is the one that speaks. The dropped head of the
  /// head-down pose is not enough for desk lean, which also wants a deep pitch or a lost face.
  func testDominantPrefersNearOverHeadDown() {
    let assessment = assess(rigged(.headDown, distanceCM: 20, pitchDeg: -30))

    XCTAssertEqual(assessment.breached[.deskLean], false)
    XCTAssertEqual(assessment.breached[.near], true)
    XCTAssertEqual(assessment.breached[.headDown], true)
    XCTAssertEqual(assessment.dominant, .near)
    XCTAssertEqual(assessment.highlighted, .distance)
    XCTAssertEqual(reading(assessment, .distance).severity, 1.0, accuracy: 0.0001)
  }

  /// The highlight follows the dominant kind: an uncomputable candidate can never win, and a
  /// breaching kind that is not dominant never contributes a highlight.
  func testHighlightedIsTheMostSevereFeatureOfTheDominantKind() {
    let shoulders = assess(rigged(.headTilt))
    XCTAssertEqual(shoulders.dominant, .headTilt)
    XCTAssertEqual(shoulders.highlighted, .shoulderTilt)

    let roll = assess(rigged(.upright, rollDeg: 22.5))
    XCTAssertEqual(roll.dominant, .headTilt)
    XCTAssertEqual(roll.highlighted, .headRoll)
    XCTAssertEqual(reading(roll, .shoulderTilt).severity, 0.0, accuracy: 0.0001)
  }
}
