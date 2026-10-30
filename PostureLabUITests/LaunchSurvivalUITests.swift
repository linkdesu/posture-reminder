import XCTest

/// 启动存活：0.6.3 的第一版在 `PostureLabApp.init` 里读了 `UIApplication.shared`（此时它还是 nil），
/// 写入 `isIdleTimerDisabled` 时每次启动都 SIGSEGV。单测用的是假实现，测不到这条真实启动路径，所以
/// 这条用例只做一件事：以用户会用的方式启动，等到首帧之后再等几秒，确认进程仍在前台、主页主控件还在。
final class LaunchSurvivalUITests: XCTestCase {

  func testTheAppSurvivesItsLaunch() {
    let app = launchApp(PomodoroLaunch.withoutOverrides)

    // 首帧：主页的「开始专注」出现了，说明 App.init → UIApplicationMain → 首帧这条路径走完。
    XCTAssertTrue(app.first(.button, labelled: "开始专注").waitForExistence(timeout: 30),
                  "启动 30 秒内主页没有出现")

    // 再等几秒，越过启动后第一次空闲计时器同步与首个深度样本；崩溃发生在启动瞬间，这几秒足够复现。
    XCTAssertTrue(wait(upTo: 5, for: { app.state == .runningForeground }),
                  "启动后进程没有留在前台：state = \(app.state.rawValue)")
    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertTrue(app.first(.button, labelled: "开始专注").exists,
                  "进程还在，但主页控件已经不在了")
    attachScreenshot(of: app, named: "launch-survival-main")
  }
}
