import Foundation

/// 一个模型关节，在应用自己的关节空间里：`x`/`y` 归一化 0...1、原点在图像左上、y 向下；
/// `confidence` 是模型自己的分数。
///
/// Vision 的 observation 只活在 `VisionJointSource` 里；这个类型是纯数据缝，单测可以不用相机、
/// 不用照片就构造一帧姿态。
struct VisionPosePoint: Equatable {
  var joint: JointID
  var x: Double
  var y: Double
  var confidence: Double
}

/// 一次推理的结果：只有关节，没有像素。
struct VisionJointFrame: Equatable {
  /// 推理所用彩色帧的采集时刻（会话时钟，秒）。
  var t: TimeInterval
  /// 过了置信度门槛、可以进入判定的关节。
  var joints: [JointID: JointSample]
  /// 模型这一帧是否报出了一个人。为 false 表示「画面里没人」；为 true 而某个关节不在 `joints`
  /// 里，则是「模型看到了、但置信度没过门槛」——两者在日志里必须分得开。
  var detected: Bool
  /// 模型对八个关节给出的**原始**置信度（`0.5` 门槛之前），键是 `JointID.rawValue`；模型没报这个
  /// 关节时该键为 nil。只用来看模型的表现，不参与任何判定。
  var rawConfidence: [String: Double]
  /// 同帧是否找到人脸（`VNDetectFaceLandmarksRequest` 报了一个人脸框）。在场判定的
  /// `.faceEyes` 路径用它：鼻点只是锚点，人脸或双眼才是「这个头真的在」的证据。
  var faceDetected: Bool = false
  /// 嘴的外轮廓（归一化坐标，按轮廓顺序）；同帧找人脸失败时为空。
  var mouth: [CGPointLike] = []
  /// 双肩因为落在鼻以上被整帧作废。真机上这个计数必须为 0。
  var shouldersInvalidated: Bool
  /// 单次推理耗时，秒。
  var inferenceSeconds: Double
}

/// 模型输出到应用关节的映射，全是纯函数。
///
/// 三层规则：
/// 1. **只出上半身的八个关节**——鼻、双眼、双耳、颈、双肩。髋、躯干中点、肘、腕、root 一律不生成，
///    它们只出现在 `unavailable` 里。
/// 2. **置信度门槛**。低于 `minimumConfidence` 的关节当作没测到；`0.5` 是初值，真机再调。
/// 3. **肩不能在头上**。肩点 y 高于鼻点 y 说明模型把耳侧或发际线认成了肩；这一帧的双肩整帧作废，
///    否则肩线倾斜与驼背会拿一个错位的点去提醒孩子。
enum VisionPoseMapping {
  /// 关节置信度门槛的初值。ADR-0008 允许真机校准，改这一处即可。
  static let minimumConfidence = 0.5

  /// 允许进入样本的关节：头（鼻/眼/耳）、颈、双肩。顺序也是调试日志里的顺序。
  static let deliveredJoints: [JointID] = [
    .nose, .leftEye, .rightEye, .leftEar, .rightEar, .neck, .leftShoulder, .rightShoulder,
  ]

  struct Joints: Equatable {
    var joints: [JointID: JointSample]
    /// 双肩被「肩在鼻以上」这条规则整帧作废。
    var shouldersInvalidated: Bool

    static let empty = Joints(joints: [:], shouldersInvalidated: false)
  }

  /// 把一帧模型点转成关节。同名关节出现多次时保留置信度最高的那个。
  static func joints(from points: [VisionPosePoint]) -> Joints {
    var byJoint: [JointID: VisionPosePoint] = [:]
    for point in points
    where deliveredJoints.contains(point.joint) && point.confidence >= minimumConfidence {
      if let existing = byJoint[point.joint], existing.confidence >= point.confidence { continue }
      byJoint[point.joint] = point
    }

    var joints: [JointID: JointSample] = [:]
    for (id, point) in byJoint {
      joints[id] = JointSample(x: point.x, y: point.y, depthM: nil, confidence: point.confidence)
    }

    // 肩 y 大于鼻 y 才是「在鼻以下」（y 向下）。肩点跑到鼻上方，两个肩一起作废：一条只对了一半
    // 的肩线比没有肩线更糟。
    var shouldersInvalidated = false
    if let nose = joints[.nose],
       let left = joints[.leftShoulder], left.y < nose.y
        || joints[.rightShoulder].map({ $0.y < nose.y }) == true {
      joints[.leftShoulder] = nil
      joints[.rightShoulder] = nil
      shouldersInvalidated = true
    }
    return Joints(joints: joints, shouldersInvalidated: shouldersInvalidated)
  }

  /// 嘴的外轮廓，只在同帧人脸框置信度过门槛时交付。
  ///
  /// Vision 的人体姿态没有嘴；嘴来自 `VNDetectFaceLandmarksRequest` 的 outerLips，而面部特征点本身
  /// 不带逐点置信度，所以门槛落在人脸框上。低于 `minimumConfidence` 的人脸不画嘴：宁可缺一个嘴，
  /// 也不把一张误检的脸画成孩子的一部分（issue #6 AC3）。
  static func mouth(points: [CGPointLike], faceConfidence: Double?) -> [CGPointLike] {
    guard let faceConfidence, faceConfidence >= minimumConfidence else { return [] }
    return points
  }

  /// Vision 的归一化点（原点在左下、y 向上）换成应用的关节空间（原点左上、y 向下）。
  ///
  /// `portrait` 说的是模型看到的那帧缓冲的方向。采集图只要求竖屏（旋转 90°、镜像），竖屏缓冲直接
  /// 翻 y；设备拒绝旋转时交给 Vision 的是横屏缓冲加 `.right`，模型的 x 就沿竖屏那条轴走，两个坐标
  /// 互换即可。
  static func imagePoint(x: Double, y: Double, portrait: Bool) -> CGPointLike {
    portrait ? CGPointLike(x: x, y: 1 - y) : CGPointLike(x: y, y: x)
  }

  /// 给每个关节读它在同帧深度图上的距离：取关节周围 ±radius 内、属于人体遮罩的有效深度中位数。
  ///
  /// 只数遮罩内的格子——没有身体的地方不该有距离，遮罩漏掉的胳膊宁可缺测，也不能拿背景的 2 米
  /// 墙当它的距离。`distance` / `head_forward` 靠这个读数，缺了它们会正确缺测。
  static func attachDepth(_ joints: [JointID: JointSample],
                          depth: DepthImage,
                          mask: BodyMask?) -> [JointID: JointSample] {
    guard let mask else { return joints }
    var result = joints
    let radius = max(1, min(3, depth.width / 80))
    for (id, joint) in joints {
      let px = min(depth.width - 1, max(0, Int(joint.x * Double(depth.width))))
      let py = min(depth.height - 1, max(0, Int(joint.y * Double(depth.height))))
      var values: [Float] = []
      for yy in (py - radius)...(py + radius) {
        for xx in (px - radius)...(px + radius)
        where mask.contains(x: xx, y: yy) && depth.isValid(x: xx, y: yy) {
          values.append(depth.value(x: xx, y: yy))
        }
      }
      guard !values.isEmpty else { continue }
      values.sort()
      result[id] = JointSample(x: joint.x,
                               y: joint.y,
                               depthM: Double(values[values.count / 2]),
                               confidence: joint.confidence)
    }
    return result
  }

  /// 横滚的三个来源按顺序取第一个有值的：双眼连线 → 双耳连线 → 深度平面。
  ///
  /// 眼线最准（两眼在脸上对称），耳线次之（耳朵会随头型偏），两者都缺测时才退回深度平面的左右坡度
  /// ——深度平面在头转过去时几乎读不出横滚，所以它只是兜底。关节过期时 `joints` 为空，这里自然只
  /// 剩深度平面。
  static func rollDegrees(_ joints: [JointID: JointSample], fallback: Double?) -> Double? {
    eyeLineDegrees(joints) ?? earLineDegrees(joints) ?? fallback
  }

  /// 双耳连线相对水平线的角度，度；两只耳朵都测到且不在同一点时才有值。
  /// 它是眼线缺测时的第二选择（ADR-0008：眼线 → 耳线 → 深度平面）。
  static func earLineDegrees(_ joints: [JointID: JointSample]) -> Double? {
    lineDegrees(from: joints[.leftEar], to: joints[.rightEar])
  }

  /// 双眼连线相对水平线的角度，度；两只眼睛都测到时才有值。
  static func eyeLineDegrees(_ joints: [JointID: JointSample]) -> Double? {
    lineDegrees(from: joints[.leftEye], to: joints[.rightEye])
  }

  /// 连线相对水平线的角度，折进 (−90°, 90°]。
  ///
  /// 前置摄像头是镜像的（`DepthCaptureSource.orient` 打开 `isVideoMirrored`），左右眼在图像里的 x
  /// 顺序会反过来：坐直时 `dx < 0`，`atan2(≈0, 负数)` 给出 ±180°。0.6.8 (14/15) 直接把这个数当横滚，
  /// 于是「实测 174° − 基线 0°」永远超过 15°，人坐得再直也判歪头（r20 诊断：session 里 88/133 行
  /// 落在 164°–180°）。这里把结果折成与水平线的锐角，180° 归一到 0°，170° 归一到 10°。
  private static func lineDegrees(from left: JointSample?, to right: JointSample?) -> Double? {
    guard let left, let right else { return nil }
    guard hypot(right.x - left.x, right.y - left.y) > 0.01 else { return nil }
    let raw = atan2(right.y - left.y, right.x - left.x) * 180 / .pi
    if raw > 90 { return 180 - raw }
    if raw < -90 { return -180 - raw }
    return raw
  }
}

/// 关节帧与深度帧的配对规则：取时间最近的那一帧深度，差超过 `maximumGap` 就是过期。
///
/// 彩色约 10 Hz、深度约 30 Hz，两者不会同刻到达；关节的位置来自彩色，距离与俯仰来自深度，所以
/// 必须明确「这一帧彩色的深度是哪一帧」。150 ms 是一个深度帧间隔的五倍，超过它再说「同帧」就是
/// 拿孩子的旧姿态配新距离。
enum VisionDepthPairing {
  static let maximumGap: TimeInterval = 0.15

  /// 时间最近的深度帧在 `ticks` 里的下标；空数组返回 nil。
  static func nearestIndex(to t: TimeInterval, ticks: [TimeInterval]) -> Int? {
    var best: (index: Int, gap: TimeInterval)?
    for (index, tick) in ticks.enumerated() {
      let gap = abs(tick - t)
      if best == nil || gap < best!.gap {
        best = (index, gap)
      }
    }
    return best?.index
  }

  /// 一次彩色推理与一次深度样本是否还能配成一帧。
  static func isStale(visionT: TimeInterval, sampleT: TimeInterval) -> Bool {
    abs(sampleT - visionT) > maximumGap
  }
}
