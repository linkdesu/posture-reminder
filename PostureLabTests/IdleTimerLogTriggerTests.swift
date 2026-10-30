import XCTest
@testable import PostureLab

/// v0.6.5：常亮取证日志的四个时刻与一行的格式。
final class IdleTimerLogTriggerTests: XCTestCase {
  private typealias T = IdleTimerLogTrigger
  private typealias S = IdleTimerLogTrigger.State

  private let parked = S(focusOpen: false, paused: false, sceneActive: true)
  private let counting = S(focusOpen: true, paused: false, sceneActive: true)
  private let paused = S(focusOpen: true, paused: true, sceneActive: true)

  func testFocusStartIsLoggedOnceFromLaunch() {
    XCTAssertEqual(T.triggers(from: nil, to: counting), [.focusStart])
    XCTAssertEqual(T.triggers(from: counting, to: counting), [])
  }

  func testLaunchWritesNothing() {
    XCTAssertEqual(T.triggers(from: nil, to: parked), [])
  }

  func testPauseAndResumeAreEachLoggedOnce() {
    XCTAssertEqual(T.triggers(from: counting, to: paused), [.pause])
    XCTAssertEqual(T.triggers(from: paused, to: paused), [])
    XCTAssertEqual(T.triggers(from: paused, to: counting), [.resume])
    XCTAssertEqual(T.triggers(from: counting, to: counting), [])
  }

  /// 暂停中直接结束专注只记 focus_end，不记 resume。
  func testEndingAPausedFocusIsNotAResume() {
    XCTAssertEqual(T.triggers(from: paused, to: parked), [.focusEnd])
  }

  func testForegroundIsLoggedOnceInAnyState() {
    var bg = counting
    bg.sceneActive = false
    XCTAssertEqual(T.triggers(from: bg, to: counting), [.foreground])
    XCTAssertEqual(T.triggers(from: counting, to: counting), [])
    var parkedBg = parked
    parkedBg.sceneActive = false
    XCTAssertEqual(T.triggers(from: parkedBg, to: parked), [.foreground])
  }

  // MARK: - 写入的是状态生效后应用上的实际值（按 SessionController 的顺序：先 update，再记）

  @MainActor
  private final class Recorder {
    let application = LogFakeApplication()
    lazy var controller = IdleTimerController(application: application)
    var state: S?
    var rows: [(T, Bool)] = []

    /// counting：专注在计时（未暂停、未休息）。
    func apply(_ new: S, counting: Bool) {
      controller.update(IdleTimerPolicy(isFocusCounting: counting, isSceneActive: new.sceneActive))
      let value = controller.actualValue ?? false
      for trigger in T.triggers(from: state, to: new) { rows.append((trigger, value)) }
      state = new
    }

    func last(_ trigger: T) -> Bool? { rows.last { $0.0 == trigger }?.1 }
  }

  @MainActor
  func testResumeAfterPauseRecordsTrue() {
    let r = Recorder()
    r.apply(counting, counting: true)
    r.apply(paused, counting: false)
    XCTAssertEqual(r.last(.pause), false)
    r.apply(counting, counting: true)
    XCTAssertEqual(r.last(.resume), true)
  }

  @MainActor
  func testForegroundDuringFocusRecordsTrue() {
    let r = Recorder()
    r.apply(counting, counting: true)
    var bg = counting
    bg.sceneActive = false
    r.apply(bg, counting: true)
    XCTAssertEqual(r.last(.background), false)
    r.apply(counting, counting: true)
    XCTAssertEqual(r.last(.foreground), true)
  }

  @MainActor
  func testForegroundDuringBreakOrOnHomeRecordsFalse() {
    // 休息：专注已关闭，计时的是休息，不占常亮。
    let r = Recorder()
    r.apply(counting, counting: true)
    r.apply(parked, counting: false)
    var bg = parked
    bg.sceneActive = false
    r.apply(bg, counting: false)
    r.apply(parked, counting: false)
    XCTAssertEqual(r.last(.foreground), false)
    // 首页（还没开始专注）。
    let home = Recorder()
    home.apply(parked, counting: false)
    home.apply(bg, counting: false)
    home.apply(parked, counting: false)
    XCTAssertEqual(home.rows.map { $0.0 }, [.background, .foreground])
    XCTAssertEqual(home.last(.foreground), false)
  }

  func testFocusEndIsLogged() {
    XCTAssertEqual(T.triggers(from: counting, to: parked), [.focusEnd])
    XCTAssertEqual(T.triggers(from: paused, to: parked), [.focusEnd])
  }

  func testBackgroundIsLoggedOnceInAnyState() {
    var bg = counting
    bg.sceneActive = false
    XCTAssertEqual(T.triggers(from: counting, to: bg), [.background])
    XCTAssertEqual(T.triggers(from: bg, to: bg), [])
    var parkedBg = parked
    parkedBg.sceneActive = false
    XCTAssertEqual(T.triggers(from: parked, to: parkedBg), [.background])
  }

  func testLineCarriesTheBoolAndTrigger() throws {
    let line = T.line(trigger: .pause, idleTimerDisabled: false, epochSeconds: 1_700_000_000.5)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    XCTAssertEqual(object["trigger"] as? String, "pause")
    XCTAssertEqual(object["idle_timer_disabled"] as? Bool, false)
    XCTAssertEqual(object["t"] as? Int, 1_700_000_000_500)
    XCTAssertEqual(Set(object.keys), ["t", "trigger", "idle_timer_disabled"])
    let on = T.line(trigger: .focusStart, idleTimerDisabled: true, epochSeconds: 0)
    XCTAssertTrue(on.contains("\"idle_timer_disabled\":true"))
  }

  /// 记的是应用上实际的值：开始时 true，暂停、结束、后台时 false。
  @MainActor
  func testActualValueFollowsTheApplication() {
    let application = LogFakeApplication()
    let controller = IdleTimerController(application: application)
    XCTAssertEqual(controller.actualValue, false)
    controller.update(IdleTimerPolicy(isFocusCounting: true, isSceneActive: true))
    XCTAssertEqual(controller.actualValue, true)
    controller.update(IdleTimerPolicy(isFocusCounting: false, isSceneActive: true))
    XCTAssertEqual(controller.actualValue, false)
    controller.update(IdleTimerPolicy(isFocusCounting: true, isSceneActive: false))
    XCTAssertEqual(controller.actualValue, false)
    let none = IdleTimerController(application: { nil })
    XCTAssertNil(none.actualValue)
  }
}

@MainActor
final class LogFakeApplication: IdleTimerControlling {
  var isIdleTimerDisabled = false
}
