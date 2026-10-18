import SwiftUI

/// End-of-session numbers: the five headline figures, the count and accumulated duration of each
/// posture that can speak, and at most one line for the experimental tier.
struct SummaryView: View {
  @EnvironmentObject private var controller: SessionController

  /// The postures that own a voice line, in `PostureKind.priority` order. The experimental tier
  /// never speaks, so it gets no detail row here — it is folded into the single line below.
  private static let voicingKinds = PostureKind.allCases
    .filter { $0.voiceLine != nil }
    .sorted { $0.priority < $1.priority }

  var body: some View {
    VStack(spacing: 28) {
      Text("这次小结")
        .font(.largeTitle.bold())

      ScrollView {
        VStack(spacing: 20) {
          if let summary = controller.lastSummary {
            headlineNumbers(summary)
            postureDetail(summary)

            // One line, not a row per posture: those kinds never speak by default, and without
            // this a parent reads "no reminders but many violations" as a contradiction.
            if summary.experimentalEpisodes > 0 {
              Text("另有 \(summary.experimentalEpisodes) 次实验性体态（头前伸、驼背），默认只记录不发声")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
          } else {
            Text("还没有记录")
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity)
      }

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

  /// The five numbers the summary has always shown.
  private func headlineNumbers(_ summary: SessionSummary) -> some View {
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
  }

  /// How often each speaking posture breached, and how long it was held in total.
  private func postureDetail(_ summary: SessionSummary) -> some View {
    VStack(spacing: 0) {
      ForEach(Array(Self.voicingKinds.enumerated()), id: \.element) { index, kind in
        if index > 0 { Divider() }
        let stat = summary.stat(kind)
        HStack {
          Text(kind.displayName)
          Spacer()
          Text("\(stat.episodes) 次 · \(durationText(stat.seconds))").monospacedDigit()
        }
        .font(.subheadline)
        .padding(.vertical, 12)
      }
    }
    .padding(.horizontal, 20)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
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
