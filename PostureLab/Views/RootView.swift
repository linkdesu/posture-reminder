import SwiftUI

/// Switches the whole app between the screens of `SessionController.Phase`.
///
/// The child's pomodoro screen is the root; the settings page and the parent report are the only
/// other screens, and both are reached from the two icons on it.
struct RootView: View {
  @EnvironmentObject private var controller: SessionController
  /// The scene's own visibility. Reported from here rather than from `PostureLabApp.init` because a
  /// view only exists after `UIApplicationMain`, which is when `UIApplication.shared` exists too.
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Group {
      switch controller.phase {
      case .pomodoro:
        PomodoroView()
          .onAppear { controller.didShow("pomodoro_main") }
      case .pomodoroSettings:
        PomodoroSettingsView()
          .onAppear { controller.didShow("pomodoro_settings") }
      case .report:
        ReportView()
          .onAppear { controller.didShow(reportScreenName) }
      }
    }
    .task {
      // The first report arms the screen rule (and tells it the app is on screen right now).
      controller.scenePhaseChanged(scenePhase)
      controller.autoStartIfSimulating()
    }
    .onChange(of: scenePhase) { _, phase in
      controller.scenePhaseChanged(phase)
    }
  }

  /// The capture script can only identify a screen by the screenshot file its `didShow` writes, and the
  /// report has one screen name per scope, so `-report week` and `-report month` do not overwrite each
  /// other's evidence.
  private var reportScreenName: String {
    switch controller.reportScope {
    case .day: return "report_day"
    case .week: return "report_week"
    case .month: return "report_month"
    }
  }
}
