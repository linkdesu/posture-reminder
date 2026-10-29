import SwiftUI

/// Switches the whole app between the screens of `SessionController.Phase`.
///
/// The child's pomodoro screen is the root; the settings page and the parent report are the only
/// other screens, and both are reached from the two icons on it.
struct RootView: View {
  @EnvironmentObject private var controller: SessionController

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
    .task { controller.autoStartIfSimulating() }
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
