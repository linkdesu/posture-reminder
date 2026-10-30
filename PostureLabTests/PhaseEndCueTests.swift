import Foundation
import XCTest
@testable import PostureLab

/// issue #7 AC3：番茄钟结束时提示音要响。
///
/// `GLOSSARY.md` 的「阶段提示音」是**专注或休息阶段自然结束**时的声音：倒计时归零响，孩子点
/// 「离开」或「跳过休息」不响，`EndSound.none` 是静音选择。`cue_played` 只在真正起播时写，所以
/// 判断「该不该响」必须发生在播放器之前——这就是这里测的那条规则。
final class PhaseEndCueTests: XCTestCase {
  /// A focus that ran to zero: the record it closed with.
  private var completedFocus: PomodoroRecord {
    PomodoroRecord(startedAt: 0, endedAt: 60, plannedSeconds: 60, focusedSeconds: 60,
                   pausedSeconds: 0, outcome: .completed, focusIndex: 1)
  }

  func testAFocusThatRunsOutRingsTheChosenSound() {
    let cues = PhaseEndCue.cues(for: [.completed(completedFocus)], endSound: .chime)
    XCTAssertEqual(cues, [.endChime], "a completed focus did not ring its end sound")
  }

  /// 休息结束也是「阶段自然结束」，同样要响：孩子听到声音才知道该回到书桌前。
  func testABreakThatRunsOutRingsTheSameSound() {
    for phase in [PomodoroPhase.shortBreak, .longBreak] {
      let cues = PhaseEndCue.cues(for: [.phaseEnded(phase)], endSound: .soft)
      XCTAssertEqual(cues, [.endSoft], "a finished \(phase.rawValue) stayed silent")
    }
  }

  /// 静音是一个真实选择：不响，也不写 `cue_played`。
  func testSilentSettingRingsNothing() {
    XCTAssertEqual(PhaseEndCue.cues(for: [.completed(completedFocus),
                                          .phaseEnded(.shortBreak)], endSound: EndSound.none),
                   [])
  }

  /// 孩子自己结束的专注和休息不是「自然结束」，不能补响一声。
  func testEndsTheChildCausedStaySilent() {
    var abandoned = completedFocus
    abandoned.outcome = .abandoned
    let cues = PhaseEndCue.cues(for: [.breakSkipped(from: .shortBreak),
                                      .abandoned(abandoned),
                                      .interrupted(abandoned),
                                      .phaseChanged(to: .focus, index: 2),
                                      .finishedAll],
                                endSound: .soft)
    XCTAssertEqual(cues, [], "an early end was celebrated with an end sound")
  }

  /// 规则要有人喂：倒计时把休息走完时，引擎必须报一个 `phaseEnded`，否则控制器永远等不到那次
  /// 提示音。被跳过的休息则不能报——它没有走完。
  func testTheEngineReportsABreakThatRanOutAndNotOneThatWasSkipped() {
    var now: TimeInterval = 1_000
    var engine = PomodoroEngine(settings: PomodoroSettings(focusMinutes: 1,
                                                           shortBreakMinutes: 1,
                                                           autoStartBreak: true),
                                now: { now })

    _ = engine.command(.start)
    // A focus that runs its minute out enters the break, which auto-starts.
    var events: [PomodoroEvent] = []
    for _ in 0..<61 {
      now += 1
      events += engine.tick()
    }
    XCTAssertEqual(engine.phase, .shortBreak)
    XCTAssertTrue(events.contains(.completed(engine.record)),
                  "the focus did not complete before the break")

    // ...and the break's own minute out is a phase that ended by itself.
    events = []
    for _ in 0..<61 {
      now += 1
      events += engine.tick()
    }
    XCTAssertEqual(engine.phase, .focus)
    XCTAssertTrue(events.contains(.phaseEnded(.shortBreak)),
                  "a break that ran out was not reported as an ended phase")

    // A skipped break is the child's own action, so it never reports one.
    now += 1
    _ = engine.command(.start)
    for _ in 0..<61 {
      now += 1
      _ = engine.tick()
    }
    XCTAssertEqual(engine.phase, .shortBreak)
    let skipped = engine.command(.skipBreak)
    XCTAssertFalse(skipped.contains { if case .phaseEnded = $0 { return true } else { return false } },
                   "a skipped break was reported as a phase that ended by itself")
  }
}
