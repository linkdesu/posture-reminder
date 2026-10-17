import Foundation
import SwiftUI

struct HomeView: View {
  @EnvironmentObject private var controller: SessionController

  var body: some View {
    VStack(spacing: 28) {
      Text("PostureLab")
        .font(.largeTitle.bold())

      placementHint

      Button {
        controller.startReading()
      } label: {
        Text("开始阅读")
          .font(.title2.bold())
          .frame(maxWidth: .infinity)
          .padding(.vertical, 28)
      }
      .buttonStyle(.borderedProminent)

      summaryCard

      HStack(spacing: 16) {
        Button("校准") { controller.showCalibration() }
          .frame(maxWidth: .infinity)
        Button("设置") { controller.showSettings() }
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .controlSize(.large)

      Spacer()
    }
    .padding(24)
  }

  /// The PRD's first user story: how to set the phone up before reading.
  private var placementHint: some View {
    VStack(spacing: 6) {
      Text("手机这样摆")
        .font(.headline)
      Text("把手机支起来，放在面前。让孩子坐正对着手机，书放在中间。")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
  }

  @ViewBuilder private var summaryCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("上次小结")
        .font(.headline)

      if let summary = controller.previousSummary {
        summaryRow("阅读时长", durationText(summary.totalSeconds))
        summaryRow("太近次数", "\(summary.tooCloseCount) 次")
        summaryRow("坐姿良好占比", percentText(summary.goodRatio))
      } else {
        Text("还没有记录")
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
  }

  private func summaryRow(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value).monospacedDigit()
    }
    .font(.subheadline)
  }

  private func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%02d:%02d", total / 60, total % 60)
  }

  private func percentText(_ ratio: Double) -> String {
    "\(Int((ratio * 100).rounded()))%"
  }
}
