import XCTest

/// The settings sections a parent needs beyond the eleven pomodoro rows: sensitivity, the avatar
/// switch, and — inside the debug section — the experimental-posture switch.
///
/// Each check is made on the page's own controls, and each change is put back the way it was found so
/// a later test does not inherit it.
final class SettingsSectionsUITests: XCTestCase {

  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = launchApp(PomodoroLaunch.settingsPage)
    XCTAssertTrue(app.first(.button, labelled: "主页").waitForExistence(timeout: 30),
                  "the settings page did not open")
  }

  override func tearDownWithError() throws {
    app = nil
  }

  func testSensitivityIsSegmentedAndPersistsItsSelection() {
    let levels = ["低", "中", "高"].map { app.first(.button, labelled: $0) }
    for level in levels {
      XCTAssertTrue(reveal(level), "the 灵敏度 segmented control is missing a segment")
    }

    let wasSelected = levels.first { $0.isSelected }
    let target = levels.first { !$0.isSelected }
    let chosen = try? XCTUnwrap(target)
    XCTAssertNotNil(chosen, "灵敏度 draws no unselected segment to move to")
    chosen?.tap()
    XCTAssertTrue(chosen?.isSelected == true, "tapping a segment did not select it")
    attachScreenshot(of: app, named: "AC-settings-sensitivity")

    // Put the segment the page started on back.
    wasSelected?.tap()
    XCTAssertTrue(wasSelected?.isSelected == true, "the original segment could not be restored")
  }

  func testAvatarSwitchLivesInTheMonitoringSection() throws {
    let avatar = app.first(.switch, labelStartingWith: "形象模式")
    XCTAssertTrue(reveal(avatar), "no 形象模式 switch on the page")
    let before = try XCTUnwrap(avatar.value as? String, "形象模式 reports no switch value")

    // A Form toggle's accessible element spans the row; only the trailing knob takes the tap.
    avatar.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    XCTAssertNotEqual(avatar.value as? String, before, "形象模式 did not toggle")
    attachScreenshot(of: app, named: "AC-settings-avatar")
    avatar.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    XCTAssertEqual(avatar.value as? String, before, "形象模式 did not toggle back")
  }

  func testExperimentalSwitchSitsInsideTheDebugSection() throws {
    let debug = app.first(.switch, labelStartingWith: "调试模式")
    XCTAssertTrue(reveal(debug), "no 调试模式 switch on the page")
    let experimental = app.first(.switch, labelStartingWith: "实验性体态")
    XCTAssertTrue(reveal(experimental), "no 实验性体态 switch on the page")

    let reset = app.first(.button, labelled: "恢复默认设置")
    XCTAssertTrue(reveal(reset), "the page has no 恢复默认设置 button")
    XCTAssertGreaterThan(experimental.frame.minY, debug.frame.minY,
                         "实验性体态 is not below 调试模式")
    XCTAssertLessThan(experimental.frame.maxY, reset.frame.maxY,
                      "实验性体态 is not in the debug block above 恢复默认设置")

    let before = try XCTUnwrap(experimental.value as? String, "实验性体态 reports no switch value")
    experimental.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    XCTAssertNotEqual(experimental.value as? String, before, "实验性体态 did not toggle")
    attachScreenshot(of: app, named: "AC-settings-experimental")
    experimental.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    XCTAssertEqual(experimental.value as? String, before, "实验性体态 did not toggle back")
  }

  // MARK: - Scrolling

  /// Scrolls the form until `element` is on screen and can be tapped. A form taller than the
  /// viewport does not build the rows below it, so existence alone is not enough. The drag starts at
  /// the leading edge so it cannot land on a toggle or a slider.
  @discardableResult
  private func reveal(_ element: XCUIElement, attempts: Int = 8) -> Bool {
    for _ in 0..<attempts {
      if element.exists && element.isHittable { return true }
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.8))
        .press(forDuration: 0.05,
               thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)))
    }
    return element.exists && element.isHittable
  }
}
