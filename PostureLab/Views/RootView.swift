import SwiftUI

/// Switches the whole app between the five screens of `SessionController.Phase`.
struct RootView: View {
  @EnvironmentObject private var controller: SessionController

  var body: some View {
    Group {
      switch controller.phase {
      case .home:
        HomeView()
          .onAppear { controller.didShow("home") }
      case .calibration:
        CalibrationView()
          .onAppear { controller.didShow("calibration") }
      case .monitoring:
        MonitoringView()
          .onAppear { controller.didShow("monitoring") }
      case .summary:
        SummaryView()
          .onAppear { controller.didShow("summary") }
      case .settings:
        SettingsView()
          .onAppear { controller.didShow("settings") }
      }
    }
    .task { controller.autoStartIfSimulating() }
  }
}
