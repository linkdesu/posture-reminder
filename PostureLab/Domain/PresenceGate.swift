import Foundation

/// 一帧的在场证据路径（逐帧日志 `joints-*.jsonl` 的 `presence_path`）。
enum PresencePath: String {
  /// 头部置信度过门槛，并且同帧**找到人脸**、或双眼都过门槛。
  case faceEyes = "face_eyes"
  /// 头部置信度过门槛，并且颈或双肩至少一个过门槛。
  case neckShoulder = "neck_shoulder"
  /// 这一帧没有可靠的在场证据——只有鼻子也算没有。
  case none = "none"
}

/// 在场判定（0.6.8 (18)）：连续 `streakRequired` 帧有可靠证据才算有人。
///
/// 鼻子是**锚点**，不是证据。一帧算「有人」必须同时满足：
/// - 头部（鼻）置信度 ≥ `VisionPoseMapping.minimumConfidence`，**并且**
/// - 同帧找到人脸、或双眼都过门槛（`.faceEyes`），**或**颈/左肩/右肩至少一个过门槛
///   （`.neckShoulder`）。
///
/// 只有鼻子过门槛的一帧既没有人脸、也没有双眼、也没有颈肩，判 `.none`：此时模型多半只认出了
/// 侧脸的鼻尖，把它当「在场」会让计时在孩子已经离开时继续跑。两条路径都满足时记 `.faceEyes`。
///
/// 连续计数存在的理由：Vision 在近距离会整帧不给 observation，单帧丢失不能当作孩子离开。
struct PresenceGate {
  /// 连续多少帧有证据才算在场。
  static let streakRequired = 3

  private(set) var streak = 0

  /// 已经连续够多帧有证据。
  var isPresent: Bool { streak >= Self.streakRequired }

  /// 这一帧的证据路径，纯函数：`confidence` 是每个关节一帧的置信度，缺键表示这一帧没有这个关节。
  static func path(confidence: [JointID: Double], faceDetected: Bool) -> PresencePath {
    guard passed(.nose, in: confidence) else { return .none }
    if faceDetected || (passed(.leftEye, in: confidence) && passed(.rightEye, in: confidence)) {
      return .faceEyes
    }
    if passed(.neck, in: confidence)
      || passed(.leftShoulder, in: confidence)
      || passed(.rightShoulder, in: confidence) {
      return .neckShoulder
    }
    return .none
  }

  /// 喂一帧，返回这一帧的路径。没有证据的帧把连续计数清零。
  @discardableResult
  mutating func observe(confidence: [JointID: Double], faceDetected: Bool) -> PresencePath {
    let path = Self.path(confidence: confidence, faceDetected: faceDetected)
    streak = path == .none ? 0 : min(Self.streakRequired, streak + 1)
    return path
  }

  /// 相机重开时把计数清掉：上一次会话的连续帧不能算进这一次。
  mutating func reset() {
    streak = 0
  }

  private static func passed(_ joint: JointID, in confidence: [JointID: Double]) -> Bool {
    (confidence[joint] ?? 0) >= VisionPoseMapping.minimumConfidence
  }
}
