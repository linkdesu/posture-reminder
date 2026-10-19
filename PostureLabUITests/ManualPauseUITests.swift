import XCTest

/// AC12, the half a child drives: the 暂停 button stops the countdown, and 开始专注 starts it again.
///
/// The record's pause band belongs to the parent's report — the runner reads it off the JSONL — but
/// the two things the child can see are the clock standing still while paused and the clock moving
/// again after the resume. Both are asserted here, a few seconds apart, off the countdown the screen
/// shows, and both moments are photographed as `AC12-manual-pause-paused` and
/// `AC12-manual-pause-resumed` (see `attachScreenshot`).
///
/// `longRun` never loses the face, so the only thing that can stop this clock is the tap.
final class ManualPauseUITests: XCTestCase {

  func testPauseThenResumeLeavesAPauseBand() throws {
    let app = launchApp(PomodoroLaunch.scriptedFocus(scenario: "longRun", minutes: 5))

    // A scripted run opens its first focus on its own about a second in, and 暂停 is drawn only while
    // that focus is running.
    let pause = app.first(.button, labelled: "暂停")
    XCTAssertTrue(pause.waitForExistence(timeout: 30), "the scripted focus never started")

    // A clock that never moved is not worth stopping.
    let start = try XCTUnwrap(countdown(in: app), "the countdown is not on screen")
    XCTAssertTrue(wait(upTo: 10, for: { (self.countdown(in: app) ?? start) != start }),
                  "the countdown never moved")

    pause.tap()
    // A paused focus is resumed through the same button that starts one, so that button is also the
    // screen's own sign that the clock is now stopped.
    XCTAssertTrue(app.first(.button, labelled: "开始专注").waitForExistence(timeout: 10),
                  "暂停 left no way back: 开始专注 never appeared")
    let paused = try XCTUnwrap(countdown(in: app), "the countdown left the screen when paused")

    // Five seconds of real clock, in which the child's clock must not move at all.
    RunLoop.current.run(until: Date().addingTimeInterval(5))
    XCTAssertEqual(countdown(in: app), paused, "the countdown kept running while paused")
    attachScreenshot(of: app, named: "AC12-manual-pause-paused")

    app.first(.button, labelled: "开始专注").tap()
    XCTAssertTrue(wait(upTo: 15, for: { (self.countdown(in: app) ?? Int.max) < paused }),
                  "the countdown did not start again after the resume")
    // 暂停 is back, which is what a running focus looks like to the child.
    XCTAssertTrue(app.first(.button, labelled: "暂停").waitForExistence(timeout: 10),
                  "the resumed focus shows no 暂停, so its clock is not running")

    // And it keeps moving: one tick could be a clock that stopped one second later.
    let running = try XCTUnwrap(countdown(in: app), "the countdown left the screen after the resume")
    XCTAssertTrue(wait(upTo: 15, for: { (self.countdown(in: app) ?? Int.max) < running }),
                  "the countdown stopped again after the resume")
    attachScreenshot(of: app, named: "AC12-manual-pause-resumed")
  }

  /// The countdown the child sees, in whole seconds.
  ///
  /// The screen gives the countdown the label 剩余 mm:ss and rounds up, so the last second reads
  /// 00:01 rather than showing zero early: the parsing here has to agree with it about how many
  /// seconds are left, not about pixels.
  private func countdown(in app: XCUIApplication) -> Int? {
    let element = app.first(.staticText, labelStartingWith: "剩余 ")
    guard element.exists else { return nil }
    return Self.seconds(in: element.label)
  }

  /// "剩余 04:59" -> 299.
  private static func seconds(in label: String) -> Int? {
    guard let clock = label.split(separator: " ").last else { return nil }
    let parts = clock.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return nil }
    return parts[0] * 60 + parts[1]
  }
}
