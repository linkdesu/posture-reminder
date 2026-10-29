import SwiftUI

/// The eleven pomodoro settings of the domain spec (`GLOSSARY.md`), in the order of its table, plus
/// the monitoring section (sensitivity and the avatar switch) and the debug section (debug mode and
/// the experimental-posture switch).
///
/// Every integer row builds its controls from `PomodoroSettings.ranges` — the one table
/// `PomodoroSettings.clamped()` also enforces — so the screen can never offer a limit the store
/// would pull back. Each row takes a number typed in as well as a stepper, and both write through
/// `PomodoroSettings.clamp(_:for:)`: a typed value out of range lands on the nearest legal value and
/// a value that is not a number at all is dropped in favour of the one the row already held.
///
/// The pomodoro rows only read and write `PomodoroSettingsStore.settings`; clamping, storage and the
/// launch-argument override window all live in the store. The debug row reads `Settings.debugEnabled`,
/// the same switch the debug overlay uses.
struct PomodoroSettingsView: View {
  @EnvironmentObject private var controller: SessionController
  @EnvironmentObject private var settingsStore: PomodoroSettingsStore
  @EnvironmentObject private var settings: Settings

  @State private var confirmingReset = false

  var body: some View {
    NavigationStack {
      Form {
        Section("番茄节奏") {
          IntegerSettingRow(title: "专注时长",
                            unit: "分钟",
                            rangeKey: "focusMinutes",
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

          // Auditions the sound the row above picks. It is the settings' own switch being heard, so
          // it neither starts a focus nor writes a `cue_played` line; 静音 has nothing to play.
          Button {
            controller.previewEndSound()
          } label: {
            Label("试听提示音", systemImage: "speaker.wave.2")
          }
          .disabled(settingsStore.settings.endSound == .none)
          .accessibilityLabel("试听提示音")
        }

        Section("姿态提醒") {
          // The switch and the volume slider are one row of the settings spec, so they stay
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

        Section("监测") {
          Picker("灵敏度", selection: $settings.sensitivity) {
            ForEach(Sensitivity.allCases, id: \.self) { sensitivity in
              Text(sensitivity.displayName).tag(sensitivity)
            }
          }
          .pickerStyle(.segmented)

          Toggle(isOn: $settings.avatarEnabled) {
            settingLabel(title: "形象模式",
                         subtitle: "显示由深度数据生成的人形点云；关闭后隐藏，画面只在本机显示、不保存不上传")
          }
        }

        Section("屏幕") {
          Toggle(isOn: $settingsStore.settings.keepScreenAwake) {
            settingLabel(title: "屏幕常亮",
                         subtitle: "阅读时不让屏幕自动变暗")
          }
        }

        Section("调试") {
          // The same app-level switch the overlay reads. Off by default in a release build, so the
          // child never sees joint data or an experimental posture unless a parent turns it on; a
          // debug build ships with it on and keeps the switch.
          Toggle(isOn: $settings.debugEnabled) {
            settingLabel(title: "调试模式",
                         subtitle: "开启后显示带关节名的骨架、每个指标的算法来源与实验性体态")
          }

          // Experimental postures are a parent/QA concern, so the switch lives inside the debug
          // section rather than among the child's settings.
          Toggle(isOn: $settings.experimentalPostures) {
            settingLabel(title: "实验性体态",
                         subtitle: "头前伸和驼背只做记录与调试高亮，不发出声音")
          }
        }

        Section {
          Button("恢复默认设置", role: .destructive) { confirmingReset = true }
        }
      }
      .navigationTitle("设置页")
      .toolbar {
        // The child's screen is the only thing behind this one, so the way back is named after it.
        ToolbarItem(placement: .topBarLeading) {
          Button {
            controller.showPomodoro()
          } label: {
            Label("主页", systemImage: "chevron.left")
          }
        }
        // The way back to the child's screen. A typed number's way out lives on the field's own
        // keyboard accessory: its first responder is a UIKit field, which a SwiftUI keyboard
        // toolbar does not follow.
      }
      .confirmationDialog("恢复默认设置？", isPresented: $confirmingReset, titleVisibility: .visible) {
        Button("恢复", role: .destructive) { settingsStore.reset() }
        Button("取消", role: .cancel) {}
      } message: {
        Text("十一项番茄钟设置都会回到默认值；灵敏度、形象模式与调试开关不受影响。")
      }
    }
  }

  private var volumeText: String {
    "\(Int((settingsStore.settings.postureVoiceVolume * 100).rounded()))%"
  }

  /// The three end sounds, named the way `GLOSSARY.md` describes them.
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

/// One integer setting: the current value as an editable number, its unit, and a stepper beside it.
///
/// The range and the step both come from `PomodoroSettings` — the same table and the same clamp the
/// store enforces — so a typed value, a stepped one and a stored one are all the same numbers. A key
/// that is missing from that table leaves the row out rather than inventing a second set of limits
/// here.
private struct IntegerSettingRow: View {
  let title: String
  let unit: String
  let rangeKey: String
  @Binding var value: Int

  /// What the field shows while it is being edited. It is the source of the value only on commit;
  /// until then the stored `value` is untouched.
  @State private var text = ""
  @State private var isEditing = false

  var body: some View {
    if let range = PomodoroSettings.ranges[rangeKey] {
      HStack(spacing: 8) {
        Text(title)
        Spacer(minLength: 8)
        SelectAllNumberField(text: $text,
                             isEditing: $isEditing,
                             accessibilityLabel: "\(title)数值",
                             onCommit: commit)
          .frame(width: 56)
        Text(unit)
          .foregroundStyle(.secondary)
        Stepper("", value: $value, in: range, step: PomodoroSettings.step(for: rangeKey))
          .labelsHidden()
          .fixedSize()
      }
      .onAppear { text = String(value) }
      .onChange(of: value) { _, newValue in
        // A stepper press or a restored default is the value now; the field follows unless the child
        // is in the middle of typing a different one.
        guard !isEditing else { return }
        text = String(newValue)
      }
    }
  }

  /// Writes the typed number through the same clamp the store uses, then puts the legal value back on
  /// screen. Text that holds no number is dropped: the row keeps the value it already had.
  private func commit(_ typed: String) {
    if let next = PomodoroSettings.value(fromManualEntry: typed, for: rangeKey) {
      value = next
    }
    text = String(value)
  }
}
