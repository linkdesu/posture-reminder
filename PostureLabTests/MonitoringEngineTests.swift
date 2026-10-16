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
  var kind: ReminderKind
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
      if case .statusChanged(let to, _, _, _) = event { return to == .tooClose }
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
    XCTAssertEqual(gentle.kind, .tooClose)
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
    XCTAssertEqual(second.kind, .tooClose)
    XCTAssertEqual(second.level, .gentle)
    XCTAssertEqual(second.t, first.t + 30.0, accuracy: 1.0)
    XCTAssertEqual(engine.summary.tooCloseCount, 2)
    XCTAssertEqual(engine.status, .tooClose)
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
    XCTAssertEqual(medium.engine.status, .headDown)
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
    XCTAssertEqual(belowThreshold.engine.status, .tooClose)
    XCTAssertEqual(belowThreshold.engine.summary.tooCloseSeconds, 6.0, accuracy: 0.05)
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
                                 longestGoodStreakSeconds: 3)
    let events: [MonitoringEvent] = [
      .sessionStarted(scenario: "approach"),
      .config(sensitivity: .medium, distanceThresholdCM: 30, pitchThresholdDeg: 20),
      .calibrated(baselineDistanceCM: 40, baselinePitchDeg: 0),
      .screenShown(name: "monitoring"),
      .sample(t: 1.5, distanceCM: 40, pitchDeg: 0),
      .statusChanged(to: .headDown, t: 1.5, distanceCM: nil, pitchDeg: nil),
      .reminder(kind: .tooClose, level: .gentle, t: 1.5, breachSeconds: 5, distanceCM: 20, pitchDeg: 0),
      .paused(t: 1.5),
      .resumed(t: 1.5),
      .sessionEnded(summary: summary),
    ]
    XCTAssertEqual(events.count, 10)

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
}
