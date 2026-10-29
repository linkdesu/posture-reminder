import XCTest

/// The input edges of the number rows, each driven through the row's own field and keyboard.
///
/// The domain rule: a typed value is clamped into the setting's range, the focus length snaps onto
/// its 5-minute step, and text that is not a usable number leaves the value the row already held.
/// Zero, negatives, oversized values, letters and an empty field are all exercised here; each case
/// starts from the defaults so the same baseline is used every time, and each is photographed.
final class SettingsInputEdgeUITests: XCTestCase {

  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = true
    app = launchApp(PomodoroLaunch.settingsPage)
    XCTAssertTrue(app.first(.button, labelled: "主页").waitForExistence(timeout: 30),
                  "the settings page did not open")
  }

  override func tearDownWithError() throws {
    app = nil
  }

  func testTypingEdgesThroughTheNumberField() {
    resetDefaults()
    let field = app.first(.textField, labelled: "专注时长数值")
    XCTAssertTrue(field.waitForExistence(timeout: 10), "专注时长 has no number field")

    // Zero is pulled up to the lower bound.
    type("0", into: field)
    XCTAssertEqual(value(of: "专注时长"), "5", "zero was not pulled up to 5")
    attachScreenshot(of: app, named: "AC-input-zero")

    // A negative number is not a legal focus length; it lands on the lower bound.
    resetDefaults()
    type("-5", into: field)
    let negative = value(of: "专注时长")
    attachScreenshot(of: app, named: "AC-input-negative")
    XCTAssertEqual(negative, "5", "a negative entry did not land on the lower bound: \(negative)")

    // Text with no number in it is dropped: the row keeps what it had.
    resetDefaults()
    type("abc", into: field)
    let letters = value(of: "专注时长")
    attachScreenshot(of: app, named: "AC-input-nonnumeric")
    XCTAssertEqual(letters, "25", "letters changed the value: \(letters)")

    // A large but parseable number is clamped to the top of the range.
    resetDefaults()
    type("999999", into: field)
    XCTAssertEqual(value(of: "专注时长"), "60", "an oversized entry was not clamped to 60")
    attachScreenshot(of: app, named: "AC-input-huge")

    // A number too large for Int is still digits: its magnitude is past the range, so it clamps
    // to the top of the range instead of keeping the old value.
    resetDefaults()
    type("999999999999999999999", into: field)
    let overflow = value(of: "专注时长")
    attachScreenshot(of: app, named: "AC-input-overflow")
    XCTAssertEqual(overflow, "60", "an overflowing entry was not clamped to 60: \(overflow)")

    // Empty: selecting and deleting the value keeps the old one.
    resetDefaults()
    field.tap()
    field.typeText(XCUIKeyboardKey.delete.rawValue)
    commit()
    let emptied = value(of: "专注时长")
    attachScreenshot(of: app, named: "AC-input-empty")
    XCTAssertEqual(emptied, "25", "an emptied field did not restore the held value: \(emptied)")

    // Leaving the field without typing must not change it.
    resetDefaults()
    field.tap()
    let other = app.first(.textField, labelled: "短休息数值")
    if other.exists {
      other.tap()            // focus moves: the first field commits on blur
      commit()
    }
    let blurred = value(of: "专注时长")
    attachScreenshot(of: app, named: "AC-input-blur-keeps-value")
    XCTAssertEqual(blurred, "25", "leaving the field without typing changed it: \(blurred)")

    // A tap selects the whole value, so the first digit replaces it instead of appending.
    resetDefaults()
    field.tap()
    field.typeText("7")
    commit()
    XCTAssertEqual(value(of: "专注时长"), "5",
                   "typing 7 produced something other than the clamp of 7")
    attachScreenshot(of: app, named: "AC-input-typed-replaces")

    resetDefaults()
  }

  // MARK: - Driving a row

  private func type(_ text: String, into field: XCUIElement) {
    field.tap()
    field.typeText(text)
    commit()
  }

  private func commit() {
    let done = app.first(.button, labelled: "完成")
    if done.waitForExistence(timeout: 5) { done.tap() }
  }

  private func value(of title: String) -> String {
    let field = app.first(.textField, labelled: "\(title)数值")
    guard field.exists, let raw = field.value as? String else {
      XCTFail("\(title) has no number field to read")
      return ""
    }
    return raw
  }

  /// Puts the eleven pomodoro rows back to their defaults so each case starts from 25 minutes.
  private func resetDefaults() {
    let reset = app.first(.button, labelled: "恢复默认设置")
    for _ in 0..<8 where !(reset.exists && reset.isHittable) {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.78))
        .press(forDuration: 0.05,
               thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.46)))
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }
    guard reset.exists else { return }
    reset.tap()
    let confirm = app.first(.button, labelled: "恢复")
    if confirm.waitForExistence(timeout: 5) { confirm.tap() }
    for _ in 0..<8 {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.4))
        .press(forDuration: 0.05,
               thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.9)))
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
  }
}
