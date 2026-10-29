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

  func testPauseIsLoggedOnceAndResumeIsNot() {
    XCTAssertEqual(T.triggers(from: counting, to: paused), [.pause])
    XCTAssertEqual(T.triggers(from: paused, to: paused), [])
    XCTAssertEqual(T.triggers(from: paused, to: counting), [])
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
private final class LogFakeApplication: IdleTimerControlling {
  var isIdleTimerDisabled = false
}
