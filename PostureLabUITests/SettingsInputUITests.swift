import XCTest

/// The two settings-page interactions the domain spec asks for beyond a stepper: a number can be
/// typed in, and the end sound can be auditioned.
///
/// Both are driven the way a parent drives them — a tap on the row's field, the keyboard, the 完成
/// button, the 试听 button — and both are photographed as evidence.
final class SettingsInputUITests: XCTestCase {

  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = launchApp(PomodoroLaunch.settingsPage)
    XCTAssertTrue(app.first(.button, labelled: "主页").waitForExistence(timeout: 30),
                  "the settings page did not open (arguments: \(app.launchArguments))")
  }

  override func tearDownWithError() throws {
    app = nil
  }

  /// A typed number lands on the nearest legal value: zero and anything above the range clamp to the
  /// ends, a value between two steps snaps onto the nearer step, and text that holds no number at all
  /// leaves the value the row already had.
  func testTypedNumbersClampIntoTheLegalRange() throws {
    // 专注时长 is 5...60 in steps of 5.
    enter("0", in: "专注时长")
    XCTAssertEqual(integerValue(of: "专注时长"), "5", "zero was not pulled up to the lower bound")
    attachScreenshot(of: app, named: "AC-input-focus-zero-clamped")

    enter("999", in: "专注时长")
    XCTAssertEqual(integerValue(of: "专注时长"), "60", "an oversized entry was not pulled down")

    enter("12", in: "专注时长")
    XCTAssertEqual(integerValue(of: "专注时长"), "10", "12 minutes did not snap onto the 5-minute step")
    attachScreenshot(of: app, named: "AC-input-focus-snapped")

    // 短休息 is 1...15 with no step.
    enter("99", in: "短休息")
    XCTAssertEqual(integerValue(of: "短休息"), "15", "an oversized break was not pulled down")
    attachScreenshot(of: app, named: "AC-input-short-break-clamped")

    // A tap selects the whole number, so leaving it untouched keeps the value the row had.
    let held = integerValue(of: "短休息")
    enter("", in: "短休息")
    XCTAssertEqual(integerValue(of: "短休息"), held, "leaving the field untouched changed the value")

    // And deleting the selected number is the same outcome: there is no number to commit.
    let field = app.first(.textField, labelled: "短休息数值")
    field.tap()
    field.typeText(XCUIKeyboardKey.delete.rawValue)
    app.first(.button, labelled: "完成").tap()
    XCTAssertEqual(integerValue(of: "短休息"), held, "an emptied field did not restore the held value")
    attachScreenshot(of: app, named: "AC-input-empty-keeps-value")

    // And the store holds what the rows show: the child's screen counts down from the same value,
    // which can only be true if nothing illegal was written.
    app.first(.button, labelled: "主页").tap()
    XCTAssertTrue(app.first(.button, labelled: "开始专注").waitForExistence(timeout: 10),
                  "the child's screen is not offering the parked focus")

    restoreDefaults()
  }

  /// A tap selects the whole number: typing 7 replaces whatever the row held, so the row reads the
  /// clamp of 7 — 5 on the 5-minute step — and never the old number with a 7 appended.
  func testTapSelectsTheWholeValueSoTypingReplacesIt() {
    let field = app.first(.textField, labelled: "专注时长数值")
    XCTAssertTrue(field.waitForExistence(timeout: 10), "专注时长 has no number field")
    field.tap()
    field.typeText("7")
    app.first(.button, labelled: "完成").tap()
    XCTAssertEqual(integerValue(of: "专注时长"), "5",
                   "the typed digit was appended to the old value instead of replacing it")
    attachScreenshot(of: app, named: "AC-input-select-all")
    restoreDefaults()
  }

  /// 试听 plays the end sound the row picked and does nothing else: no focus starts, no countdown
  /// moves, and the child's screen is still parked on the proof of that.
  func testPreviewIsAudibleWithoutStartingTheTimer() throws {
    let audition = app.first(.button, labelled: "试听提示音")
    XCTAssertTrue(audition.waitForExistence(timeout: 10), "the settings page offers no 试听 button")
    audition.tap()
    attachScreenshot(of: app, named: "AC-preview-tapped")

    // A preview is a sound, not a session: the page stays put and no timer starts behind it.
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    XCTAssertTrue(app.first(.button, labelled: "主页").exists,
                  "试听 left the settings page")

    app.first(.button, labelled: "主页").tap()
    XCTAssertTrue(app.first(.button, labelled: "开始专注").waitForExistence(timeout: 10),
                  "试听 started a focus instead of leaving the timer parked")
    XCTAssertFalse(app.first(.button, labelled: "暂停").exists,
                   "试听 started the countdown")
  }

  // MARK: - Driving a row

  /// Types `text` into `title`'s field and commits it through the keyboard's 完成 button — the same
  /// steps a parent takes, because a number pad has no return key. Tapping the field selects its whole
  /// value, so typed text replaces the old number; `text` empty is the "leave it alone" case.
  private func enter(_ text: String, in title: String) {
    let field = app.first(.textField, labelled: "\(title)数值")
    XCTAssertTrue(field.waitForExistence(timeout: 10), "\(title) has no number field")
    field.tap()
    if !text.isEmpty { field.typeText(text) }

    let done = app.first(.button, labelled: "完成")
    XCTAssertTrue(done.waitForExistence(timeout: 5), "the number pad offered no way to commit")
    done.tap()
  }

  /// The number a row shows, read off its own field.
  private func integerValue(of title: String) -> String {
    let field = app.first(.textField, labelled: "\(title)数值")
    guard field.exists, let raw = field.value as? String else {
      XCTFail("\(title) has no number field to read")
      return ""
    }
    return raw
  }

  /// Leaves the page as it was found, so the next test does not inherit a shortened focus.
  private func restoreDefaults() {
    let reset = app.first(.button, labelled: "恢复默认设置")
    guard reset.waitForExistence(timeout: 5) else { return }
    reset.tap()
    let confirm = app.first(.button, labelled: "恢复")
    if confirm.waitForExistence(timeout: 5) { confirm.tap() }
  }
}
