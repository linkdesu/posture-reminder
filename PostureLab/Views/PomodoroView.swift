import SwiftUI

/// The child's pomodoro screen: the point-cloud likeness fills the ground, the countdown and the
/// phase sit quietly over the empty space above it, and the three controls wait at the bottom.
///
/// Nothing here can interrupt. A breaching posture never changes the layout, never takes over the
/// screen and never stops the clock — it only tints the part of the avatar that is in trouble, which
/// `AvatarView` already does. There is no edge border, no flashing, no panel and no modal; the
/// pre-recorded voice and the parent report are where a posture is actually raised.
///
/// The settings and the report do have a way in from here, because an installed app has no other:
/// two quiet text buttons that exist only before the first focus has run, so the screen is bare of
/// anything pressable for the whole of every focus. See `showsSetupEntries`.
struct PomodoroView: View {
  @EnvironmentObject private var controller: SessionController

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      // The likeness is the ground of the screen, not a card inside a layout. It also draws the
      // quiet placeholder while there is no geometry yet, so the ground never turns into a blank
      // warning.
      AvatarView(geometry: controller.latestGeometry, assessment: controller.latestAssessment)
        .ignoresSafeArea()

      if let snapshot = controller.pomodoroSnapshot {
        session(snapshot)
      } else {
        idle
      }
    }
  }

  // MARK: - Session

  private func session(_ snapshot: PomodoroSnapshot) -> some View {
    VStack(spacing: 0) {
      header(snapshot)
      Spacer(minLength: 0)
      countdown(snapshot)
      controls(snapshot)
    }
    .padding(.horizontal, 24)
    .padding(.top, 16)
    .padding(.bottom, 28)
  }

  private func header(_ snapshot: PomodoroSnapshot) -> some View {
    VStack(spacing: 4) {
      Text(phaseName(snapshot.phase))
        .font(.headline)
        .foregroundStyle(.white.opacity(0.85))
      Text(indexText(snapshot))
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.45))
    }
    .shadow(color: .black.opacity(0.7), radius: 8)
  }

  private func countdown(_ snapshot: PomodoroSnapshot) -> some View {
    Text(countdownText(snapshot))
      .font(.system(size: 68, weight: .light, design: .rounded))
      .monospacedDigit()
      // Dimming is the only response to a stopped clock; nothing moves, so nothing flashes.
      .foregroundStyle(.white.opacity(snapshot.isRunning ? 0.92 : 0.6))
      .lineLimit(1)
      .minimumScaleFactor(0.6)
      .shadow(color: .black.opacity(0.7), radius: 10)
      .padding(.bottom, 24)
      .accessibilityLabel("剩余 \(countdownText(snapshot))")
  }

  private func controls(_ snapshot: PomodoroSnapshot) -> some View {
    VStack(spacing: 20) {
      // A focus that is not running gets one large way back in; a paused focus resumes through the
      // same command, so the child never has to pick between "start" and "resume".
      if snapshot.phase == .focus, !snapshot.isRunning {
        Button {
          controller.pomodoroCommand(.start)
        } label: {
          Text("开始专注")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
      }

      HStack(spacing: 16) {
        if snapshot.isRunning {
          secondary("暂停") { controller.pomodoroCommand(.pause) }
        } else if snapshot.phase != .focus {
          secondary("开始") { controller.pomodoroCommand(.start) }
        }

        // A break is not a pomodoro in flight; abandoning belongs to the focus clock only.
        if snapshot.phase == .focus {
          secondary("放弃") { controller.pomodoroCommand(.abandon) }
        }

        if snapshot.phase != .focus {
          secondary("跳过休息") { controller.pomodoroCommand(.skipBreak) }
        }
      }

      // Only before the first focus: after that this row is gone, so the bottom of the screen holds
      // the clock's controls and nothing else. See `showsSetupEntries`.
      if showsSetupEntries {
        setupEntries
      }
    }
  }

  private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.callout)
        .foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
  }

  // MARK: - Idle

  /// No snapshot means pomodoro mode is not live yet. Stay quiet and show nothing that could be
  /// pressed to no effect.
  private var idle: some View {
    VStack {
      Spacer()
      Text("番茄钟待命中")
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.35))
        .padding(.bottom, showsSetupEntries ? 16 : 40)
      if showsSetupEntries {
        setupEntries
          .padding(.bottom, 28)
      }
    }
  }

  // MARK: - Setup entries

  /// Whether the settings and the report are reachable from this screen.
  ///
  /// A fresh install has no other route to either, so they have to be here; but the north star is
  /// that the child's screen carries nothing that could pull them out of a focus, so the pair is
  /// offered only while there is nothing to protect — before the first focus has run at all, which is
  /// `nil` (no timer yet), or a timer that has not started, is still on the first focus and has
  /// completed none today. Once a focus has run, they stay hidden for good: during and after one the
  /// screen is the cloud, the countdown and the controls and nothing else.
  private var showsSetupEntries: Bool {
    guard let snapshot = controller.pomodoroSnapshot else { return true }
    return !snapshot.isRunning && snapshot.focusIndex == 1 && snapshot.completedToday == 0
  }

  /// Two quiet text buttons rather than a bar, so the way out is there when it is looked for and
  /// invisible to the child who is not looking for it.
  private var setupEntries: some View {
    HStack(spacing: 16) {
      setupEntry("设置") { controller.showPomodoroSettings() }
      setupEntry("报告") { controller.showReport() }
    }
  }

  private func setupEntry(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.35))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Text

  private func phaseName(_ phase: PomodoroPhase) -> String {
    switch phase {
    case .focus: return "专注"
    case .shortBreak: return "短休息"
    case .longBreak: return "长休息"
    }
  }

  /// Which pomodoro this is. During a break the engine's index is the focus just finished.
  private func indexText(_ snapshot: PomodoroSnapshot) -> String {
    if snapshot.phase == .focus {
      return "第 \(snapshot.focusIndex) 个"
    }
    return "第 \(snapshot.focusIndex) 个已完成"
  }

  /// A countdown rounds up, so the last second reads 00:01 rather than showing zero early.
  private func countdownText(_ snapshot: PomodoroSnapshot) -> String {
    let total = max(0, Int(snapshot.remainingSeconds.rounded(.up)))
    return String(format: "%02d:%02d", total / 60, total % 60)
  }
}
