import XCTest

/// `verify.py drive settings-scroll | settings-toggle | upgrade-063` 的 XCUITest 底层。
///
/// 全量测试里它们也照常跑（legacy 用例没有旧版 App 时跳过）。证据是 `.keepAlways` 附件：
/// verify.py 用 `xcresulttool export attachments` 导出截图与文本，再自己从模拟器读回
/// UserDefaults，确认开关真的写进了存储，而不是只看界面。
final class VerifyDriveUITests: XCTestCase {

  /// 番茄钟设置页的 10 项（`features/pomodoro-settings.md`）；「试听提示音」是按钮，不算设置项。
  static let tenSettings = ["专注时长", "短休息", "长休息", "几个专注后长休息",
                            "自动开始休息", "自动开始下一个专注", "每日目标番茄数", "结束提示音",
                            "姿态语音提醒", "休息时是否监测姿态"]

  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    app = nil
  }

  private func openSettings(_ application: XCUIApplication) {
    app = application
    app.launchArguments = PomodoroLaunch.settingsPage
    app.launch()
    XCTAssertTrue(app.first(.button, labelled: "主页").waitForExistence(timeout: 30),
                  "the settings page did not open")
  }

  /// 滚到设置页下半屏截图，并逐项数出 10 个设置项。
  func testDriveSettingsScrollCountsTenSettings() throws {
    openSettings(XCUIApplication())
    attachScreenshot(of: app, named: "drive-settings-top")
    var found: [String] = []
    for title in Self.tenSettings {
      if reveal(app.first(.any, labelStartingWith: title)) { found.append(title) }
    }
    scrollToBottom()
    attachScreenshot(of: app, named: "drive-settings-bottom")
    let keepAwake = app.first(.any, labelStartingWith: "屏幕常亮").exists
      || app.first(.any, labelStartingWith: "保持屏幕常亮").exists
    attachText("drive-settings-count",
               "count=\(found.count)\nfound=\(found.joined(separator: ","))\nkeepScreenAwakeRow=\(keepAwake)\n")
    XCTAssertEqual(found, Self.tenSettings, "settings page does not show exactly the ten settings")
    XCTAssertFalse(keepAwake, "the removed 屏幕常亮 row is back")
  }

  /// 真点一次「自动开始休息」开关；值是否落进 UserDefaults 由 verify.py 在模拟器外读回。
  func testDriveSettingsToggleFlipsAutoStartBreak() throws {
    openSettings(XCUIApplication())
    let toggle = app.first(.switch, labelStartingWith: "自动开始休息")
    XCTAssertTrue(reveal(toggle), "no 自动开始休息 switch")
    let before = toggle.value as? String
    attachScreenshot(of: app, named: "drive-toggle-before")
    flip(toggle, from: before, named: "自动开始休息")
    let after = toggle.value as? String
    attachScreenshot(of: app, named: "drive-toggle-after")
    attachText("drive-toggle-values", "control=自动开始休息\nbefore=\(before ?? "nil")\nafter=\(after ?? "nil")\n")
    XCTAssertNotEqual(before, after)
    // 让偏好写入落盘再结束，verify.py 随后读回存储。
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    app.terminate()
  }

  /// 升级路径：在已安装的 0.6.3 界面上真点「屏幕常亮」关掉。只有 verify.py 用
  /// `TEST_RUNNER_PL_DRIVE_LEGACY_BUNDLE` 指定、且装的是旧版时才跑，否则跳过。
  func testDriveLegacyKeepScreenAwakeOff() throws {
    guard let bundle = ProcessInfo.processInfo.environment["PL_DRIVE_LEGACY_BUNDLE"], !bundle.isEmpty else {
      throw XCTSkip("legacy upgrade drive only runs from verify.py drive upgrade-063")
    }
    openSettings(XCUIApplication(bundleIdentifier: bundle))
    let toggle = app.first(.switch, labelStartingWith: "屏幕常亮")
    XCTAssertTrue(reveal(toggle), "no 屏幕常亮 switch on the legacy settings page")
    let before = toggle.value as? String
    attachScreenshot(of: app, named: "drive-legacy-keepawake-before")
    if before != "0" { flip(toggle, from: before, named: "屏幕常亮") }
    let after = toggle.value as? String
    attachScreenshot(of: app, named: "drive-legacy-keepawake-after")
    attachText("drive-legacy-values", "control=屏幕常亮\nbefore=\(before ?? "nil")\nafter=\(after ?? "nil")\n")
    XCTAssertEqual(after, "0", "屏幕常亮 is still on")
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    app.terminate()
  }

  // MARK: - Helpers

  private func attachText(_ name: String, _ text: String) {
    let attachment = XCTAttachment(string: text)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

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

  private func scrollToBottom() {
    for _ in 0..<8 {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.85))
        .press(forDuration: 0.05,
               thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.25)))
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
  }

  private var contentArea: CGRect {
    let window = app.frame
    let bar = app.navigationBars.firstMatch
    let top = bar.exists ? bar.frame.maxY : window.minY
    return CGRect(x: window.minX, y: top, width: window.width, height: window.maxY - top)
  }
}
