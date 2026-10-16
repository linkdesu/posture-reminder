import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var controller: SessionController
  @EnvironmentObject private var settings: Settings

  var body: some View {
    NavigationStack {
      Form {
        Section("灵敏度") {
          Picker("灵敏度", selection: $settings.sensitivity) {
            ForEach(Sensitivity.allCases, id: \.self) { sensitivity in
              Text(sensitivity.displayName).tag(sensitivity)
            }
          }
          .pickerStyle(.segmented)
        }

        Section("提醒方式") {
          Picker("提醒方式", selection: $settings.reminderMode) {
            ForEach(ReminderMode.allCases, id: \.self) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
          .pickerStyle(.segmented)
        }

        Section {
          Toggle("调试模式", isOn: $settings.debugEnabled)
        }

        Section {
          Button("重新校准") { controller.showCalibration() }
          Button("返回") { controller.showHome() }
        }
      }
      .navigationTitle("设置")
    }
  }
}
