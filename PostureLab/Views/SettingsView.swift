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
          Toggle(isOn: $settings.avatarEnabled) {
            settingLabel(
              title: "形象模式",
              subtitle: "让孩子看到自己的坐姿形象，不显示真实画面"
            )
          }

          Toggle(isOn: $settings.experimentalPostures) {
            settingLabel(
              title: "实验性体态",
              subtitle: "头前伸和驼背只做提示和记录，不发出声音"
            )
          }
        }

        Section {
          Button("重新校准") { controller.showCalibration() }
          Button("返回") { controller.showHome() }
        }
      }
      .navigationTitle("设置")
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
