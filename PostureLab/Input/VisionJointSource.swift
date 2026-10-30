import CoreVideo
import Foundation
import Vision

/// 前置彩色帧的唯一去处：一次 2D 人体姿态推理，拿回上半身关节，别的什么都不留。
///
/// **彩色帧是借用，不保留。** `joints(in:at:)` 拿到调用方的 `CVPixelBuffer`，交给一个
/// `VNImageRequestHandler` 走完请求，把 observation 翻成纯数据（`VisionPosePoint`）就返回。这个文件
/// 不把缓冲存到 `self` 上、不画、不转 `UIImage`/`CGImage`、不编码、不写盘；调用方（采集源）在返回后
/// 立刻丢掉自己的引用，所以任一时刻最多只有一帧在内存里。仓库的 `scripts/audit-privacy.py` 就是靠
/// 「`VNDetectHumanBodyPose` 只允许出现在本文件」这条白名单守住这个边界的。
///
/// **2D 而不是 3D。** 2D 关节加同帧深度已经能给每个关节一个距离，而 3D 版本更重，对坐姿、下半身被
/// 桌面挡住的孩子没有已证实的收益（ADR-0008）。
///
/// **频率与丢帧。** 彩色流约 30 fps，推理只跑约 10 Hz：距上一次推理不到 `minimumInterval` 的帧直
/// 接丢掉，绝不排队——排队会让画面延迟一秒才更新姿势导演。请求实例复用，不每帧新建。
final class VisionJointSource {
  /// 复用同一个请求。Vision 的请求对象本身不持有图像。
  private let request = VNDetectHumanBodyPoseRequest()
  private let lock = NSLock()
  private var isBusy = false
  private var lastRunAt: TimeInterval = -.greatestFiniteMagnitude
  private var interval: TimeInterval = CaptureLoad.normal.visionInterval

  /// 推理节流：正常 10 Hz，发热降级时 5 Hz（`CaptureLoad`）。改它不影响正在跑的这一次推理。
  var minimumInterval: TimeInterval {
    get {
      lock.lock()
      defer { lock.unlock() }
      return interval
    }
    set {
      lock.lock()
      interval = newValue
      lock.unlock()
    }
  }

  /// 本文件里被问到的关节名与应用的关节名一一对应。只问头、颈、双肩：其余关节这个版本不显示、
  /// 不判定、不进日志。
  private static let jointNames: [(key: VNHumanBodyPoseObservation.JointName, id: JointID)] = [
    (.nose, .nose),
    (.leftEye, .leftEye), (.rightEye, .rightEye),
    (.leftEar, .leftEar), (.rightEar, .rightEar),
    (.neck, .neck),
    (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
  ]

  /// 一帧彩色的推理。忙、或被节流时返回 nil（这一帧被丢掉，不排队）。
  ///
  /// `t` 是这一帧彩色的采集时刻（会话时钟）；结果按同一时刻返回，配对由调用方做。
  func joints(in buffer: CVPixelBuffer, at t: TimeInterval) -> VisionJointFrame? {
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    guard width > 0, height > 0 else { return nil }

    lock.lock()
    let busy = isBusy || t - lastRunAt < interval
    if !busy {
      isBusy = true
      lastRunAt = t
    }
    lock.unlock()
    guard !busy else { return nil }

    defer {
      lock.lock()
      isBusy = false
      lock.unlock()
    }

    // 竖屏缓冲（采集图要的是 90° 旋转 + 镜像）直接 `.up`；设备拒绝旋转时拿到的是横屏缓冲，
    // `.right` 是把它立起来的那 90°。
    let portrait = height >= width
    let orientation: CGImagePropertyOrientation = portrait ? .up : .right
    let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
    let startedAt = ProcessInfo.processInfo.systemUptime
    do {
      try handler.perform([request])
    } catch {
      return VisionJointFrame(t: t, joints: [:], detected: false, rawConfidence: [:],
                              shouldersInvalidated: false,
                              inferenceSeconds: ProcessInfo.processInfo.systemUptime - startedAt)
    }
    let inferenceSeconds = ProcessInfo.processInfo.systemUptime - startedAt

    // 画面里可能不止一个人；取置信度最高的那个观察。
    let observation = (request.results ?? []).max { $0.confidence < $1.confidence }

    var points: [VisionPosePoint] = []
    // 模型给出的原始分数，门槛之前：日志靠它区分「没人」与「被 0.5 过滤掉」。
    var rawConfidence: [String: Double] = [:]
    if let observation {
      for name in Self.jointNames {
        guard let recognized = try? observation.recognizedPoint(name.key) else { continue }
        rawConfidence[name.id.rawValue] = Double(recognized.confidence)
        let image = VisionPoseMapping.imagePoint(x: Double(recognized.location.x),
                                                 y: Double(recognized.location.y),
                                                 portrait: portrait)
        points.append(VisionPosePoint(joint: name.id,
                                      x: image.x,
                                      y: image.y,
                                      confidence: Double(recognized.confidence)))
      }
    }

    let mapped = VisionPoseMapping.joints(from: points)
    return VisionJointFrame(t: t,
                            joints: mapped.joints,
                            detected: observation != nil,
                            rawConfidence: rawConfidence,
                            shouldersInvalidated: mapped.shouldersInvalidated,
                            inferenceSeconds: inferenceSeconds)
  }

  /// 采集停下时清空节流状态，下一次 `start()` 的第一帧不被上一次会话的时间戳挡掉。
  func reset() {
    lock.lock()
    lastRunAt = -.greatestFiniteMagnitude
    isBusy = false
    lock.unlock()
  }
}
