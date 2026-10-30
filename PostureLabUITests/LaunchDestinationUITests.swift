import XCTest

/// issue #7 AC4：从桌面图标打开 App 默认进入主页。
///
/// 冷启动已经落在主页（`LaunchSurvivalUITests` 覆盖）。这条用例测的是另一种「打开」：App 被挂起在
/// 设置页或统计页时，家长上滑回桌面、再从桌面图标点回来。用户看到的第一屏必须是番茄钟主页，而不是
/// 离开时那个家长页面——否则孩子拿起手机时面对的是设置项。倒计时不受影响：它按墙钟走。
final class LaunchDestinationUITests: XCTestCase {

  func testReopeningFromTheHomeScreenLandsOnTheChildsScreen() {
    let app = launchApp(PomodoroLaunch.settingsPage)
    XCTAssertTrue(app.first(.button, labelled: "主页").waitForExistence(timeout: 30),
                  "the settings page did not open")
    attachScreenshot(of: app, named: "AC4-settings-before")

    // 回桌面，再从桌面图标点回来——和用户的动作一样，不用 `activate()` 的捷径。
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(wait(upTo: 5, for: { app.state != .runningForeground }),
                  "the app did not go to the background")
    app.activate()

    XCTAssertTrue(app.first(.button, labelled: "设置页").waitForExistence(timeout: 30),
                  "reopening the app did not land on the child's screen")
    XCTAssertTrue(app.first(.button, labelled: "开始专注").exists
                    || app.first(.button, labelled: "暂停").exists,
                  "the child's screen is up but has no countdown controls")
    XCTAssertFalse(app.first(.button, labelled: "主页").exists,
                   "reopening the app kept the settings page on screen")
    attachScreenshot(of: app, named: "AC4-main-after-reopen")
  }

  /// 统计页同理：家长读完统计回到桌面，再点图标，先看到的是孩子的主页。
  func testReopeningFromTheReportLandsOnTheChildsScreen() {
    let app = launchApp(["-seedHistory", "3", "-report", "day"])
    XCTAssertTrue(app.first(.button, labelled: "主页").waitForExistence(timeout: 30),
                  "the report did not open")
    attachScreenshot(of: app, named: "AC4-report-before")

    XCUIDevice.shared.press(.home)
    XCTAssertTrue(wait(upTo: 5, for: { app.state != .runningForeground }),
                  "the app did not go to the background")
    app.activate()

    XCTAssertTrue(app.first(.button, labelled: "设置页").waitForExistence(timeout: 30),
                  "reopening the app did not land on the child's screen")
    XCTAssertFalse(app.first(.button, labelled: "主页").exists,
                   "reopening the app kept the report on screen")
    attachScreenshot(of: app, named: "AC4-main-after-report")
  }
}
