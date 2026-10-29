import XCTest
@testable import PostureLab

private let tick: TimeInterval = 0.1

/// One constant stretch of a recorded stream. `nil` distance/pitch means the face was absent.
private struct Segment {
  let duration: TimeInterval
  let distanceCM: Double?
  let pitchDeg: Double?
}

/// Samples every `tick` seconds. A segment boundary carries the next segment's value, and the
/// final tick is emitted as well so the stream covers exactly `sum(duration)` seconds of clock.
private func sampleStream(_ segments: [Segment], from start: TimeInterval = 0) -> [PostureSample] {
  var samples: [PostureSample] = []
  var index = 0
  for (position, segment) in segments.enumerated() {
    let ticks = Int((segment.duration / tick).rounded())
    let isLast = position == segments.count - 1
    for _ in 0..<(ticks + (isLast ? 1 : 0)) {
      samples.append(PostureSample(t: start + Double(index) * tick,
                                   distanceCM: segment.distanceCM,
                                   pitchDeg: segment.pitchDeg))
      index += 1
    }
  }
  return samples
}

private struct FiredReminder: Equatable {
  var kind: PostureKind
  var level: ReminderLevel
  var t: TimeInterval
  var breachSeconds: Double
}

private func reminders(in events: [MonitoringEvent]) -> [FiredReminder] {
  events.compactMap { (event: MonitoringEvent) -> FiredReminder? in
    guard case .reminder(let kind, let level, let t, let breachSeconds, _, _) = event else {
      return nil
    }
    return FiredReminder(kind: kind, level: level, t: t, breachSeconds: breachSeconds)
  }
}

/// The same 10 Hz stream with one pose's joints and depth on every sample. This is the data QA's
/// scripted replays hand the engine, so the engine rules are pinned against the rig itself.
private func posing(_ segments: [Segment],
                    as pose: BodyPose,
                    from start: TimeInterval = 0) -> [PostureSample] {
  sampleStream(segments, from: start).map { sample in
    let geometry = BodyRig.geometry(pose, distanceCM: sample.distanceCM)
    return PostureSample(t: sample.t,
                         distanceCM: sample.distanceCM,
                         pitchDeg: sample.pitchDeg,
                         joints: geometry.joints,
                         depth: geometry.depth,
                         depthAvailable: geometry.depth != nil)
  }
}

/// The last feature line the engine wrote; QA reads it to attribute a reminder to a feature.
private func lastFeatureLine(in events: [MonitoringEvent])
  -> (readings: [FeatureReading], highlighted: PostureFeature?)? {
  var last: (readings: [FeatureReading], highlighted: PostureFeature?)?
  for event in events {
    if case .features(_, let readings, let highlighted) = event {
      last = (readings, highlighted)
    }
  }
  return last
}

private func reading(_ readings: [FeatureReading], _ feature: PostureFeature) throws -> FeatureReading {
  try XCTUnwrap(readings.first { $0.feature == feature })
}

final class MonitoringEngineTests: XCTestCase {
  private func run(_ segments: [Segment],
                   sensitivity: Sensitivity = .medium,
                   baselineDistanceCM: Double = 40,
                   baselinePitchDeg: Double = 0) -> (engine: MonitoringEngine, events: [MonitoringEvent]) {
    var engine = MonitoringEngine(config: .forSensitivity(sensitivity),
                                  baselineDistanceCM: baselineDistanceCM,
                                  baselinePitchDeg: baselinePitchDeg)
    var events: [MonitoringEvent] = []
    for sample in sampleStream(segments) {
      events += engine.ingest(sample)
    }
    return (engine, events)
  }

  func testShortApproachFiresNothing() {
    let result = run([Segment(duration: 2, distanceCM: 40, pitchDeg: 0),
                      Segment(duration: 4, distanceCM: 20, pitchDeg: 0),
                      Segment(duration: 2, distanceCM: 40, pitchDeg: 0)])

    XCTAssertEqual(reminders(in: result.events).count, 0)
    XCTAssertEqual(result.engine.summary.tooCloseSeconds, 4.0, accuracy: 0.05)
    XCTAssertEqual(result.engine.status, .good)
    let tooCloseShown = result.events.contains { (event: MonitoringEvent) in
      if case .statusChanged(let to, _, _, _) = event { return to == .posture(.near) }
      return false
    }
    XCTAssertTrue(tooCloseShown)
  }

  func testTwoLevelTiming() throws {
    let breachStart: TimeInterval = 2
    let result = run([Segment(duration: breachStart, distanceCM: 40, pitchDeg: 0),
                      Segment(duration: 20, distanceCM: 20, pitchDeg: 0)])
    let fired = reminders(in: result.events)

    XCTAssertEqual(fired.count, 2)
    let gentle = try XCTUnwrap(fired.first)
    let voice = try XCTUnwrap(fired.last)
    XCTAssertEqual(gentle.kind, .near)
    XCTAssertEqual(gentle.level, .gentle)
    XCTAssertEqual(voice.level, .voice)
    XCTAssertLessThan(gentle.t, voice.t)
    XCTAssertEqual(gentle.t, breachStart + 5.0, accuracy: 1.0)
    XCTAssertEqual(voice.t, breachStart + 15.0, accuracy: 1.0)
    XCTAssertEqual(gentle.breachSeconds, 5.0, accuracy: 1.0)
    XCTAssertEqual(voice.breachSeconds, 15.0, accuracy: 1.0)
    XCTAssertEqual(result.engine.summary.tooCloseCount, 1)
  }

  func testRecoveryRestoresGoodAndCooldownSuppresses() throws {
    var (engine, events) = run([Segment(duration: 2, distanceCM: 40, pitchDeg: 0),
                                Segment(duration: 10, distanceCM: 20, pitchDeg: 0),
                                Segment(duration: 0.1, distanceCM: 40, pitchDeg: 0)])

    XCTAssertEqual(engine.status, .good)
    let first = try XCTUnwrap(reminders(in: events).first)
    XCTAssertEqual(first.level, .gentle)
    XCTAssertEqual(first.t, 7.0, accuracy: 1.0)
    XCTAssertEqual(engine.summary.tooCloseCount, 1)

    for sample in sampleStream([Segment(duration: 26, distanceCM: 20, pitchDeg: 0)], from: 12.1) {
      events += engine.ingest(sample)
    }

    let fired = reminders(in: events)
    XCTAssertEqual(fired.count, 2)
    XCTAssertEqual(fired.filter { $0.t > 12.0 && $0.t < 36.9 }.count, 0)
    let second = try XCTUnwrap(fired.last)
    XCTAssertEqual(second.kind, .near)
    XCTAssertEqual(second.level, .gentle)
    XCTAssertEqual(second.t, first.t + 30.0, accuracy: 1.0)
    XCTAssertEqual(engine.summary.tooCloseCount, 2)
    XCTAssertEqual(engine.status, .posture(.near))
  }

  func testHeadDownRespectsSensitivity() throws {
    let headDown = [Segment(duration: 2, distanceCM: 40, pitchDeg: 0),
                    Segment(duration: 6, distanceCM: 40, pitchDeg: -25)]

    let medium = run(headDown)
    let fired = reminders(in: medium.events)
    XCTAssertEqual(fired.count, 1)
    let reminder = try XCTUnwrap(fired.first)
    XCTAssertEqual(reminder.kind, .headDown)
    XCTAssertEqual(reminder.level, .gentle)
    XCTAssertEqual(reminder.t, 7.0, accuracy: 1.0)
    XCTAssertEqual(reminder.breachSeconds, 5.0, accuracy: 1.0)
    XCTAssertEqual(medium.engine.status, .posture(.headDown))
    XCTAssertEqual(medium.engine.summary.headDownSeconds, 6.0, accuracy: 0.05)
    XCTAssertEqual(medium.engine.summary.tooCloseCount, 0)

    let low = run(headDown, sensitivity: .low)
    XCTAssertEqual(reminders(in: low.events).count, 0)
    XCTAssertEqual(low.engine.status, .good)
    XCTAssertEqual(low.engine.summary.headDownSeconds, 0.0, accuracy: 0.001)
    XCTAssertEqual(low.engine.summary.goodSeconds, 8.0, accuracy: 0.05)
  }

  func testAbsencePausesClockWithoutViolation() throws {
    let withAbsence = run([Segment(duration: 2, distanceCM: 40, pitchDeg: 0),
                           Segment(duration: 10, distanceCM: nil, pitchDeg: nil),
                           Segment(duration: 2, distanceCM: 40, pitchDeg: 0)])
    let withoutAbsence = run([Segment(duration: 4, distanceCM: 40, pitchDeg: 0)])

    let paused = withAbsence.events.compactMap { (event: MonitoringEvent) -> TimeInterval? in
      guard case .paused(let t) = event else { return nil }
      return t
    }
    let resumed = withAbsence.events.compactMap { (event: MonitoringEvent) -> TimeInterval? in
      guard case .resumed(let t) = event else { return nil }
      return t
    }

    XCTAssertEqual(paused.count, 1)
    XCTAssertEqual(try XCTUnwrap(paused.first), 5.0, accuracy: 0.2)
    XCTAssertEqual(resumed.count, 1)
    XCTAssertEqual(try XCTUnwrap(resumed.first), 12.0, accuracy: 0.2)
    XCTAssertEqual(reminders(in: withAbsence.events).count, 0)
    XCTAssertFalse(withAbsence.engine.isPaused)
    XCTAssertEqual(withAbsence.engine.summary.totalSeconds, 4.0, accuracy: 0.05)
    XCTAssertEqual(withAbsence.engine.summary.totalSeconds,
                   withoutAbsence.engine.summary.totalSeconds, accuracy: 0.05)
    XCTAssertEqual(withoutAbsence.engine.summary.totalSeconds, 4.0, accuracy: 0.05)
  }

  func testSummaryMatchesEventLog() {
    let config = MonitoringEngine.Config.forSensitivity(.medium)
    let result = run([Segment(duration: 2, distanceCM: 40, pitchDeg: 0),
                      Segment(duration: 1, distanceCM: nil, pitchDeg: nil),
                      Segment(duration: 2, distanceCM: 40, pitchDeg: 0),
                      Segment(duration: 3, distanceCM: 20, pitchDeg: 0),
                      Segment(duration: 2, distanceCM: 40, pitchDeg: -30),
                      Segment(duration: 2, distanceCM: 40, pitchDeg: 0)])

    var total = 0.0
    var good = 0.0
    var tooClose = 0.0
    var headDown = 0.0
    var streak = 0.0
    var longestStreak = 0.0
    var previous: PostureSample?

    for event in result.events {
      guard case .sample(let t, let distanceCM, let pitchDeg) = event else { continue }
      defer { previous = PostureSample(t: t, distanceCM: distanceCM, pitchDeg: pitchDeg) }
      guard let last = previous, let lastDistance = last.distanceCM,
            let lastPitch = last.pitchDeg else { continue }

      let dt = t - last.t
      total += dt
      let isTooClose = lastDistance < config.distanceThresholdCM
      let isHeadDown = (0 - lastPitch) > config.pitchThresholdDeg
      if isTooClose { tooClose += dt }
      if isHeadDown { headDown += dt }
      if isTooClose || isHeadDown {
        streak = 0
      } else {
        good += dt
        streak += dt
        longestStreak = max(longestStreak, streak)
      }
    }

    XCTAssertEqual(result.engine.summary.totalSeconds, 11.0, accuracy: 0.05)
    XCTAssertEqual(result.engine.summary.goodSeconds, 6.0, accuracy: 0.05)
    XCTAssertEqual(result.engine.summary.tooCloseSeconds, 3.0, accuracy: 0.05)
    XCTAssertEqual(result.engine.summary.headDownSeconds, 2.0, accuracy: 0.05)
    XCTAssertEqual(result.engine.summary.longestGoodStreakSeconds, 4.0, accuracy: 0.05)

    XCTAssertEqual(total, 11.0, accuracy: 0.05)
    XCTAssertEqual(good, 6.0, accuracy: 0.05)
    XCTAssertEqual(tooClose, 3.0, accuracy: 0.05)
    XCTAssertEqual(headDown, 2.0, accuracy: 0.05)
    XCTAssertEqual(longestStreak, 4.0, accuracy: 0.05)

    XCTAssertEqual(result.engine.summary.totalSeconds, total, accuracy: 0.0001)
    XCTAssertEqual(result.engine.summary.goodSeconds, good, accuracy: 0.0001)
    XCTAssertEqual(result.engine.summary.tooCloseSeconds, tooClose, accuracy: 0.0001)
    XCTAssertEqual(result.engine.summary.headDownSeconds, headDown, accuracy: 0.0001)
    XCTAssertEqual(result.engine.summary.longestGoodStreakSeconds, longestStreak, accuracy: 0.0001)
  }

  func testSensitivityThresholdTable() {
    XCTAssertEqual(Sensitivity.low.distanceThresholdCM, 25.0, accuracy: 0.001)
    XCTAssertEqual(Sensitivity.medium.distanceThresholdCM, 30.0, accuracy: 0.001)
    XCTAssertEqual(Sensitivity.high.distanceThresholdCM, 35.0, accuracy: 0.001)
    XCTAssertEqual(Sensitivity.low.pitchThresholdDeg, 25.0, accuracy: 0.001)
    XCTAssertEqual(Sensitivity.medium.pitchThresholdDeg, 20.0, accuracy: 0.001)
    XCTAssertEqual(Sensitivity.high.pitchThresholdDeg, 15.0, accuracy: 0.001)

    XCTAssertEqual(MonitoringEngine.Config.forSensitivity(.low).distanceThresholdCM, 25.0, accuracy: 0.001)
    XCTAssertEqual(MonitoringEngine.Config.forSensitivity(.medium).distanceThresholdCM, 30.0, accuracy: 0.001)
    XCTAssertEqual(MonitoringEngine.Config.forSensitivity(.high).distanceThresholdCM, 35.0, accuracy: 0.001)
    XCTAssertEqual(MonitoringEngine.Config.forSensitivity(.low).pitchThresholdDeg, 25.0, accuracy: 0.001)
    XCTAssertEqual(MonitoringEngine.Config.forSensitivity(.medium).pitchThresholdDeg, 20.0, accuracy: 0.001)
    XCTAssertEqual(MonitoringEngine.Config.forSensitivity(.high).pitchThresholdDeg, 15.0, accuracy: 0.001)
    XCTAssertEqual(MonitoringEngine.Config.forSensitivity(.high).gentleDelay, 5.0, accuracy: 0.001)
    XCTAssertEqual(MonitoringEngine.Config.forSensitivity(.high).voiceDelay, 15.0, accuracy: 0.001)
    XCTAssertEqual(MonitoringEngine.Config.forSensitivity(.high).cooldown, 30.0, accuracy: 0.001)
    XCTAssertEqual(MonitoringEngine.Config.forSensitivity(.high).absencePauseDelay, 3.0, accuracy: 0.001)
  }

  func testDistanceAtThresholdIsNotAViolation() {
    let threshold = Sensitivity.medium.distanceThresholdCM

    let atThreshold = run([Segment(duration: 2, distanceCM: 40, pitchDeg: 0),
                           Segment(duration: 6, distanceCM: threshold, pitchDeg: 0)])
    XCTAssertEqual(atThreshold.engine.status, .good)
    XCTAssertEqual(reminders(in: atThreshold.events).count, 0)
    XCTAssertEqual(atThreshold.engine.summary.tooCloseSeconds, 0.0, accuracy: 0.001)
    XCTAssertEqual(atThreshold.engine.summary.goodSeconds, 8.0, accuracy: 0.05)
    XCTAssertEqual(atThreshold.engine.summary.tooCloseCount, 0)
    let statusChanges = atThreshold.events.filter { (event: MonitoringEvent) in
      if case .statusChanged = event { return true }
      return false
    }
    XCTAssertEqual(statusChanges.count, 0)

    let belowThreshold = run([Segment(duration: 2, distanceCM: 40, pitchDeg: 0),
                              Segment(duration: 6, distanceCM: threshold - 0.1, pitchDeg: 0)])
    XCTAssertEqual(belowThreshold.engine.status, .posture(.near))
    XCTAssertEqual(belowThreshold.engine.summary.tooCloseSeconds, 6.0, accuracy: 0.05)
  }

  /// The breach clock starts at the first crossing sample and a single normal sample resets it, so
  /// two separate 4 s breaches never add up to the 5 s gentle delay.
  func testSingleGoodSampleResetsTheBreachTimer() throws {
    var (engine, events) = run([Segment(duration: 1, distanceCM: 40, pitchDeg: 0),
                                Segment(duration: 4, distanceCM: 20, pitchDeg: 0),
                                Segment(duration: 0.1, distanceCM: 40, pitchDeg: 0),
                                Segment(duration: 4, distanceCM: 20, pitchDeg: 0)])

    XCTAssertEqual(reminders(in: events).count, 0)
    XCTAssertEqual(engine.status, .posture(.near))
    XCTAssertEqual(engine.summary.tooCloseSeconds, 8.0, accuracy: 0.05)
    XCTAssertEqual(engine.summary.tooCloseCount, 0)

    // The second stretch restarts at 5.1 s, so the gentle reminder lands 5 s later.
    for sample in sampleStream([Segment(duration: 6, distanceCM: 20, pitchDeg: 0)], from: 9.2) {
      events += engine.ingest(sample)
    }

    let fired = reminders(in: events)
    XCTAssertEqual(fired.count, 1)
    let reminder = try XCTUnwrap(fired.first)
    XCTAssertEqual(reminder.kind, .near)
    XCTAssertEqual(reminder.level, .gentle)
    XCTAssertEqual(reminder.t, 10.1, accuracy: 0.15)
    XCTAssertEqual(reminder.breachSeconds, 5.0, accuracy: 0.15)
    XCTAssertEqual(engine.summary.tooCloseCount, 1)
  }

  /// Too-close and head-down stay independent episodes with their own clocks, and both speak: the
  /// engine emits one reminder per breaching speakeable kind, ordered by `PostureKind.priority`
  /// ascending within a tick. Playing them one at a time is the player's job, not the engine's.
  func testBothKindsFireAndLogOnTheSameSample() throws {
    var engine = MonitoringEngine(config: .forSensitivity(.medium),
                                  baselineDistanceCM: 40,
                                  baselinePitchDeg: 0)
    var events: [MonitoringEvent] = []
    var batchesWithTwoReminders = 0

    for sample in sampleStream([Segment(duration: 1, distanceCM: 40, pitchDeg: 0),
                                Segment(duration: 20, distanceCM: 20, pitchDeg: -25)]) {
      let batch = engine.ingest(sample)
      events += batch
      if reminders(in: batch).count > 1 {
        batchesWithTwoReminders += 1
      }
    }

    // Both kinds breach from the same sample, so the gentle tick and the voice tick each carry two
    // reminders rather than one.
    XCTAssertEqual(batchesWithTwoReminders, 2)

    let fired = reminders(in: events)
    XCTAssertEqual(fired.map(\.kind), [.near, .headDown, .near, .headDown])
    XCTAssertEqual(fired.map(\.level), [.gentle, .gentle, .voice, .voice])
    // Within a tick the reminders are ordered near (2) before head-down (5); each kind keeps its own
    // timing, 5 s of breach for the gentle line and 15 s for the voice line.
    XCTAssertEqual(fired[0].t, 6.0, accuracy: 0.15)
    XCTAssertEqual(fired[1].t, 6.0, accuracy: 0.15)
    XCTAssertEqual(fired[2].t, 16.0, accuracy: 0.15)
    XCTAssertEqual(fired[3].t, 16.0, accuracy: 0.15)

    XCTAssertEqual(engine.summary.tooCloseSeconds, 20.0, accuracy: 0.05)
    XCTAssertEqual(engine.summary.headDownSeconds, 20.0, accuracy: 0.05)
    XCTAssertEqual(engine.summary.tooCloseCount, 1)
    XCTAssertEqual(engine.summary.tooCloseRemindCount, 2)
    XCTAssertEqual(engine.summary.headDownCount, 1)
    XCTAssertEqual(engine.summary.headDownRemindCount, 2)
    XCTAssertEqual(engine.episodeCount(for: .near), 1)
    XCTAssertEqual(engine.reminderCount(for: .near), 2)
    XCTAssertEqual(engine.episodeCount(for: .headDown), 1)
    XCTAssertEqual(engine.reminderCount(for: .headDown), 2)
    XCTAssertEqual(engine.status, .posture(.near))
  }

  /// Three kinds breach one leaning pose: desk-lean, near and head-down each keep their own episode
  /// and each emit their own reminder, ordered by `PostureKind.priority` within a tick — desk-lean
  /// (1), near (2), head-down (5). The experimental head-forward kind also breaches here but stays
  /// silent.
  func testEveryBreachingKindOnOneSampleFiresInPriorityOrder() throws {
    var engine = MonitoringEngine(config: .forSensitivity(.medium),
                                  baselineDistanceCM: 40,
                                  baselinePitchDeg: 0)
    var events: [MonitoringEvent] = []

    let upright = sampleStream([Segment(duration: 1, distanceCM: 40, pitchDeg: 0)])
    let leaning = posing([Segment(duration: 20, distanceCM: 20, pitchDeg: -45)],
                         as: .deskLean,
                         from: 1.0)
    for sample in upright + leaning {
      events += engine.ingest(sample)
    }

    let fired = reminders(in: events)
    XCTAssertEqual(fired.map(\.kind),
                   [.deskLean, .near, .headDown, .deskLean, .near, .headDown])
    XCTAssertEqual(fired.map(\.level),
                   [.gentle, .gentle, .gentle, .voice, .voice, .voice])
    // Each kind keeps its own timing: gentle at 5 s of breach, voice at 15 s.
    for (index, _) in [PostureKind.deskLean, .near, .headDown].enumerated() {
      XCTAssertEqual(fired[index].t, 6.0, accuracy: 0.15)
      XCTAssertEqual(fired[index + 3].t, 16.0, accuracy: 0.15)
    }

    XCTAssertEqual(engine.episodeCount(for: .deskLean), 1)
    XCTAssertEqual(engine.reminderCount(for: .deskLean), 2)
    XCTAssertEqual(engine.episodeCount(for: .near), 1)
    XCTAssertEqual(engine.reminderCount(for: .near), 2)
    XCTAssertEqual(engine.episodeCount(for: .headDown), 1)
    XCTAssertEqual(engine.reminderCount(for: .headDown), 2)
    // Head-forward breaches the same pose but is experimental, so it never leaves a reminder.
    XCTAssertEqual(engine.episodeCount(for: .headForward), 1)
    XCTAssertEqual(engine.reminderCount(for: .headForward), 0)

    XCTAssertEqual(engine.summary.tooCloseRemindCount, 2)
    XCTAssertEqual(engine.summary.headDownRemindCount, 2)
    XCTAssertEqual(engine.summary.tooCloseSeconds, 20.0, accuracy: 0.05)
    XCTAssertEqual(engine.status, .posture(.deskLean))
    XCTAssertEqual(engine.status.rawValue, "desk_lean")
  }

  /// Shoulder tilt is its own posture: a dropped shoulder under a square head runs one shoulder-tilt
  /// episode, speaks at levels 1 and 2, and never touches the head-tilt episode (AC11).
  func testShoulderTiltPoseRunsAHeadTiltFreeEpisode() throws {
    var engine = MonitoringEngine(config: .forSensitivity(.medium),
                                  baselineDistanceCM: 40,
                                  baselinePitchDeg: 0)
    var events: [MonitoringEvent] = []

    let upright = sampleStream([Segment(duration: 1, distanceCM: 40, pitchDeg: 0)])
    let tilted = posing([Segment(duration: 20, distanceCM: 40, pitchDeg: 0)],
                        as: .shoulderTilt,
                        from: 1.0)
    for sample in upright + tilted {
      events += engine.ingest(sample)
    }

    XCTAssertEqual(reminders(in: events).map(\.kind), [.shoulderTilt, .shoulderTilt])
    XCTAssertEqual(reminders(in: events).map(\.level), [.gentle, .voice])
    XCTAssertEqual(engine.episodeCount(for: .shoulderTilt), 1)
    XCTAssertEqual(engine.reminderCount(for: .shoulderTilt), 2)
    XCTAssertEqual(engine.episodeCount(for: .headTilt), 0)
    XCTAssertEqual(engine.reminderCount(for: .headTilt), 0)
    XCTAssertEqual(engine.status, .posture(.shoulderTilt))
    XCTAssertEqual(engine.status.rawValue, "shoulder_tilt")

    let line = try XCTUnwrap(lastFeatureLine(in: events))
    XCTAssertEqual(line.highlighted, .shoulderTilt)
    XCTAssertTrue(try reading(line.readings, .shoulderTilt).isOverThreshold)
    XCTAssertFalse(try reading(line.readings, .headRoll).isOverThreshold)
  }

  /// An experimental kind still runs its episode, still moves the status and still writes feature
  /// lines; only the reminder is dropped, because its `voiceLine` is nil.
  func testExperimentalKindLogsWithoutAReminder() throws {
    var engine = MonitoringEngine(config: .forSensitivity(.medium),
                                  baselineDistanceCM: 40,
                                  baselinePitchDeg: 0)
    var events: [MonitoringEvent] = []

    // 20 s of slouch is four times the gentle delay, so a stable kind would have spoken twice.
    let upright = sampleStream([Segment(duration: 1, distanceCM: 40, pitchDeg: 0)])
    let slouching = posing([Segment(duration: 20, distanceCM: 40, pitchDeg: 0)],
                           as: .slouch,
                           from: 1.0)
    for sample in upright + slouching {
      events += engine.ingest(sample)
    }

    XCTAssertEqual(reminders(in: events).count, 0)
    XCTAssertEqual(engine.episodeCount(for: .slouch), 1)
    XCTAssertEqual(engine.reminderCount(for: .slouch), 0)
    XCTAssertEqual(engine.status, .posture(.slouch))
    XCTAssertEqual(engine.status.rawValue, "slouch")
    XCTAssertTrue(events.contains { (event: MonitoringEvent) in
      if case .statusChanged(let to, _, _, _) = event { return to == .posture(.slouch) }
      return false
    })

    let line = try XCTUnwrap(lastFeatureLine(in: events))
    XCTAssertEqual(line.highlighted, .slouch)
    XCTAssertEqual(try reading(line.readings, .slouch).value, 0.15, accuracy: 0.005)
    XCTAssertTrue(try reading(line.readings, .slouch).isOverThreshold)
  }

  /// Good reading time is earned when the face is present and nothing breaches at all, not when the
  /// two v2 kinds happen to be quiet. A session the app interrupted because of a newer posture must
  /// not read back as a perfect run.
  func testGoodSecondsCountsEveryPostureNotOnlyTheTwoV2Kinds() throws {
    func runSamples(_ samples: [PostureSample]) -> (engine: MonitoringEngine, events: [MonitoringEvent]) {
      var engine = MonitoringEngine(config: .forSensitivity(.medium),
                                    baselineDistanceCM: 40,
                                    baselinePitchDeg: 0)
      var events: [MonitoringEvent] = []
      for sample in samples {
        events += engine.ingest(sample)
      }
      return (engine, events)
    }

    // The chin rest holds for the whole 30 s run, so every tick breaches `chin_rest` and the session
    // speaks twice. The v2 kinds stay quiet throughout, which is what made the old rule call all
    // 30 s good.
    let (held, heldEvents) = runSamples(posing([Segment(duration: 30, distanceCM: 40, pitchDeg: 0)],
                                               as: .chinRest))
    XCTAssertEqual(reminders(in: heldEvents).map(\.kind), [.chinRest, .chinRest])
    XCTAssertEqual(held.status, .posture(.chinRest))
    XCTAssertEqual(held.summary.totalSeconds, 30.0, accuracy: 0.05)
    XCTAssertNotEqual(held.summary.goodSeconds, held.summary.totalSeconds)
    XCTAssertEqual(held.summary.goodSeconds, 0.0, accuracy: 0.05)

    // The shipped `chinRest` scenario opens upright for 2 s, so exactly those 2 s of its 30 s are good.
    let (scenario, _) = runSamples(
      posing([Segment(duration: 2, distanceCM: 40, pitchDeg: 0)], as: .upright)
        + posing([Segment(duration: 28, distanceCM: 40, pitchDeg: 0)], as: .chinRest, from: 2.0)
    )
    XCTAssertEqual(scenario.summary.totalSeconds, 30.0, accuracy: 0.05)
    XCTAssertEqual(scenario.summary.goodSeconds, 2.0, accuracy: 0.05)
    XCTAssertLessThan(scenario.summary.goodSeconds, scenario.summary.totalSeconds)

    // The mirror: the same length sitting upright is a clean run, so all of it is good.
    let (upright, uprightEvents) = runSamples(posing([Segment(duration: 30, distanceCM: 40, pitchDeg: 0)],
                                                     as: .upright))
    XCTAssertEqual(reminders(in: uprightEvents).count, 0)
    XCTAssertEqual(upright.status, .good)
    XCTAssertEqual(upright.summary.totalSeconds, 30.0, accuracy: 0.05)
    XCTAssertEqual(upright.summary.goodSeconds, 30.0, accuracy: 0.05)
    XCTAssertEqual(upright.summary.goodSeconds, upright.summary.totalSeconds, accuracy: 0.05)
  }

  /// `pausedSeconds` accumulates the intervals whose start sample had no face, which is what the
  /// coordinator compares against 300 s to end an idle session.
  func testPausedSecondsAccumulatesAbsence() throws {
    let result = run([Segment(duration: 2, distanceCM: 40, pitchDeg: 0),
                      Segment(duration: 10, distanceCM: nil, pitchDeg: nil),
                      Segment(duration: 2, distanceCM: 40, pitchDeg: 0)])

    XCTAssertEqual(result.engine.summary.pausedSeconds, 10.0, accuracy: 0.2)
    XCTAssertEqual(result.engine.summary.totalSeconds, 4.0, accuracy: 0.2)
    XCTAssertEqual(result.engine.summary.goodSeconds, 4.0, accuracy: 0.2)
    XCTAssertEqual(result.engine.summary.tooCloseSeconds, 0.0, accuracy: 0.001)
    XCTAssertEqual(result.engine.summary.headDownSeconds, 0.0, accuracy: 0.001)
    XCTAssertEqual(result.engine.summary.tooCloseCount, 0)
  }

  /// Feeds one posed stretch into a running engine. The pause tests switch pose and face presence
  /// mid-stream and inspect the engine while it is paused, so they cannot use `run`.
  private func feed(_ samples: [PostureSample],
                    into engine: inout MonitoringEngine) -> [MonitoringEvent] {
    var events: [MonitoringEvent] = []
    for sample in samples { events += engine.ingest(sample) }
    return events
  }

  /// A pause is a hard gate, not a gap in wall-clock time. A chin rest reads the wrist-to-nose
  /// distance off the body, so it keeps breaching with the face gone — the face-lost-but-body-present
  /// case. Before the fix it escalated to level 2 while the child was away and fired at 17.0 s,
  /// inside the pause.
  func testPauseEmitsNoRemindersAndFreezesTheEpisode() throws {
    var engine = MonitoringEngine(config: .forSensitivity(.medium),
                                  baselineDistanceCM: 40,
                                  baselinePitchDeg: 0)
    var events: [MonitoringEvent] = []

    events += feed(posing([Segment(duration: 2, distanceCM: 40, pitchDeg: 0)], as: .upright),
                   into: &engine)
    events += feed(posing([Segment(duration: 4, distanceCM: 40, pitchDeg: 0)],
                          as: .chinRest,
                          from: 2),
                   into: &engine)
    // The face goes at 6.0 s and the pause starts at 9.0 s; the body keeps the chin rest breaching.
    events += feed(posing([Segment(duration: 60, distanceCM: nil, pitchDeg: nil)],
                          as: .chinRest,
                          from: 6),
                   into: &engine)

    XCTAssertTrue(engine.isPaused)
    XCTAssertEqual(engine.status, .noPerson)
    // The face is gone for the 60 ticks from 6.0 s to the resume at 66.0 s, so the face-less
    // stretch is exactly 60.0 s of absence; one tick is the finest this stream can resolve.
    XCTAssertEqual(engine.summary.pausedSeconds, 60.0, accuracy: tick)
    XCTAssertEqual(engine.summary.totalSeconds, 6.0, accuracy: 0.05)
    XCTAssertEqual(engine.summary.goodSeconds, 2.0, accuracy: 0.05)

    let pausedAt = try XCTUnwrap(events.compactMap { event -> TimeInterval? in
      guard case .paused(let t) = event else { return nil }
      return t
    }.first)
    XCTAssertEqual(pausedAt, 9.0, accuracy: 0.05)

    // Level 1 landed at 7.0 s, before the pause; the level-2 wall falls inside it.
    XCTAssertEqual(reminders(in: events).count, 1)
    XCTAssertEqual(engine.episodeCount(for: .chinRest), 1)
    XCTAssertEqual(engine.reminderCount(for: .chinRest), 1)

    events += feed(posing([Segment(duration: 2, distanceCM: 40, pitchDeg: 0)],
                          as: .chinRest,
                          from: 66),
                   into: &engine)

    XCTAssertFalse(engine.isPaused)
    XCTAssertEqual(engine.status, .posture(.chinRest))
    XCTAssertEqual(engine.summary.pausedSeconds, 60.0, accuracy: 0.05)

    let fired = reminders(in: events)
    XCTAssertEqual(fired.count, 1)
    let gentle = try XCTUnwrap(fired.first)
    XCTAssertEqual(gentle.kind, .chinRest)
    XCTAssertEqual(gentle.level, .gentle)
    XCTAssertEqual(gentle.t, 7.0, accuracy: 0.05)
    XCTAssertEqual(gentle.breachSeconds, 5.0, accuracy: 0.05)
    XCTAssertTrue(fired.allSatisfy { $0.t < 9.0 })
    XCTAssertEqual(engine.reminderCount(for: .chinRest), 1)
  }

  /// Wall-clock arithmetic back-filled every wall a pause crossed: on resume `sample.t - breachStart`
  /// jumped by the pause length and the waiting reminder fired on the first sample. The accumulator
  /// only moves while the child is watched, so a wall crossed during a pause is still crossed at the
  /// same rate afterwards, never on the resume sample itself.
  func testPauseDoesNotBackfillTheFiveAndFifteenSecondWalls() throws {
    // The 5 s wall: 4.9 s of breach when the pause starts. The wall is crossed while the child is
    // away, but the first sample after the resume still reads 4.9 s, so level 1 lands one tick
    // later rather than at once.
    var fiveSecondEngine = MonitoringEngine(config: .forSensitivity(.medium),
                                            baselineDistanceCM: 40,
                                            baselinePitchDeg: 0)
    var fiveSecondEvents: [MonitoringEvent] = []
    fiveSecondEvents += feed(posing([Segment(duration: 2, distanceCM: 40, pitchDeg: 0)],
                                    as: .upright),
                             into: &fiveSecondEngine)
    fiveSecondEvents += feed(posing([Segment(duration: 2, distanceCM: 40, pitchDeg: 0)],
                                    as: .chinRest,
                                    from: 2),
                             into: &fiveSecondEngine)
    fiveSecondEvents += feed(posing([Segment(duration: 60, distanceCM: nil, pitchDeg: nil)],
                                    as: .chinRest,
                                    from: 4),
                             into: &fiveSecondEngine)
    fiveSecondEvents += feed(posing([Segment(duration: 2, distanceCM: 40, pitchDeg: 0)],
                                    as: .chinRest,
                                    from: 64),
                             into: &fiveSecondEngine)

    let fiveSecondFired = reminders(in: fiveSecondEvents)
    XCTAssertEqual(fiveSecondFired.count, 1)
    let fiveSecondGentle = try XCTUnwrap(fiveSecondFired.first)
    XCTAssertEqual(fiveSecondGentle.kind, .chinRest)
    XCTAssertEqual(fiveSecondGentle.level, .gentle)
    XCTAssertEqual(fiveSecondGentle.t, 64.1, accuracy: 0.15)
    // The accumulator only ever moves one tick at a time, so level 1 reads the 5 s wall plus the
    // tick that carries it over. A clock that back-filled the 57 s pause would report 62.0 s here
    // — the value in the tens this bound rejects — so the bound, not a literal, is what proves the
    // paused interval never reached the accumulator.
    XCTAssertGreaterThanOrEqual(fiveSecondGentle.breachSeconds, 5.0)
    XCTAssertLessThan(fiveSecondGentle.breachSeconds, 6.0)
    XCTAssertGreaterThan(fiveSecondGentle.t, 64.0)

    // The 15 s wall: level 1 fired at 7.0 s and the pause crosses the level-2 wall. The accumulated
    // breach is 6.9 s at the pause, so level 2 needs 8.1 s more and does not arrive inside this 2 s
    // resume. The wall-clock version fired it on the first resumed sample.
    var fifteenSecondEngine = MonitoringEngine(config: .forSensitivity(.medium),
                                               baselineDistanceCM: 40,
                                               baselinePitchDeg: 0)
    var fifteenSecondEvents: [MonitoringEvent] = []
    fifteenSecondEvents += feed(posing([Segment(duration: 2, distanceCM: 40, pitchDeg: 0)],
                                       as: .upright),
                                into: &fifteenSecondEngine)
    fifteenSecondEvents += feed(posing([Segment(duration: 4, distanceCM: 40, pitchDeg: 0)],
                                       as: .chinRest,
                                       from: 2),
                                into: &fifteenSecondEngine)
    fifteenSecondEvents += feed(posing([Segment(duration: 60, distanceCM: nil, pitchDeg: nil)],
                                       as: .chinRest,
                                       from: 6),
                                into: &fifteenSecondEngine)
    fifteenSecondEvents += feed(posing([Segment(duration: 2, distanceCM: 40, pitchDeg: 0)],
                                       as: .chinRest,
                                       from: 66),
                                into: &fifteenSecondEngine)

    let fifteenSecondFired = reminders(in: fifteenSecondEvents)
    XCTAssertEqual(fifteenSecondFired.map(\.level), [.gentle])
    XCTAssertEqual(fifteenSecondFired.first?.t ?? -1, 7.0, accuracy: 0.05)
    XCTAssertEqual(fifteenSecondEngine.reminderCount(for: .chinRest), 1)
  }

  /// Entering a pause stops the clock instead of resetting it: 4 s of breach, 60 s away, then one
  /// more second of breach reaches level 1 — not the resume sample. `absencePauseDelay` is 0 so the
  /// pause starts on the first face-less sample, keeping the frozen value exactly 4 s instead of
  /// mixing in the shipped 3 s onset.
  func testResumedBreachNeedsOneMoreSecondForLevelOne() throws {
    var immediatePause = MonitoringEngine.Config.forSensitivity(.medium)
    immediatePause.absencePauseDelay = 0
    var engine = MonitoringEngine(config: immediatePause,
                                  baselineDistanceCM: 40,
                                  baselinePitchDeg: 0)
    var events: [MonitoringEvent] = []

    events += feed(posing([Segment(duration: 1, distanceCM: 40, pitchDeg: 0)], as: .upright),
                   into: &engine)
    events += feed(posing([Segment(duration: 4.1, distanceCM: 40, pitchDeg: 0)],
                          as: .chinRest,
                          from: 1),
                   into: &engine)
    // 4.0 s on the breach clock when the face leaves at 5.1 s.
    events += feed(posing([Segment(duration: 60, distanceCM: nil, pitchDeg: nil)],
                          as: .chinRest,
                          from: 5.1),
                   into: &engine)

    XCTAssertTrue(engine.isPaused)
    XCTAssertEqual(reminders(in: events).count, 0)
    XCTAssertEqual(engine.episodeCount(for: .chinRest), 0)

    events += feed(posing([Segment(duration: 2, distanceCM: 40, pitchDeg: 0)],
                          as: .chinRest,
                          from: 65.1),
                   into: &engine)

    let fired = reminders(in: events)
    XCTAssertEqual(fired.count, 1)
    let gentle = try XCTUnwrap(fired.first)
    XCTAssertEqual(gentle.kind, .chinRest)
    XCTAssertEqual(gentle.level, .gentle)
    XCTAssertEqual(gentle.t, 66.1, accuracy: 0.15)
    XCTAssertEqual(gentle.breachSeconds, 5.0, accuracy: 0.06)
    XCTAssertGreaterThan(gentle.t, 65.1)
    XCTAssertEqual(engine.episodeCount(for: .chinRest), 1)
    XCTAssertEqual(engine.reminderCount(for: .chinRest), 1)
  }

  /// AC21: a resume onto a still-breaching sample reports the posture, never `good`, and the pause
  /// itself reports `no_person` even though the body is still in frame.
  func testPausedStatusIsNoPersonAndAResumedBreachIsNeverGood() throws {
    var immediatePause = MonitoringEngine.Config.forSensitivity(.medium)
    immediatePause.absencePauseDelay = 0
    var engine = MonitoringEngine(config: immediatePause,
                                  baselineDistanceCM: 40,
                                  baselinePitchDeg: 0)
    var events: [MonitoringEvent] = []

    events += feed(posing([Segment(duration: 1, distanceCM: 40, pitchDeg: 0)], as: .upright),
                   into: &engine)
    events += feed(posing([Segment(duration: 4.1, distanceCM: 40, pitchDeg: 0)],
                          as: .chinRest,
                          from: 1),
                   into: &engine)
    XCTAssertEqual(engine.status, .posture(.chinRest))

    events += feed(posing([Segment(duration: 60, distanceCM: nil, pitchDeg: nil)],
                          as: .chinRest,
                          from: 5.1),
                   into: &engine)
    XCTAssertTrue(engine.isPaused)
    XCTAssertEqual(engine.status, .noPerson)

    events += feed(posing([Segment(duration: 2, distanceCM: 40, pitchDeg: 0)],
                          as: .chinRest,
                          from: 65.1),
                   into: &engine)

    XCTAssertFalse(engine.isPaused)
    XCTAssertEqual(engine.status, .posture(.chinRest))
    XCTAssertNotEqual(engine.status, .good)
    XCTAssertTrue(events.contains { event in
      guard case .statusChanged(let to, let t, _, _) = event else { return false }
      return to == .posture(.chinRest) && abs(t - 65.1) < 0.05
    })
  }

  /// The episode counters count episodes (level 1 reached) while the remind counters count lines,
  /// so an episode that escalates to voice contributes 1 to the former and 2 to the latter.
  func testReminderCountsTrackEpisodesAndLines() {
    let result = run([Segment(duration: 2, distanceCM: 40, pitchDeg: 0),
                      Segment(duration: 6, distanceCM: 40, pitchDeg: -25),
                      Segment(duration: 17, distanceCM: 20, pitchDeg: 0)])

    let fired = reminders(in: result.events)
    XCTAssertEqual(fired.filter { $0.kind == .near }.count, 2)
    XCTAssertEqual(fired.filter { $0.kind == .headDown }.count, 1)

    XCTAssertEqual(result.engine.summary.tooCloseCount, 1)
    XCTAssertEqual(result.engine.summary.tooCloseRemindCount, 2)
    XCTAssertEqual(result.engine.summary.headDownCount, 1)
    XCTAssertEqual(result.engine.summary.headDownRemindCount, 1)
  }

  /// QA precondition P1: the same key set on every line, so a null value is fine and a missing key
  /// is not.
  func testLogRecordAlwaysCarriesRequiredKeys() throws {
    let summary = SessionSummary(startedAt: Date(),
                                 totalSeconds: 10,
                                 goodSeconds: 5,
                                 tooCloseSeconds: 2,
                                 headDownSeconds: 2,
                                 pausedSeconds: 1,
                                 tooCloseCount: 1,
                                 tooCloseRemindCount: 2,
                                 headDownCount: 1,
                                 headDownRemindCount: 1,
                                 longestGoodStreakSeconds: 3)
    let events: [MonitoringEvent] = [
      .sessionStarted(scenario: "approach"),
      .config(sensitivity: .medium, distanceThresholdCM: 30, pitchThresholdDeg: 20),
      .calibrated(baselineDistanceCM: 40, baselinePitchDeg: 0),
      .screenShown(name: "monitoring"),
      .sample(t: 1.5, distanceCM: 40, pitchDeg: 0),
      .statusChanged(to: .posture(.headDown), t: 1.5, distanceCM: nil, pitchDeg: nil),
      .reminder(kind: .near, level: .gentle, t: 1.5, breachSeconds: 5, distanceCM: 20, pitchDeg: 0),
      .speechTimeout(kind: .near, level: .voice),
      .speechUnavailable(kind: .headDown),
      .paused(t: 1.5),
      .resumed(t: 1.5),
      .sessionEnded(summary: summary),
    ]
    XCTAssertEqual(events.count, 12)

    let requiredKeys = ["ts", "event", "state", "screen", "distance_cm", "pitch_deg"]
    let now = Date()
    for event in events {
      let data = try JSONEncoder().encode(event.logRecord(now: now))
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      for key in requiredKeys {
        XCTAssertTrue(object.keys.contains(key), "\(event) dropped the \(key) key")
      }
    }
  }

  /// A `-sensitivity`/`-debug` launch argument is a per-run override, so applying it must not
  /// become the user's saved setting on the next launch, while real user changes still persist.
  func testLaunchOverridesDoNotPersist() throws {
    let suiteName = "PostureLabTests.launchOverrides"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)

    let launchSettings = Settings(defaults: defaults)
    launchSettings.suppressPersistence = true
    launchSettings.sensitivity = .high
    launchSettings.debugEnabled = true
    launchSettings.suppressPersistence = false

    let afterLaunch = Settings(defaults: defaults)
    XCTAssertEqual(afterLaunch.sensitivity, .medium)
    // Nothing was written for either switch, so a fresh store reports the build's own defaults: the
    // overlay is on in a debug build and off in a release build, and never the staged `true`.
    XCTAssertNil(defaults.object(forKey: "settings.debugEnabled"),
                 "the launch override was persisted as the user's setting")
    #if DEBUG
    XCTAssertTrue(afterLaunch.debugEnabled)
    #else
    XCTAssertFalse(afterLaunch.debugEnabled)
    #endif

    afterLaunch.sensitivity = .low
    let afterUserChange = Settings(defaults: defaults)
    XCTAssertEqual(afterUserChange.sensitivity, .low)
  }

  /// AC7's corpus-side invariant: the `pomodoroDay` script, played at the source's 10 Hz rate from
  /// its own zero, is fifteen seconds of good sitting, thirty of the cycle's posture, then fifteen
  /// more of good. A scripted run anchors the script clock on the focus it records (see
  /// `SessionController.rebaseSimulatedClock`), so this is the timeline the parent sees per focus.
  func testPomodoroDayScriptReplaysAsFifteenThirtyFifteen() {
    var engine = MonitoringEngine(config: .forSensitivity(.medium),
                                  baselineDistanceCM: 40,
                                  baselinePitchDeg: 0)
    var runs: [(kind: PostureStatus, start: TimeInterval, end: TimeInterval)] = []
    var current: (kind: PostureStatus, start: TimeInterval) = (.good, 0)
    for index in 0...600 {
      let t = Double(index) / 10
      for event in engine.ingest(Scenario.pomodoroDay.sample(at: t)) {
        guard case .statusChanged(let status, let at, _, _) = event else { continue }
        runs.append((current.kind, current.start, at))
        current = (status, at)
      }
    }
    runs.append((current.kind, current.start, 60))

    XCTAssertEqual(runs.map(\.kind), [.good, .posture(.near), .good])
    XCTAssertEqual(runs[0].end - runs[0].start, 15, accuracy: 0.2)
    XCTAssertEqual(runs[1].end - runs[1].start, 30, accuracy: 0.2)
    XCTAssertEqual(runs[2].end - runs[2].start, 15, accuracy: 0.2)
  }
}
