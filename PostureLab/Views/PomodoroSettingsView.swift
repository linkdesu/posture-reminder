import SwiftUI

/// The twelve pomodoro settings of the north star, in the order of its table.
///
/// Every integer row builds its stepper from `PomodoroSettings.ranges` — the one table
/// `PomodoroSettings.clamped()` also enforces — so the screen can never offer a limit the store
/// would pull back. The view only reads and writes `PomodoroSettingsStore.settings`; clamping,
/// storage and the launch-argument override window all live in the store.
struct PomodoroSettingsView: View {
  @EnvironmentObject private var controller: SessionController
  @EnvironmentObject private var settingsStore: PomodoroSettingsStore

  @State private var confirmingReset = false

  var body: some View {
    NavigationStack {
      Form {
        Section("番茄节奏") {
          IntegerSettingRow(title: "专注时长",
                            unit: "分钟",
                            rangeKey: "focusMinutes",
                            step: 5,
                            value: $settingsStore.settings.focusMinutes)
          IntegerSettingRow(title: "短休息",
                            unit: "分钟",
                            rangeKey: "shortBreakMinutes",
                            value: $settingsStore.settings.shortBreakMinutes)
          IntegerSettingRow(title: "长休息",
                            unit: "分钟",
                            rangeKey: "longBreakMinutes",
                            value: $settingsStore.settings.longBreakMinutes)
          IntegerSettingRow(title: "几个专注后长休息",
                            unit: "个",
                            rangeKey: "focusPerLongBreak",
                            value: $settingsStore.settings.focusPerLongBreak)
        }

        Section("自动开始") {
          Toggle(isOn: $settingsStore.settings.autoStartBreak) {
            settingLabel(title: "自动开始休息",
                         subtitle: "专注结束后自动开始休息")
          }
          Toggle(isOn: $settingsStore.settings.autoStartFocus) {
            settingLabel(title: "自动开始下一个专注",
                         subtitle: "休息结束后自动开始下一个番茄")
          }
        }

        Section("目标与提示") {
          IntegerSettingRow(title: "每日目标番茄数",
                            unit: "个",
                            rangeKey: "dailyGoal",
                            value: $settingsStore.settings.dailyGoal)

          Picker("结束提示音", selection: $settingsStore.settings.endSound) {
            ForEach(EndSound.allCases, id: \.self) { sound in
              Text(Self.soundName(sound)).tag(sound)
            }
          }

          Toggle(isOn: $settingsStore.settings.remindBeforeEnd) {
            settingLabel(title: "结束前提醒",
                         subtitle: "结束前 1 分钟提醒一次")
          }
        }

        Section("姿态提醒") {
          // The switch and the volume slider are one row of the north-star table, so they stay
          // together and the slider greys out instead of disappearing.
          Toggle(isOn: $settingsStore.settings.postureVoiceEnabled) {
            settingLabel(title: "姿态语音提醒",
                         subtitle: "坐姿不对时播放录好的温柔语音，番茄钟不会停")
          }

          HStack(spacing: 12) {
            Text("音量")
              .foregroundStyle(.secondary)
            Slider(value: $settingsStore.settings.postureVoiceVolume, in: 0...1)
              .accessibilityLabel("姿态语音音量")
            Text(volumeText)
              .font(.footnote)
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .frame(width: 44, alignment: .trailing)
          }
          .disabled(!settingsStore.settings.postureVoiceEnabled)

          Toggle(isOn: $settingsStore.settings.monitorDuringBreak) {
            settingLabel(title: "休息时是否监测姿态",
                         subtitle: "休息时也判断坐姿，默认不打扰")
          }
        }

        Section("屏幕") {
          Toggle(isOn: $settingsStore.settings.keepScreenAwake) {
            settingLabel(title: "屏幕常亮",
                         subtitle: "阅读时不让屏幕自动变暗")
          }
        }

        Section {
          Button("恢复默认设置", role: .destructive) { confirmingReset = true }
        }
      }
      .navigationTitle("番茄钟设置")
      .toolbar {
        // The child's screen is the only thing behind this one, so the way back is named after it.
        ToolbarItem(placement: .topBarLeading) {
          Button {
            controller.showPomodoro()
          } label: {
            Label("返回专注", systemImage: "chevron.left")
          }
        }
      }
      .confirmationDialog("恢复默认设置？", isPresented: $confirmingReset, titleVisibility: .visible) {
        Button("恢复", role: .destructive) { settingsStore.reset() }
        Button("取消", role: .cancel) {}
      } message: {
        Text("十二项设置都会回到默认值。")
      }
    }
  }

  private var volumeText: String {
    "\(Int((settingsStore.settings.postureVoiceVolume * 100).rounded()))%"
  }

  /// The three end sounds, named the way the north-star table describes them.
  private static func soundName(_ sound: EndSound) -> String {
    switch sound {
    case .soft: "柔和铃声"
    case .chime: "铃声"
    case EndSound.none: "静音"
    }
  }

  private func settingLabel(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
      Text(subtitle)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }
}

/// One integer setting: a stepper whose limits come from `PomodoroSettings.ranges`, plus the
/// current value so the row reads without touching the control.
///
/// A key that is missing from that table leaves the row out rather than inventing a second set of
/// limits here — `clamped()` would reject anything this screen made up.
private struct IntegerSettingRow: View {
  let title: String
  let unit: String
  let rangeKey: String
  var step: Int = 1
  @Binding var value: Int

  var body: some View {
    if let range = PomodoroSettings.ranges[rangeKey] {
      Stepper(value: $value, in: range, step: step) {
        HStack(spacing: 8) {
          Text(title)
          Spacer(minLength: 8)
          Text("\(value) \(unit)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
