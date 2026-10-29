import XCTest

/// The monitoring and debug controls on the settings page, driven like a parent drives them.
///
/// 灵敏度 is a segmented control, and 形象模式, 调试模式 and 实验性体态 are switches. Each is
/// photographed before and after its real tap, then the app is killed and started again with no
/// launch argument: the page has to come back showing what was set. The test also records the
/// page's accessibility tree so the number of rows it actually draws can be counted from evidence.
final class SettingsTogglesPersistenceUITests: XCTestCase {

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

  func testMonitoringAndDebugControlsSurviveARelaunch() throws {
    recordTree(named: "settings-accessibility-tree-before")

    scrollToTop()

    // 灵敏度: whatever it starts on, move to another segment and remember the target.
    let levels = ["低", "中", "高"].map { app.first(.button, labelled: $0) }
    for level in levels {
      XCTAssertTrue(reveal(level), "the 灵敏度 segmented control is missing a segment")
    }
    let chosen = try XCTUnwrap(levels.first { !$0.isSelected },
                               "灵敏度 offers no segment to move to")
    attachScreenshot(of: app, named: "AC-setting-sensitivity-before")
    chosen.tap()
    XCTAssertTrue(wait(upTo: 5, for: { chosen.isSelected }),
                  "tapping \(chosen.label) did not select it")
    attachScreenshot(of: app, named: "AC-setting-sensitivity-after")

    // The three switches.
    let avatar = app.first(.switch, labelStartingWith: "形象模式")
    XCTAssertTrue(reveal(avatar), "no 形象模式 switch on the page")
    let avatarBefore = avatar.value as? String
    attachScreenshot(of: app, named: "AC-setting-avatar-before")
    flip(avatar, from: avatarBefore, named: "形象模式")
    attachScreenshot(of: app, named: "AC-setting-avatar-after")
    let avatarAfter = avatar.value as? String
    XCTAssertNotEqual(avatarAfter, avatarBefore, "形象模式 did not change")

    let debug = app.first(.switch, labelStartingWith: "调试模式")
    XCTAssertTrue(reveal(debug), "no 调试模式 switch on the page")
    let debugBefore = debug.value as? String
    attachScreenshot(of: app, named: "AC-setting-debug-before")
    flip(debug, from: debugBefore, named: "调试模式")
    attachScreenshot(of: app, named: "AC-setting-debug-after")
    let debugAfter = debug.value as? String
    XCTAssertNotEqual(debugAfter, debugBefore, "调试模式 did not change")

    let experimental = app.first(.switch, labelStartingWith: "实验性体态")
    XCTAssertTrue(reveal(experimental), "no 实验性体态 switch on the page")
    let experimentalBefore = experimental.value as? String
    attachScreenshot(of: app, named: "AC-setting-experimental-before")
    flip(experimental, from: experimentalBefore, named: "实验性体态")
    attachScreenshot(of: app, named: "AC-setting-experimental-after")
    let experimentalAfter = experimental.value as? String
    XCTAssertNotEqual(experimentalAfter, experimentalBefore, "实验性体态 did not change")

    recordTree(named: "settings-accessibility-tree-after")

    // Let the preferences write land, then kill the process. No launch argument opens the settings
    // page on the way back, so every value has to come out of storage.
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    app.terminate()
    app.launchArguments = PomodoroLaunch.withoutOverrides
    app.launch()

    let gear = app.first(.button, labelled: "设置页")
    XCTAssertTrue(gear.waitForExistence(timeout: 30), "the child's screen never offered 设置页")
    gear.tap()
    XCTAssertTrue(app.first(.button, labelled: "主页").waitForExistence(timeout: 10),
                  "the settings page did not come back after the relaunch")

    scrollToTop()
    let levelsAgain = ["低", "中", "高"].map { app.first(.button, labelled: $0) }
    for level in levelsAgain {
      XCTAssertTrue(reveal(level), "a 灵敏度 segment is missing after the relaunch")
    }
    XCTAssertTrue(levelsAgain.first { $0.label == chosen.label }?.isSelected == true,
                  "灵敏度 did not keep \(chosen.label)")

    for (name, control, expected) in [
      ("形象模式", avatar, avatarAfter),
      ("调试模式", debug, debugAfter),
      ("实验性体态", experimental, experimentalAfter)
    ] {
      XCTAssertTrue(reveal(control), "\(name) is missing after the relaunch")
      XCTAssertEqual(control.value as? String, expected, "\(name) did not survive the relaunch")
    }
    attachScreenshot(of: app, named: "AC-setting-after-relaunch")
    recordTree(named: "settings-accessibility-tree-relaunch")
  }

  // MARK: - Evidence

  private func recordTree(named name: String) {
    let attachment = XCTAttachment(string: app.debugDescription)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  // MARK: - Toggling

  private func flip(_ control: XCUIElement, from before: String?, named name: String) {
    for _ in 0..<3 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
      let frame = control.frame
      app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        .withOffset(CGVector(dx: frame.maxX - 24, dy: frame.midY))
        .tap()
      if wait(upTo: 3, for: { (control.value as? String) != before }) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        return
      }
    }
    XCTFail("\(name) did not toggle away from \(before ?? "nil")")
  }

  // MARK: - Scrolling

  @discardableResult
  private func reveal(_ element: XCUIElement, attempts: Int = 12) -> Bool {
    for _ in 0..<attempts {
      if element.exists && contentArea.contains(element.frame) { return true }
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.78))
        .press(forDuration: 0.05,
               thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.46)))
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }
    return element.exists && contentArea.contains(element.frame)
  }

  private func scrollToTop() {
    for _ in 0..<6 {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.46))
        .press(forDuration: 0.05,
               thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.9)))
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
  }

  private var contentArea: CGRect {
    let window = app.frame
    let bar = app.navigationBars.firstMatch
    let top = bar.exists ? bar.frame.maxY : window.minY
    return CGRect(x: window.minX, y: top, width: window.width, height: window.maxY - top)
  }
}
