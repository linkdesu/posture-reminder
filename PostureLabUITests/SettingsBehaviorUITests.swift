import XCTest

/// issue #7 AC1：设置里的纯开关不只是翻转一个开关，而是真的改变番茄钟的行为。
///
/// 开关的「存下来了」由 `SettingsPersistenceUITests` / `SettingsTogglesPersistenceUITests` 覆盖：它们
/// 真点开关、杀进程、重启后逐行读回。这里补的是另一半——点完之后用户看得见的变化，而且只用真实控件
/// 与真实计时：形象模式关掉后主页不再有人形，自动开始休息关掉后专注结束停在休息的「开始」上，自动
/// 开始下一个专注打开后休息结束自己进入下一个专注。
///
/// 姿态语音提醒与休息时是否监测姿态的效果只有声音与日志，界面上没有可读的痕迹，它们由
/// `verify.py` 的脚本场景（`-presetSettings postureVoiceEnabled=0/1`、`monitorDuringBreak=0/1`）
/// 按 `speech_played` 与 `features` 行取证，见 `features/pomodoro-settings.md`。
final class SettingsBehaviorUITests: XCTestCase {

  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = nil
  }

  override func tearDownWithError() throws {
    app = nil
  }

  // MARK: - 形象模式

  /// 形象模式是主页唯一能合上人形的开关：关掉后主页不再画「形象预览」，再打开又回来。番茄钟本身
  /// 不受影响——计时是墙钟，不是画布。
  func testTheAvatarSwitchRemovesAndRestoresTheMirror() {
    let app = launchApp(PomodoroLaunch.settingsPage)
    XCTAssertTrue(openSettings(page: app), "the settings page did not open")

    let avatar = app.first(.switch, labelStartingWith: "形象模式")
    XCTAssertTrue(reveal(avatar, in: app), "no 形象模式 switch on the page")
    if isOn(avatar) {
      flip(avatar, in: app, named: "形象模式")
      XCTAssertFalse(isOn(avatar), "形象模式 did not turn off")
    }
    attachScreenshot(of: app, named: "AC1-avatar-off-settings")

    backToMain(in: app)
    XCTAssertFalse(app.first(.any, labelled: "形象预览").exists,
                   "形象模式 is off but the app still draws the likeness")
    attachScreenshot(of: app, named: "AC1-avatar-off-main")

    // Back on, and the likeness returns without a relaunch.
    app.first(.button, labelled: "设置页").tap()
    XCTAssertTrue(openSettings(page: app))
    XCTAssertTrue(reveal(avatar, in: app))
    flip(avatar, in: app, named: "形象模式")
    XCTAssertTrue(isOn(avatar), "形象模式 did not turn back on")
    backToMain(in: app)

    XCTAssertTrue(wait(upTo: 10, for: { app.first(.any, labelled: "形象预览").exists }),
                  "形象模式 is on but the likeness never came back")
    attachScreenshot(of: app, named: "AC1-avatar-on-main")
  }

  // MARK: - 自动开始休息

  /// 自动开始休息默认开着；关掉之后专注走完只停在休息的开始上，倒计时不再自己走。
  func testTurningOffAutoStartBreakParksTheBreak() {
    // `-focusMinutes 1` is a per-run override: the two switches are toggled rather than the whole
    // page reset, so the short focus the test needs is not thrown away with the other rows.
    let app = launchApp(["-settings", "1", "-focusMinutes", "1", "-shortBreakMinutes", "1"])
    XCTAssertTrue(openSettings(page: app), "the settings page did not open")

    let auto = app.first(.switch, labelStartingWith: "自动开始休息")
    XCTAssertTrue(reveal(auto, in: app), "no 自动开始休息 switch on the page")
    if isOn(auto) { flip(auto, in: app, named: "自动开始休息") }
    XCTAssertFalse(isOn(auto), "自动开始休息 did not turn off")
    attachScreenshot(of: app, named: "AC1-autostartbreak-off")

    backToMain(in: app)
    startFocus(in: app)

    // The one-minute focus runs out on its own; the break it enters must not start.
    XCTAssertTrue(wait(upTo: 100, for: { app.first(.staticText, labelled: "短休息").exists }),
                  "the focus never reached its break")
    XCTAssertTrue(app.first(.button, labelled: "开始").exists,
                  "the break did not offer 开始, so it started itself")
    XCTAssertFalse(app.first(.button, labelled: "暂停").exists,
                   "the break was running although 自动开始休息 is off")
    attachScreenshot(of: app, named: "AC1-break-parked")
    resetToDefaults(in: app)
  }

  // MARK: - 自动开始下一个专注

  /// 自动开始下一个专注打开后，休息走完不等孩子点「开始专注」就进入下一个专注。
  func testTurningOnAutoStartFocusStartsTheNextFocusByItself() {
    let app = launchApp(["-settings", "1", "-focusMinutes", "1", "-shortBreakMinutes", "1"])
    XCTAssertTrue(openSettings(page: app), "the settings page did not open")

    // Both halves of the chain: the break has to start by itself for the next focus to be reached,
    // and the next focus has to start by itself for the test to see it counting.
    for title in ["自动开始休息", "自动开始下一个专注"] {
      let auto = app.first(.switch, labelStartingWith: title)
      XCTAssertTrue(reveal(auto, in: app), "no \(title) switch on the page")
      if !isOn(auto) { flip(auto, in: app, named: title) }
      XCTAssertTrue(isOn(auto), "\(title) did not turn on")
    }
    attachScreenshot(of: app, named: "AC1-autostartfocus-on")

    backToMain(in: app)
    startFocus(in: app)

    // Focus (1 min) → break (1 min) → the next focus starts by itself: it is counting, and it is the
    // second one, so no tap ever reached 开始专注.
    XCTAssertTrue(wait(upTo: 170, for: {
      app.first(.staticText, labelled: "第 2 个").exists
        && app.first(.button, labelled: "暂停").exists
    }), "the next focus never started by itself after the break")
    XCTAssertFalse(app.first(.button, labelled: "开始专注").exists,
                   "the second focus is waiting for a tap instead of counting")
    attachScreenshot(of: app, named: "AC1-next-focus-running")
    // Leave the twenty-five minute defaults behind for whatever runs next.
    resetToDefaults(in: app)
  }

  // MARK: - Navigation

  /// 设置页开着：左上角的「主页」就是它自己的返回键。
  private func openSettings(page: XCUIApplication) -> Bool {
    page.first(.button, labelled: "主页").waitForExistence(timeout: 30)
  }

  private func backToMain(in app: XCUIApplication) {
    app.first(.button, labelled: "主页").tap()
    XCTAssertTrue(wait(upTo: 10, for: {
      app.first(.button, labelled: "设置页").exists
    }), "the child's screen did not come back")
  }

  private func startFocus(in app: XCUIApplication) {
    let start = app.first(.button, labelled: "开始专注")
    XCTAssertTrue(start.waitForExistence(timeout: 10), "the child's screen has no 开始专注")
    start.tap()
    XCTAssertTrue(wait(upTo: 10, for: { app.first(.button, labelled: "暂停").exists }),
                  "tapping 开始专注 did not start the countdown")
  }

  /// Back to the ten settings' defaults through the page's own button, so one test cannot leave a
  /// switch flipped — or a one-minute focus staged by a launch argument — for the next.
  private func resetToDefaults(in app: XCUIApplication) {
    app.first(.button, labelled: "设置页").tap()
    XCTAssertTrue(openSettings(page: app))
    // 恢复默认设置 是整页的最后一行：先滚到底，再按行读。
    for _ in 0..<10 {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.82))
        .press(forDuration: 0.05,
               thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.28)))
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    let reset = app.first(.button, labelled: "恢复默认设置")
    XCTAssertTrue(reveal(reset, in: app, attempts: 30), "no 恢复默认设置 button on the page")
    reset.tap()
    let confirm = app.first(.button, labelled: "恢复")
    XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the reset confirmation did not appear")
    confirm.tap()
    scrollToTop(in: app)
  }

  // MARK: - Controls

  private func isOn(_ control: XCUIElement) -> Bool {
    (control.value as? String) == "1"
  }

  /// Taps a switch's trailing knob (the whole row is the switch, only the knob is reachable through
  /// coordinates) until its value flips.
  private func flip(_ control: XCUIElement, in app: XCUIApplication, named name: String) {
    let before = isOn(control)
    for _ in 0..<3 {
      let frame = control.frame
      app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        .withOffset(CGVector(dx: frame.maxX - 24, dy: frame.midY))
        .tap()
      if wait(upTo: 3, for: { self.isOn(control) != before }) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return
      }
    }
    XCTFail("\(name) did not flip")
  }

  @discardableResult
  private func reveal(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 12) -> Bool {
    for _ in 0..<attempts {
      if element.exists && contentArea(of: app).contains(element.frame) { return true }
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.78))
        .press(forDuration: 0.05,
               thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.46)))
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }
    return element.exists && contentArea(of: app).contains(element.frame)
  }

  private func scrollToTop(in app: XCUIApplication) {
    for _ in 0..<8 {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.46))
        .press(forDuration: 0.05,
               thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.9)))
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
  }

  private func contentArea(of app: XCUIApplication) -> CGRect {
    let window = app.frame
    let bar = app.navigationBars.firstMatch
    let top = bar.exists ? bar.frame.maxY : window.minY
    return CGRect(x: window.minX, y: top, width: window.width, height: window.maxY - top)
  }
}
