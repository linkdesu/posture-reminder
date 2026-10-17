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
    XCTAssertFalse(afterLaunch.debugEnabled)

    afterLaunch.sensitivity = .low
    let afterUserChange = Settings(defaults: defaults)
    XCTAssertEqual(afterUserChange.sensitivity, .low)
  }
}
