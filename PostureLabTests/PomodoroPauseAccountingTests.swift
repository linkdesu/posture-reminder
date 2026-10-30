import Foundation
import XCTest
@testable import PostureLab

/// issue #7 AC2：统计里的暂停时长必须与实际暂停时间一致。
///
/// 一个专注的暂停时长有两个读者：记录里的 `pausedSeconds`，和统计页时间轴上的 `paused` /
/// `no_person` 段。`GLOSSARY.md` 与 ADR-0003 要求两者严格相等，而且「无人暂停」只有连续 3 秒
/// 无人之后才成立。这些测试把两个引擎按 `SessionController` 的接线顺序一起驱动，所以它们测的是
/// 用户会看到的那两个数字，而不是某个引擎内部的记账。
final class PomodoroPauseAccountingTests: XCTestCase {
  /// 引擎与时间轴共用的墙钟：每次 `tick` / `ingest` 之前由 `at(t)` 设定。
  private final class Clock {
    var now: TimeInterval = 1_000
    func at(_ t: TimeInterval) { now = t }
  }

  private var clock = Clock()

  override func setUp() {
    super.setUp()
    clock = Clock()
  }

  /// `SessionController.handlePomodoro` 的接线顺序：先喂计时器，再按同一时刻给时间轴画一段。
  /// `status` 是体态引擎这一刻的结论——无人时它是 `no_person`，人回来后还有 1 秒去抖。
  private struct Run {
    var engine: PomodoroEngine
    var timeline = FocusTimeline()
    let clock: Clock
    /// 体态引擎此刻报的状态；脚本里由测试给出，真机上来自 `MonitoringEngine`。
    var status: String = PostureStatus.good.rawValue

    init(settings: PomodoroSettings = PomodoroSettings(), clock: Clock) {
      self.clock = clock
      engine = PomodoroEngine(settings: settings, now: { clock.now })
    }

    mutating func start(at t: TimeInterval) {
      clock.at(t)
      timeline.started(at: t)
      _ = engine.command(.start)
    }

    /// One camera tick: the timer first, then the band the controller would draw for this instant.
    mutating func sample(_ sample: PostureSample, at t: TimeInterval, status: String) {
      clock.at(t)
      _ = engine.ingest(sample)
      self.status = status
      let kind = FocusTimeline.bandKind(isPaused: isPaused,
                                        isPausedByAbsence: engine.isPausedByAbsence,
                                        status: status)
      if let kind {
        _ = timeline.observe(kind, at: t)
      } else {
        timeline.endPause(at: t)
      }
    }

    /// One tick of the countdown's own timer, which the controller also uses to cut a stalled band.
    mutating func tick(at t: TimeInterval) {
      clock.at(t)
      _ = engine.tick()
    }

    mutating func finish(at t: TimeInterval) -> PomodoroRecord {
      clock.at(t)
      let events = engine.finish()
      let record = events.compactMap { event -> PomodoroRecord? in
        switch event {
        case .abandoned(let record), .completed(let record), .interrupted(let record): return record
        default: return nil
        }
      }.last ?? engine.record
      _ = timeline.finished(at: t)
      return record
    }

    var isPaused: Bool { !engine.isRunning || engine.isPausedByAbsence }

    /// 时间轴上两个暂停带的秒数之和，也就是统计页「暂停」+「不在画面」两行相加。
    var pausedBandSeconds: Double {
      timeline.segments
        .filter { $0.kind == PostureSegment.pausedKind || $0.kind == PostureStatus.noPerson.rawValue }
        .reduce(0) { $0 + $1.seconds }
    }
  }

  private func present(_ t: TimeInterval) -> PostureSample {
    PostureSample(t: t, distanceCM: 40, pitchDeg: 15)
  }

  private func absent(_ t: TimeInterval) -> PostureSample {
    PostureSample(t: t, distanceCM: nil, pitchDeg: nil)
  }

  /// 10 Hz 的一整段：从 `from` 到 `to`（不含），每 0.1 秒一帧。
  private func stretch(from: TimeInterval,
                       to: TimeInterval,
                       eyesOn: Bool,
                       status: String,
                       into run: inout Run) {
    var t = from
    while t < to {
      let sample = eyesOn ? present(t) : absent(t)
      run.sample(sample, at: t, status: status)
      t += 0.1
    }
  }

  // MARK: - AC2

  /// 眨眼级别的人脸丢失（2 秒，未满 3 秒）不是「无人」，倒计时不能停：它既不该冻结，也不该给
  /// 暂停时长或灰色带加时间。
  func testAbsenceShorterThanThreeSecondsDoesNotPauseTheCountdown() {
    var run = Run(clock: clock)
    run.start(at: 1_000)

    stretch(from: 1_000, to: 1_005, eyesOn: true, status: PostureStatus.good.rawValue, into: &run)
    stretch(from: 1_005, to: 1_007, eyesOn: false, status: PostureStatus.noPerson.rawValue, into: &run)
    stretch(from: 1_007, to: 1_012, eyesOn: true, status: PostureStatus.good.rawValue, into: &run)

    XCTAssertEqual(run.engine.record.pausedSeconds, 0, accuracy: 0.001,
                   "a two-second blink was counted as a pause")
    XCTAssertEqual(run.engine.remainingSeconds, 1_500 - 12, accuracy: 0.2,
                   "the countdown froze for a blink")
    XCTAssertEqual(run.pausedBandSeconds, 0, accuracy: 0.001,
                   "a blink drew a pause band on the report")
    XCTAssertFalse(run.timeline.segments.contains { $0.kind == PostureSegment.noDataKind },
                   "a blink in the stream was reported as 无数据")
  }

  /// 5 秒无人按规则只暂停 3 秒之后的部分：`pausedSeconds` 与时间轴的暂停带都只能是这 2 秒。
  func testAnAbsencePausesOnlyAfterThreeSecondsAndTheRecordMatchesTheTimeline() {
    var run = Run(clock: clock)
    run.start(at: 1_000)

    stretch(from: 1_000, to: 1_005, eyesOn: true, status: PostureStatus.good.rawValue, into: &run)
    stretch(from: 1_005, to: 1_010, eyesOn: false, status: PostureStatus.noPerson.rawValue, into: &run)
    // The face is back, but the posture engine holds「无人」for its one-second resume debounce
    // (`MonitoringEngine`'s `presenceResumeDelay`). Those seconds are focus time and must not extend
    // the 不在画面 band past the pause they follow - that was the 0.9 s vs 1.9 s mismatch this test
    // now pins.
    stretch(from: 1_010, to: 1_011, eyesOn: true, status: PostureStatus.noPerson.rawValue, into: &run)
    stretch(from: 1_011, to: 1_016, eyesOn: true, status: PostureStatus.good.rawValue, into: &run)

    let record = run.finish(at: 1_016)

    XCTAssertEqual(record.pausedSeconds, 2, accuracy: 0.15,
                   "the absence pause did not start three seconds in")
    XCTAssertEqual(run.pausedBandSeconds, 2, accuracy: 0.15,
                   "the pause band outlived the pause by the resume debounce")
    XCTAssertEqual(run.pausedBandSeconds, record.pausedSeconds, accuracy: 0.15,
                   "the report's pause bands disagree with the record's pausedSeconds")
  }

  /// 手动暂停走的是另一条路径，但它读的是同一个数字：记录与统计页的暂停带仍然必须相等。
  func testAManualPauseKeepsTheRecordAndTheTimelineEqual() {
    var run = Run(clock: clock)
    run.start(at: 1_000)

    stretch(from: 1_000, to: 1_005, eyesOn: true, status: PostureStatus.good.rawValue, into: &run)

    clock.at(1_005)
    _ = run.engine.command(.pause)
    var t = 1_005.1
    while t < 1_015 {
      run.tick(at: t)
      run.sample(present(t), at: t, status: PostureStatus.good.rawValue)
      t += 0.25
    }

    clock.at(1_015)
    _ = run.engine.command(.resume)
    stretch(from: 1_015, to: 1_020, eyesOn: true, status: PostureStatus.good.rawValue, into: &run)

    let record = run.finish(at: 1_020)

    XCTAssertEqual(record.pausedSeconds, 10, accuracy: 0.15, "the ten-second pause was not recorded")
    XCTAssertEqual(run.pausedBandSeconds, record.pausedSeconds, accuracy: 0.15,
                   "the report's pause band disagrees with the record's pausedSeconds")
  }
}
