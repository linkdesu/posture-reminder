import Foundation
import XCTest
@testable import PostureLab

/// The engine's only clock: runs of samples at the 10 Hz camera tick. Every `t` is an exact decimal
/// tenth, so the expected remaining values are exact literals too.
private func samples(_ count: Int, from start: TimeInterval = 0) -> [PostureSample] {
  guard count > 0 else { return [] }
  return (1...count).map { index in
    PostureSample(t: start + Double(index) / 10, distanceCM: 40, pitchDeg: 15)
  }
}

/// The same tick with no face in frame: what the camera reports for a child who has left the chair.
private func absentSamples(_ count: Int, from start: TimeInterval = 0) -> [PostureSample] {
  guard count > 0 else { return [] }
  return (1...count).map { index in
    PostureSample(t: start + Double(index) / 10, distanceCM: nil, pitchDeg: nil)
  }
}

/// The engine's clock, driven by the test: every sample sets it to that sample's `t`, so the runs
/// below read exactly as they did when the sample stream was the only clock.
private final class TestClock {
  var now: TimeInterval = 0
}

final class PomodoroEngineTests: XCTestCase {
  /// Epoch zero, so a record's epoch seconds are the same numbers as the sample clock and every
  /// expectation below can be a literal.
  private let clock = TestClock()

  private func makeEngine(_ settings: PomodoroSettings = PomodoroSettings()) -> PomodoroEngine {
    clock.now = 0
    return PomodoroEngine(settings: settings, now: { [clock] in clock.now })
  }

  /// Feeds a run of samples, moving the engine's wall clock to each sample's `t` first, which is
  /// what a camera tick does.
  @discardableResult
  private func feed(_ engine: inout PomodoroEngine, _ stream: [PostureSample]) -> [PomodoroEvent] {
    stream.flatMap { sample in
      clock.now = sample.t
      return engine.ingest(sample)
    }
  }

  // MARK: - Settings

  func testSettingsDefaultsMatchTheNorthStarTable() {
    let settings = PomodoroSettings()
    XCTAssertEqual(settings.focusMinutes, 25)
    XCTAssertEqual(settings.shortBreakMinutes, 5)
    XCTAssertEqual(settings.longBreakMinutes, 15)
    XCTAssertEqual(settings.focusPerLongBreak, 4)
    XCTAssertEqual(settings.autoStartBreak, true)
    XCTAssertEqual(settings.autoStartFocus, false)
    XCTAssertEqual(settings.dailyGoal, 4)
    XCTAssertEqual(settings.endSound, .soft)
    XCTAssertEqual(settings.postureVoiceEnabled, true)
    XCTAssertEqual(settings.postureVoiceVolume, 0.8)
    XCTAssertEqual(settings.monitorDuringBreak, false)
  }

  func testRangesDescribeEveryIntegerSetting() {
    XCTAssertEqual(PomodoroSettings.ranges.count, 5)
    XCTAssertEqual(PomodoroSettings.ranges["focusMinutes"], 5...60)
    XCTAssertEqual(PomodoroSettings.ranges["shortBreakMinutes"], 1...15)
    XCTAssertEqual(PomodoroSettings.ranges["longBreakMinutes"], 5...30)
    XCTAssertEqual(PomodoroSettings.ranges["focusPerLongBreak"], 2...8)
    XCTAssertEqual(PomodoroSettings.ranges["dailyGoal"], 1...12)
  }

  func testClampedPullsEverySettingBackIntoRange() {
    var settings = PomodoroSettings()
    XCTAssertEqual(settings.clamped(), settings)

    settings.focusMinutes = 63
    settings.shortBreakMinutes = 0
    settings.longBreakMinutes = 45
    settings.focusPerLongBreak = 1
    settings.dailyGoal = 20
    settings.postureVoiceVolume = 1.7

    let clamped = settings.clamped()
    XCTAssertEqual(clamped.focusMinutes, 60)
    XCTAssertEqual(clamped.shortBreakMinutes, 1)
    XCTAssertEqual(clamped.longBreakMinutes, 30)
    XCTAssertEqual(clamped.focusPerLongBreak, 2)
    XCTAssertEqual(clamped.dailyGoal, 12)
    XCTAssertEqual(clamped.postureVoiceVolume, 1)

    settings.postureVoiceVolume = -0.3
    XCTAssertEqual(settings.clamped().postureVoiceVolume, 0)
  }

  func testClampedSnapsTheFocusLengthOntoItsFiveMinuteStep() {
    var settings = PomodoroSettings()

    settings.focusMinutes = 7
    XCTAssertEqual(settings.clamped().focusMinutes, 5)

    settings.focusMinutes = 58
    XCTAssertEqual(settings.clamped().focusMinutes, 60)

    settings.focusMinutes = 32
    XCTAssertEqual(settings.clamped().focusMinutes, 30)

    settings.focusMinutes = 1
    XCTAssertEqual(settings.clamped().focusMinutes, 5)
  }

  // MARK: - Focus

  func testFocusCompletesAtThePlannedTimeAndAShortBreakFollows() {
    var engine = makeEngine()
    XCTAssertEqual(engine.phase, .focus)
    XCTAssertEqual(engine.isRunning, false)
    XCTAssertEqual(engine.remainingSeconds, 1500)
    XCTAssertEqual(engine.focusIndex, 1)

    XCTAssertEqual(engine.command(.start), [.phaseChanged(to: .focus, index: 1)])
    XCTAssertEqual(engine.isRunning, true)

    // 24:59 of samples: the countdown follows the stream and nothing else.
    feed(&engine, samples(14_990))
    XCTAssertEqual(engine.remainingSeconds, 1)
    XCTAssertEqual(engine.phase, .focus)
    XCTAssertEqual(engine.record.focusedSeconds, 1499)

    let events = feed(&engine, samples(10, from: 1499))

    XCTAssertEqual(events.count, 2)
    guard case .completed(let record) = events[0] else {
      return XCTFail("expected a completed pomodoro")
    }
    XCTAssertEqual(record.outcome, .completed)
    XCTAssertEqual(record.startedAt, 0)
    XCTAssertEqual(record.endedAt, 1500)
    XCTAssertEqual(record.plannedSeconds, 1500)
    XCTAssertEqual(record.focusedSeconds, 1500)
    XCTAssertEqual(record.pausedSeconds, 0)
    XCTAssertEqual(record.skippedBreak, false)
    XCTAssertEqual(record.focusIndex, 1)

    XCTAssertEqual(events[1], .phaseChanged(to: .shortBreak, index: 1))
    XCTAssertEqual(engine.phase, .shortBreak)
    XCTAssertEqual(engine.remainingSeconds, 300)
    XCTAssertEqual(engine.isRunning, true)
  }

  func testShortBreakEndsIntoAWaitingNextFocus() {
    var engine = makeEngine()
    _ = engine.command(.start)
    feed(&engine, samples(15_000))
    XCTAssertEqual(engine.phase, .shortBreak)

    // The default `autoStartFocus` is off: the break ends and the next focus waits for `.start`.
    let events = feed(&engine, samples(3_000, from: 1500))
    XCTAssertEqual(events, [.phaseChanged(to: .focus, index: 2)])
    XCTAssertEqual(engine.phase, .focus)
    XCTAssertEqual(engine.focusIndex, 2)
    XCTAssertEqual(engine.remainingSeconds, 1500)
    XCTAssertEqual(engine.isRunning, false)

    // A waiting focus does not spend time just because samples keep arriving.
    XCTAssertEqual(feed(&engine, samples(600, from: 1800)), [])
    XCTAssertEqual(engine.remainingSeconds, 1500)
  }

  func testFourthFocusProducesALongBreak() {
    var settings = PomodoroSettings()
    settings.focusMinutes = 1
    settings.shortBreakMinutes = 1
    settings.longBreakMinutes = 1
    var engine = makeEngine(settings)
    _ = engine.command(.start)

    var clock: TimeInterval = 0
    var last: [PomodoroEvent] = []
    for index in 1...4 {
      last = feed(&engine, samples(600, from: clock))
      clock += 60
      guard index < 4 else { break }

      XCTAssertEqual(last.last, .phaseChanged(to: .shortBreak, index: index))
      feed(&engine, samples(600, from: clock))
      clock += 60
      XCTAssertEqual(engine.phase, .focus)
      XCTAssertEqual(engine.isRunning, false)
      _ = engine.command(.start)
    }

    XCTAssertEqual(last.last, .phaseChanged(to: .longBreak, index: 4))
    XCTAssertEqual(engine.phase, .longBreak)
    XCTAssertEqual(engine.record.focusIndex, 4)
    XCTAssertEqual(engine.remainingSeconds, 60)
  }

  func testAutoStartBreakOffLeavesTheBreakWaiting() {
    var settings = PomodoroSettings()
    settings.autoStartBreak = false
    var engine = makeEngine(settings)
    _ = engine.command(.start)

    let events = feed(&engine, samples(15_000))
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(engine.phase, .shortBreak)
    XCTAssertEqual(engine.isRunning, false)
    XCTAssertEqual(engine.remainingSeconds, 300)

    // Nothing ticks until the break is started.
    XCTAssertEqual(feed(&engine, samples(600, from: 1500)), [])
    XCTAssertEqual(engine.remainingSeconds, 300)
  }

  // MARK: - Pause

  func testPauseInsideAFocusDoesNotInflateFocusedSeconds() {
    var engine = makeEngine()
    _ = engine.command(.start)
    feed(&engine, samples(6_000))
    XCTAssertEqual(engine.remainingSeconds, 900)
    XCTAssertEqual(engine.record.focusedSeconds, 600)

    _ = engine.command(.pause)
    XCTAssertEqual(engine.isRunning, false)
    feed(&engine, samples(1_200, from: 600))
    XCTAssertEqual(engine.remainingSeconds, 900)
    XCTAssertEqual(engine.record.focusedSeconds, 600)
    XCTAssertEqual(engine.record.pausedSeconds, 120)

    _ = engine.command(.resume)
    let events = feed(&engine, samples(9_000, from: 720))

    XCTAssertEqual(events.last, .phaseChanged(to: .shortBreak, index: 1))
    guard case .completed(let record) = events.first else {
      return XCTFail("expected a completed pomodoro")
    }
    XCTAssertEqual(record.focusedSeconds, 1500)
    XCTAssertEqual(record.pausedSeconds, 120)
    XCTAssertEqual(record.endedAt, 1620)
  }

  // MARK: - Absence

  func testAbsenceSuspendsTheFocusAndItsSecondsAreNotFocusTime() {
    var engine = makeEngine()
    _ = engine.command(.start)
    feed(&engine, samples(6_000))
    XCTAssertEqual(engine.remainingSeconds, 900)
    XCTAssertEqual(engine.record.focusedSeconds, 600)
    XCTAssertEqual(engine.isPausedByAbsence, false)

    // The face is gone from the 600.1 tick and back at 660.0: sixty seconds nobody was in the chair.
    XCTAssertEqual(feed(&engine, absentSamples(599, from: 600)), [])
    XCTAssertEqual(engine.isRunning, true)          // suspended, not stopped
    XCTAssertEqual(engine.isPausedByAbsence, true)
    XCTAssertEqual(engine.remainingSeconds, 900)    // the countdown holds where it stood
    XCTAssertEqual(engine.record.focusedSeconds, 600)
    // AC5: the away time is not focus time, so it is credited to the pause exactly like a manual
    // one — the whole 60 s band the parent's timeline draws grey.
    XCTAssertEqual(engine.record.pausedSeconds, 59.8, accuracy: 0.2)

    feed(&engine, samples(11, from: 659.9))         // back at 660.0, still there at 661.0
    XCTAssertEqual(engine.isPausedByAbsence, false)
    XCTAssertEqual(engine.remainingSeconds, 899)
    XCTAssertEqual(engine.record.focusedSeconds, 601)  // 661 s of clock, 60 s of it away
    XCTAssertEqual(engine.record.pausedSeconds, 59.9, accuracy: 0.2)
    XCTAssertEqual(engine.phase, .focus)
  }

  func testAnAbsenceUnderTheLimitDoesNotInterruptTheFocus() {
    var engine = makeEngine()
    _ = engine.command(.start)
    feed(&engine, samples(6_000))

    // 299 s away, all of it suspended and none of it focus time.
    XCTAssertEqual(feed(&engine, absentSamples(2_990, from: 600)), [])
    XCTAssertEqual(engine.isPausedByAbsence, true)
    XCTAssertEqual(engine.phase, .focus)
    XCTAssertEqual(engine.isRunning, true)
    XCTAssertNil(engine.record.endedAt)
    XCTAssertEqual(engine.remainingSeconds, 900)
    XCTAssertEqual(engine.record.focusedSeconds, 600)

    // Back at 899.1: the countdown picks up where it stopped, with the whole ten minutes left.
    XCTAssertEqual(feed(&engine, samples(1, from: 899)), [])
    XCTAssertEqual(engine.isPausedByAbsence, false)
    XCTAssertEqual(engine.remainingSeconds, 900)
    XCTAssertEqual(engine.record.focusedSeconds, 600)
    XCTAssertEqual(engine.phase, .focus)
  }

  func testAnAbsencePastTheLimitInterruptsTheFocusWithoutABreak() {
    var engine = makeEngine()
    _ = engine.command(.start)
    feed(&engine, samples(6_000))

    // Exactly 300 s away is still the same, suspended focus ...
    XCTAssertEqual(feed(&engine, absentSamples(3_000, from: 600)), [])
    XCTAssertEqual(engine.isRunning, true)
    XCTAssertEqual(engine.remainingSeconds, 900)

    // ... and the tick that makes it 300.1 s ends it.
    let events = feed(&engine, absentSamples(10, from: 900))
    XCTAssertEqual(events.count, 1)
    guard case .interrupted(let record) = events[0] else {
      return XCTFail("expected an interrupted pomodoro")
    }
    XCTAssertEqual(record.outcome, .interrupted)
    XCTAssertEqual(record.startedAt, 0)
    // "more than 300 s" is strict, so on a 10 Hz stream the absence that began at 600.1 s trips at
    // the first sample past 900.1 s, which is 900.2.
    XCTAssertEqual(record.endedAt, 900.2)
    XCTAssertEqual(record.plannedSeconds, 1500)
    XCTAssertEqual(record.focusedSeconds, 600)      // ten minutes in, and never the absence
    // The whole absence is time outside the focus, so it is credited to the pause the same way a
    // manual one is (AC5); the interval up to the interrupting tick is included.
    XCTAssertEqual(record.pausedSeconds, 300.1, accuracy: 0.2)
    XCTAssertEqual(record.skippedBreak, false)
    XCTAssertEqual(record.focusIndex, 1)

    // B5: no break, nothing auto-starts, and the child comes back to a full, still countdown.
    XCTAssertEqual(engine.phase, .focus)
    XCTAssertEqual(engine.isRunning, false)
    XCTAssertEqual(engine.isPausedByAbsence, false)
    XCTAssertEqual(engine.remainingSeconds, 1500)
    XCTAssertEqual(feed(&engine, absentSamples(100, from: 901)), [])
    XCTAssertEqual(engine.remainingSeconds, 1500)
  }

  /// AC5: an absence pauses the focus exactly like a manual pause does, and the record says how
  /// long it lasted. The countdown holds where it stood and the minute lands in `pausedSeconds`
  /// instead of the focus, so `focusedSeconds + pausedSeconds` still accounts for the wall clock.
  func testAnAbsenceHoldsTheCountdownAndIsCreditedAsPausedSeconds() {
    var settings = PomodoroSettings()
    settings.focusMinutes = 5
    var engine = makeEngine(settings)
    _ = engine.command(.start)

    feed(&engine, samples(100))                      // t = 0.1 ... 10.0, face present
    let atAbsence = engine.remainingSeconds
    XCTAssertEqual(atAbsence, 290, accuracy: 0.1)

    feed(&engine, absentSamples(40, from: 10))       // t = 10.1 ... 14.0, no face
    XCTAssertTrue(engine.isPausedByAbsence)
    XCTAssertEqual(engine.remainingSeconds, atAbsence, accuracy: 1e-9,
                   "an absence moved the countdown")
    XCTAssertEqual(engine.record.pausedSeconds, 3.9, accuracy: 0.15)

    feed(&engine, samples(30, from: 14))             // t = 14.1 ... 17.0, the child is back
    XCTAssertFalse(engine.isPausedByAbsence)
    XCTAssertEqual(engine.remainingSeconds, 287.1, accuracy: 0.1,
                   "the focus did not resume where it stopped")

    let record = engine.record
    XCTAssertEqual(record.pausedSeconds, 4.0, accuracy: 0.15)
    XCTAssertEqual(record.focusedSeconds + record.pausedSeconds, 16.9, accuracy: 0.2,
                   "the record stopped accounting for its wall clock")
  }

  // MARK: - Manual entry

  /// The row's text field writes through exactly this gate: a number out of range becomes the nearest
  /// legal value, the focus length is snapped onto its step, and no path can produce the zero a stored
  /// setting must never hold.
  func testManualEntryClampsEveryIntegerSetting() {
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "0", for: "focusMinutes"), 5)
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "999", for: "focusMinutes"), 60)
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "12", for: "focusMinutes"), 10)
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "13", for: "focusMinutes"), 15)
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: " 30 ", for: "focusMinutes"), 30)
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "０", for: "shortBreakMinutes"), 1)
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "99", for: "shortBreakMinutes"), 15)
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "0", for: "longBreakMinutes"), 5)
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "0", for: "focusPerLongBreak"), 2)
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "0", for: "dailyGoal"), 1)
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "１３", for: "focusMinutes"), 15)

    // Not a number this row can use: the caller keeps the value it already had.
    XCTAssertNil(PomodoroSettings.value(fromManualEntry: "", for: "focusMinutes"))
    XCTAssertNil(PomodoroSettings.value(fromManualEntry: "   ", for: "focusMinutes"))
    XCTAssertNil(PomodoroSettings.value(fromManualEntry: "abc", for: "focusMinutes"))
    XCTAssertNil(PomodoroSettings.value(fromManualEntry: "5.5", for: "focusMinutes"))
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "-5", for: "focusMinutes"), 5)
    XCTAssertNil(PomodoroSettings.value(fromManualEntry: "10", for: "endSound"))

    // More digits than `Int` holds is still digits, not a discarded entry: the magnitude is past
    // every range, so the typed number clamps to the end its sign points at instead of being kept.
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "999999999999999999999", for: "focusMinutes"), 60)
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "-999999999999999999999", for: "focusMinutes"), 5)
    XCTAssertEqual(PomodoroSettings.value(fromManualEntry: "999999999999999999999", for: "dailyGoal"), 12)
    XCTAssertNil(PomodoroSettings.value(fromManualEntry: "-", for: "focusMinutes"))
  }

  /// Every integer setting refuses to hold zero, whichever way the value arrived.
  func testNoIntegerSettingCanBeStoredAsZero() {
    XCTAssertEqual(PomodoroSettings.ranges.count, 5)
    for key in PomodoroSettings.ranges.keys {
      guard let clamped = PomodoroSettings.clamp(0, for: key) else {
        XCTFail("\(key) is missing from the clamp table")
        continue
      }
      XCTAssertGreaterThan(clamped, 0, "\(key) accepted zero")
    }

    var settings = PomodoroSettings()
    settings.focusMinutes = 0
    settings.shortBreakMinutes = 0
    settings.longBreakMinutes = 0
    settings.focusPerLongBreak = 0
    settings.dailyGoal = 0

    let clamped = settings.clamped()
    XCTAssertEqual(clamped.focusMinutes, 5)
    XCTAssertEqual(clamped.shortBreakMinutes, 1)
    XCTAssertEqual(clamped.longBreakMinutes, 5)
    XCTAssertEqual(clamped.focusPerLongBreak, 2)
    XCTAssertEqual(clamped.dailyGoal, 1)
  }

  // MARK: - Ending early

  func testAbandonReportsTheActualFocusedTime() {
    var engine = makeEngine()
    _ = engine.command(.start)
    feed(&engine, samples(3_000))

    let events = engine.command(.abandon)
    XCTAssertEqual(events.count, 1)
    guard case .abandoned(let record) = events[0] else {
      return XCTFail("expected an abandoned pomodoro")
    }
    XCTAssertEqual(record.outcome, .abandoned)
    XCTAssertEqual(record.startedAt, 0)
    XCTAssertEqual(record.endedAt, 300)
    XCTAssertEqual(record.plannedSeconds, 1500)
    XCTAssertEqual(record.focusedSeconds, 300)
    XCTAssertEqual(record.pausedSeconds, 0)
    XCTAssertEqual(record.skippedBreak, false)
    XCTAssertEqual(record.focusIndex, 1)
    // The record carries the evidence the aggregation side attaches; the engine itself owns none.
    XCTAssertEqual(record.postureSegments, [])
    XCTAssertEqual(record.reminderCounts, [:])

    XCTAssertEqual(engine.isRunning, false)
    // B3: the abandoned countdown is spent, so what is left is the whole focus again.
    XCTAssertEqual(engine.remainingSeconds, 1500)
  }

  func testAbandonRearmsTheCountdownToTheFullFocus() {
    var engine = makeEngine()
    _ = engine.command(.start)
    feed(&engine, samples(3_000))
    XCTAssertEqual(engine.remainingSeconds, 1200)

    _ = engine.command(.abandon)
    XCTAssertEqual(engine.remainingSeconds, 1500)
    XCTAssertEqual(engine.isRunning, false)
    XCTAssertEqual(engine.phase, .focus)

    // B3: the next start runs a whole focus, not the tail of the abandoned one.
    _ = engine.command(.start)
    XCTAssertEqual(engine.remainingSeconds, 1500)
    XCTAssertEqual(engine.isRunning, true)
    feed(&engine, samples(10, from: 300))
    XCTAssertEqual(engine.remainingSeconds, 1499)
    XCTAssertEqual(engine.record.plannedSeconds, 1500)
    XCTAssertEqual(engine.record.focusedSeconds, 1)
    XCTAssertEqual(engine.record.startedAt, 300)
    XCTAssertEqual(engine.record.focusIndex, 1)
  }

  func testSkippingABreakIsRecordedAndMovesToTheNextFocus() {
    var engine = makeEngine()
    _ = engine.command(.start)
    feed(&engine, samples(15_000))
    XCTAssertEqual(engine.phase, .shortBreak)
    XCTAssertEqual(engine.isRunning, true)

    let events = engine.command(.skipBreak)
    XCTAssertEqual(events, [.breakSkipped(from: .shortBreak), .phaseChanged(to: .focus, index: 2)])
    XCTAssertEqual(engine.record.skippedBreak, true)
    XCTAssertEqual(engine.record.focusIndex, 1)
    XCTAssertEqual(engine.phase, .focus)
    XCTAssertEqual(engine.focusIndex, 2)
    XCTAssertEqual(engine.remainingSeconds, 1500)
    XCTAssertEqual(engine.isRunning, false)
  }

  func testFinishAbandonsTheFocusInFlight() {
    var engine = makeEngine()
    _ = engine.command(.start)
    feed(&engine, samples(1_000))

    clock.now = 100
    let events = engine.finish()
    XCTAssertEqual(events.count, 2)
    guard case .abandoned(let record) = events[0] else {
      return XCTFail("expected an abandoned pomodoro")
    }
    XCTAssertEqual(record.outcome, .abandoned)
    XCTAssertEqual(record.endedAt, 100)
    XCTAssertEqual(record.focusedSeconds, 100)
    XCTAssertEqual(events[1], .finishedAll)
    XCTAssertEqual(engine.isRunning, false)
  }
  // MARK: - Wall clock (v0.6)

  /// The countdown is the wall clock's, not the sample stream's: with the clock moved and no sample
  /// at all, the timer still counts down and still completes. This is what lets a focus keep time
  /// during the「识别中」gap, when the camera has not produced its first frame yet.
  func testTheCountdownAdvancesWithoutAnySample() {
    var settings = PomodoroSettings()
    settings.focusMinutes = 1
    var engine = makeEngine(settings)
    _ = engine.command(.start)

    clock.now = 0.5
    XCTAssertEqual(engine.tick(), [])
    XCTAssertEqual(engine.remainingSeconds, 59.5, accuracy: 1e-9)

    clock.now = 59.9
    XCTAssertEqual(engine.tick(), [])
    XCTAssertEqual(engine.remainingSeconds, 0.1, accuracy: 1e-9)

    clock.now = 60
    let events = engine.tick()
    XCTAssertEqual(events.count, 2)
    guard case .completed(let record) = events[0] else {
      return XCTFail("expected a completed pomodoro")
    }
    XCTAssertEqual(record.focusedSeconds, 60)
    XCTAssertEqual(record.endedAt, 60)
  }

  /// The focus is stamped with the instant of the tap: the record's `startedAt` is the clock the
  /// start command read, not the last sample the camera delivered before it.
  func testTheStartCommandStampsTheFocusWithTheWallClock() {
    var engine = makeEngine()
    feed(&engine, samples(10))          // the camera ran a second before the tap
    clock.now = 1_000
    _ = engine.command(.start)

    XCTAssertEqual(engine.record.startedAt, 1_000)

    // The first sample arrives 1.4 s later, and the countdown is already 1.4 s into the plan.
    clock.now = 1_001.4
    _ = engine.ingest(PostureSample(t: 11.4, distanceCM: 40, pitchDeg: 15))
    XCTAssertEqual(engine.remainingSeconds, 1498.6, accuracy: 1e-9)
    XCTAssertEqual(engine.record.focusedSeconds, 1.4, accuracy: 1e-9)
  }

  /// A focus that closes with no sample ever arrives still reports against its plan: the record is
  /// abandoned with the focus time the wall clock gave it.
  func testFinishWithNoSampleEverKeepsTheElapsedWallClock() {
    var engine = makeEngine()
    clock.now = 500
    _ = engine.command(.start)
    clock.now = 530
    let events = engine.finish()

    guard case .abandoned(let record) = events[0] else {
      return XCTFail("expected an abandoned pomodoro")
    }
    XCTAssertEqual(record.startedAt, 500)
    XCTAssertEqual(record.endedAt, 530)
    XCTAssertEqual(record.focusedSeconds, 30, accuracy: 1e-9)
    XCTAssertEqual(events[1], .finishedAll)
  }
}
