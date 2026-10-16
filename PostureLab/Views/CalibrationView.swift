import SwiftUI

struct CalibrationView: View {
  @EnvironmentObject private var controller: SessionController

  var body: some View {
    VStack(spacing: 32) {
      Text("把手机固定好，让孩子坐正，看着书")
        .font(.title3)
        .multilineTextAlignment(.center)

      content

      Spacer()
    }
    .padding(32)
  }

  @ViewBuilder private var content: some View {
    switch controller.calibrationState {
    case .idle:
      Button("开始校准") { controller.beginCalibration() }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

    case .countingDown(let seconds):
      VStack(spacing: 12) {
        Text("\(seconds)")
          .font(.system(size: 96, weight: .bold, design: .rounded))
          .monospacedDigit()
        Text("请坐正，保持不动")
          .foregroundStyle(.secondary)
      }

    case .sampling(let progress):
      VStack(spacing: 12) {
        ProgressView(value: progress)
          .frame(maxWidth: 240)
        Text("正在采集坐姿，保持不动")
          .foregroundStyle(.secondary)
      }

    case .done(let result):
      VStack(spacing: 20) {
        VStack(spacing: 8) {
          Text("校准完成").font(.headline)
          Text("基准距离 \(result.distanceCM, specifier: "%.1f") cm")
          Text("基准俯仰角度 \(result.pitchDeg, specifier: "%.1f")°")
        }
        HStack(spacing: 16) {
          Button("重新校准") { controller.retryCalibration() }
          Button("完成") { controller.acceptCalibration() }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
      }

    case .failed(let message):
      VStack(spacing: 20) {
        Text(message)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
        Button("重新校准") { controller.retryCalibration() }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
      }
    }
  }
}
