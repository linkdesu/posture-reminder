import Foundation

/// 30 Hz 的点云帧，只喂画布，不进引擎。
///
/// 引擎的状态机是按 10 Hz 调的（暂停 3 秒、越阈 15 秒都按样本时钟读），而画面要的是每一帧深度。
/// 两者分开走：样本带关节与判定输入，点云帧只带点。
struct CloudFrame: Equatable {
  var t: TimeInterval
  var points: [BodyPoint]
}

protocol SampleSource: AnyObject {
  var onSample: ((PostureSample) -> Void)? { get set }
  /// 每个深度帧一次（约 30 Hz）。脚本源没有深度，不发这个回调。
  var onCloud: ((CloudFrame) -> Void)? { get set }
  func start()
  func stop()
}
