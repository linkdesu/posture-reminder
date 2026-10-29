import XCTest

/// The controls on the child's screen, driven the way a child drives them.
///
/// Three rules are checked here, each on the screen itself rather than on a model:
/// - before 开始专注 there is no way to end a focus, and the point cloud is already live;
/// - once a focus is started the end button is there and reads 休息; pressing it ends the focus
///   early, resets the countdown and stays in the focus phase (no break);
/// - 开始专注 answers a tap anywhere on its capsule, not only on the word.
final class PomodoroControlsUITests: XCTestCase {

  /// The label of the end-the-focus button, written out here because a UI test cannot import the
  /// app's `PomodoroCopy`: if the copy changes, this constant changes with it.
  private static let endFocusLabel = "休息"

  func testParkedScreenHidesTheEndButtonAndStartsWithoutABreak() throws {
    let app = launchApp(PomodoroLaunch.parkedPreview(minutes: 5))

    let start = app.first(.button, labelled: "开始专注")
    XCTAssertTrue(start.waitForExistence(timeout: 30), "the child's screen never parked on 开始专注")
    XCTAssertFalse(app.first(.button, labelled: Self.endFocusLabel).exists,
                   "a parked focus offered the end button before it was ever started")
    XCTAssertFalse(app.first(.button, labelled: "放弃").exists,
                   "the old 放弃 label is still on screen")
    attachScreenshot(of: app, named: "AC-parked-before-start")

    start.tap()
    XCTAssertTrue(app.first(.button, labelled: "暂停").waitForExistence(timeout: 10),
                  "开始专注 did not start the focus")
    let end = app.first(.button, labelled: Self.endFocusLabel)
    XCTAssertTrue(end.waitForExistence(timeout: 5), "a started focus has no 休息 button")
    XCTAssertTrue(wait(upTo: 10, for: { (self.countdownSeconds(in: app) ?? 300) < 300 }),
                  "the countdown never moved after 开始专注")

    end.tap()
    // Ending early is not a completion and not a break: the screen is back at a parked focus with
    // its full length, and the break controls never appear.
    XCTAssertTrue(app.first(.button, labelled: "开始专注").waitForExistence(timeout: 10),
                  "休息 left no parked focus to start again")
    XCTAssertFalse(app.first(.button, labelled: Self.endFocusLabel).exists,
                   "休息 stayed on screen after the focus ended")
    XCTAssertFalse(app.first(.button, labelled: "跳过休息").exists,
                   "ending a focus early entered the break phase")
    let reset = try XCTUnwrap(countdownSeconds(in: app), "the countdown left the screen")
    XCTAssertGreaterThanOrEqual(reset, 295,
                                "countdown was not reset to the full 5 minutes: \(reset)")
    attachScreenshot(of: app, named: "AC-ended-early-reset")
  }

  /// The capsule is the target. A tap near its left edge — about as far from the word as the button
  /// gets — has to start the focus just like a tap on the text.
  func testStartButtonAnswersATapOnItsWholeCapsule() {
    let app = launchApp(PomodoroLaunch.parkedPreview())
    let start = app.first(.button, labelled: "开始专注")
    XCTAssertTrue(start.waitForExistence(timeout: 30), "the child's screen never parked")
    XCTAssertGreaterThan(start.frame.width, 200, "the start button is not the full-width capsule")

    start.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5)).tap()
    XCTAssertTrue(app.first(.button, labelled: "暂停").waitForExistence(timeout: 10),
                  "a tap on the capsule's edge did not start the focus")
    attachScreenshot(of: app, named: "AC-start-whole-capsule")
  }

  /// The countdown the child sees, in whole seconds; -1 when it is not on screen.
  private func countdownSeconds(in app: XCUIApplication) -> Int? {
    let element = app.first(.staticText, labelStartingWith: "剩余 ")
    guard element.exists,
          let clock = element.label.split(separator: " ").last
    else { return nil }
    let parts = clock.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return nil }
    return parts[0] * 60 + parts[1]
  }
}
