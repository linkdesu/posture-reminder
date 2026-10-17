import SwiftUI

/// Monitoring screen: a minimal readout over pure black, with an edge alert border.
/// Reminders never take over the center of the screen; they are sound plus this border.
struct MonitoringView: View {
  @EnvironmentObject private var controller: SessionController
  @EnvironmentObject private var settings: Settings

  /// Any breaching posture earns the edge alert; `.good` and `.noPerson` do not.
  private var showsAlertBorder: Bool {
    if case .posture = controller.status { return true }
    return false
  }

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      // Board mode is the black background plus the readout below, unchanged from r1.
      if settings.avatarEnabled {
        AvatarView(geometry: controller.latestGeometry, assessment: controller.latestAssessment)
      }

      if settings.debugEnabled {
        DebugOverlayView(geometry: controller.latestGeometry, assessment: controller.latestAssessment)
          .allowsHitTesting(false)
      }

      // Timer, status, paused marker and the exit button stay above the avatar and overlay so
      // nothing the child needs is ever covered. In board mode this is the only content.
      VStack(spacing: 0) {
        exitRow
        Spacer()
        readout
        Spacer()
      }

      if showsAlertBorder {
        Rectangle()
          .strokeBorder(Color.orange, lineWidth: 12)
          .ignoresSafeArea()
          .allowsHitTesting(false)
      }
    }
  }

  private var exitRow: some View {
    HStack {
      Spacer()
      Button("结束") { controller.finishMonitoring() }
        .font(.headline)
        .tint(.orange)
    }
    .padding(.horizontal, 24)
    .padding(.top, 16)
  }

  private var readout: some View {
    VStack(spacing: 16) {
      Text(elapsedText)
        .font(.system(size: 84, weight: .light, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.85))

      Text(controller.status.displayName)
        .font(.title2)
        .foregroundStyle(.white.opacity(0.55))

      if controller.isPaused {
        Text("已暂停")
          .font(.title3.bold())
          .foregroundStyle(.white.opacity(0.85))
      }
    }
  }

  private var elapsedText: String {
    let seconds = max(0, Int(controller.elapsedSeconds))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}
