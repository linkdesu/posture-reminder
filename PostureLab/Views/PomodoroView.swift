import SwiftUI

/// The child's pomodoro screen: the depth-derived point cloud and its vector silhouette fill the
/// ground from launch — before 开始专注 is pressed — the countdown and the phase sit quietly over the
/// empty space above them, and the controls wait at the bottom.
///
/// Nothing here can interrupt. A breaching posture never changes the layout, never takes over the
/// screen and never stops the clock — it only tints the part of the avatar that is in trouble, which
/// `AvatarView` already does. There is no edge border, no flashing, no panel and no modal; the
/// pre-recorded voice and the parent report are where a posture is actually raised.
///
/// With debug mode on, `DebugOverlayView` names every joint and shows the arithmetic behind every
/// feature, so the numbers on screen can be traced to the body they came from.
///
/// The only navigation is the pair of icons at the top trailing edge: the report page (`chart.bar`)
/// and the settings page (`gearshape`). They carry no text, so a child who is not looking for them
/// never notices them, but a parent never has to wait for a pomodoro to end either.
struct PomodoroView: View {
  @EnvironmentObject private var controller: SessionController
  @EnvironmentObject private var settings: Settings
  @EnvironmentObject private var pomodoroSettings: PomodoroSettingsStore

  /// How much of the bottom the controls can take: the home-indicator inset, the bottom padding, the
  /// tall start button, the spacing below it and the secondary row, plus a margin. The debug
  /// overlay's feature table is lifted clear of all of them by this much; the likeness wears the same
  /// inset so both layers still project onto the same joints.
  private static let controlsClearance: CGFloat = 200

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      // The likeness is the ground as soon as the app opens, unless a parent turned 形象模式 off —
      // that switch is the one way to take the mirror away. No camera picture is ever drawn: the
      // cloud comes from the depth mask, and with no body yet the view draws a vector silhouette.
      if settings.avatarEnabled {
        AvatarView(geometry: controller.latestGeometry,
                   assessment: childAssessment)
          .ignoresSafeArea()
          // When the overlay is up it is inset for the controls and the likeness takes the same
          // frame, so the skeleton stays on the body. See `controlsClearance`.
          .padding(.bottom, showsDebugOverlay ? Self.controlsClearance : 0)
          // The drawing has no text of its own; this name lets a test tell 形象模式 on from off
          // without reading pixels.
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("形象预览")
      }

      // Joint data is a parent's view of the measurement, so it sits under the controls and is never
      // a target. It is on whenever debug mode is on; the readings themselves need a running focus,
      // and before one the rows show their formula with a dash.
      if showsDebugOverlay {
        DebugOverlayView(geometry: controller.latestGeometry, assessment: childAssessment)
          .ignoresSafeArea()
          .padding(.bottom, Self.controlsClearance)
          .allowsHitTesting(false)
      }

      if let snapshot = controller.pomodoroSnapshot {
        session(snapshot)
      } else {
        idle
      }

      // Today's progress lives in the top leading corner: the countdown owns the centre and the two
      // icons own the top trailing edge, so this readout competes with neither.
      if let snapshot = controller.pomodoroSnapshot {
        dailyGoal(snapshot)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .allowsHitTesting(false)
      }

      navigation
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
  }

  // MARK: - Display filter

  /// The assessment the child is allowed to see.
  ///
  /// With debug off, an experimental posture is a measurement for the parent's report, not something
  /// a child should meet: clearing `dominant` keeps every part of the likeness calm. The log and the
  /// history still record the posture untouched — this is a display filter and nothing else.
  private var childAssessment: PostureAssessment? {
    guard let assessment = controller.latestAssessment else { return nil }
    guard !settings.debugEnabled, assessment.dominant?.tier == .experimental else {
      return assessment
    }
    var filtered = assessment
    filtered.dominant = nil
    return filtered
  }

  /// Debug mode is the only gate. The skeleton and the formula table are the parent's view of the
  /// measurement, and they are useful before the first focus too — that is where Link checks which
  /// joint every number comes from. The overlay draws nothing until there is geometry to draw.
  private var showsDebugOverlay: Bool { settings.debugEnabled }

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
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 18)
            // The whole capsule is the button. Without this the hit area is the text glyphs only,
            // because a plain button style draws no shape of its own.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
        .accessibilityLabel("开始专注")
      }

      HStack(spacing: 16) {
        if snapshot.isRunning {
          secondary("暂停") { controller.pomodoroCommand(.pause) }
        } else if snapshot.phase != .focus {
          secondary("开始") { controller.pomodoroCommand(.start) }
        }

        // Only a started focus has something to end early; a parked one has no record to abandon.
        // The outcome is still `abandoned` everywhere it is logged or stored — this is the label
        // only, and it lives in `PomodoroCopy` so a rename is one line.
        if snapshot.focusStarted {
          secondary(PomodoroCopy.endFocusEarly) { controller.pomodoroCommand(.abandon) }
        }

        if snapshot.phase != .focus {
          secondary("跳过休息") { controller.pomodoroCommand(.skipBreak) }
        }
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
        // The capsule is the tap target, and it is never smaller than a fingertip.
        .frame(minWidth: 88, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
  }

  // MARK: - Daily goal

  /// Today's completed pomodoros against the parent's daily goal, in the dimmest weight the screen
  /// uses. It is a status line, not a target to chase: it never grows, never colours itself and
  /// never sits where the child's eye has to pass the countdown.
  private func dailyGoal(_ snapshot: PomodoroSnapshot) -> some View {
    Text("今天 \(snapshot.completedToday)/\(pomodoroSettings.settings.dailyGoal)")
      .font(.caption.monospacedDigit())
      .foregroundStyle(.white.opacity(0.4))
      .padding(.top, 18)
      .padding(.leading, 20)
      .shadow(color: .black.opacity(0.6), radius: 6)
      .accessibilityLabel("今日目标 \(snapshot.completedToday) 个，共 \(pomodoroSettings.settings.dailyGoal) 个")
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
        .padding(.bottom, 40)
    }
  }

  // MARK: - Navigation

  /// The screen's only navigation: the report page and the settings page as icons. No text, so the
  /// two words a child would look for never appear; the tap targets stay large enough for an adult.
  private var navigation: some View {
    HStack(spacing: 0) {
      iconButton("chart.bar", label: "统计页") { controller.showReport() }
      iconButton("gearshape", label: "设置页") { controller.showPomodoroSettings() }
    }
    .padding(.top, 4)
    .padding(.trailing, 12)
  }

  /// `label` is the accessibility name, not visible text: the buttons are icons only.
  private func iconButton(_ symbol: String,
                          label: String,
                          action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .shadow(color: .black.opacity(0.6), radius: 6)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
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
