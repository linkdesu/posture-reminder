import SwiftUI

/// End-of-session numbers: exactly five, plus a way back home.
struct SummaryView: View {
  @EnvironmentObject private var controller: SessionController

  var body: some View {
    VStack(spacing: 28) {
      Text("本次小结")
        .font(.largeTitle.bold())

      if let summary = controller.lastSummary {
        VStack(spacing: 0) {
          row("阅读时长", durationText(summary.totalSeconds))
          Divider()
          row("太近次数", "\(summary.tooCloseCount) 次")
          Divider()
          row("低头累计时长", durationText(summary.headDownSeconds))
          Divider()
          row("坐姿良好占比", percentText(summary.goodRatio))
          Divider()
          row("最长连续良好时长", durationText(summary.longestGoodStreakSeconds))
        }
        .padding(.horizontal, 20)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
      } else {
        Text("还没有记录")
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        controller.showHome()
      } label: {
        Text("完成")
          .font(.title2.bold())
          .frame(maxWidth: .infinity)
          .padding(.vertical, 20)
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(24)
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value).monospacedDigit()
    }
    .font(.body)
    .padding(.vertical, 16)
  }

  private func durationText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%02d:%02d", total / 60, total % 60)
  }

  private func percentText(_ ratio: Double) -> String {
    "\(Int((ratio * 100).rounded()))%"
  }
}
