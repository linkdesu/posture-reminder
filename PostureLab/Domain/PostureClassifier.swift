import Foundation

/// What a calibration measured: the two numbers a baseline is really made of.
struct CalibrationResult: Equatable {
  var distanceCM: Double
  var pitchDeg: Double
}

/// What a verdict is measured against. Calibration itself only ever measures distance and pitch.
struct PostureBaseline: Equatable {
  var distanceCM: Double
  var pitchDeg: Double
  var rollDeg: Double
  var shoulderTiltDeg: Double
  var headHeight: Double        // normalized image y, smaller is higher
  var headDepthM: Double?       // head to camera, metres
  var shoulderWidth: Double     // normalized shoulder width
  var neckToRoot: Double        // normalized neck-to-root distance

  /// Only distance and pitch really come out of calibration; the other body fields come from the
  /// first frame that has body data, which for the rig — and for any session that opens sitting
  /// upright — is its neutral layout. Keeping those numbers here is what stops the rig and the
  /// baseline from drifting apart.
  /// 直立时「肩线中线 − 鼻点」的归一化高度；校准会把它换成孩子自己的中位数。
  static let uprightHeadHeight = 0.22
  static let uprightHeadDepthM = 0.35
  static let uprightShoulderWidth = 0.20
  static let uprightNeckToRoot = 0.20

  static func from(calibration: CalibrationResult) -> PostureBaseline {
    PostureBaseline(distanceCM: calibration.distanceCM,
                    pitchDeg: calibration.pitchDeg,
                    rollDeg: 0,
                    shoulderTiltDeg: 0,
                    headHeight: uprightHeadHeight,
                    headDepthM: uprightHeadDepthM,
                    shoulderWidth: uprightShoulderWidth,
                    neckToRoot: uprightNeckToRoot)
  }
}

/// Pure functions, no state and no clock: everything a verdict needs arrives in the arguments, which
/// is what makes a sample stream replayable.
enum PostureClassifier {
  /// Every feature reading for the sample, whether each posture breaches, and which feature to
  /// highlight.
  static func assess(_ sample: PostureSample,
                     baseline: PostureBaseline,
                     thresholds: PostureThresholds) -> PostureAssessment {
    let readings = read(sample, baseline: baseline, thresholds: thresholds)
    var byFeature: [PostureFeature: FeatureReading] = [:]
    for reading in readings {
      byFeature[reading.feature] = reading
    }
    // A reading that could not be measured is never over threshold, so every kind's verdict is built
    // from these and inherits that rule for free.
    let over = { (feature: PostureFeature) in byFeature[feature]?.isOverThreshold ?? false }

    let pitchDrop = sample.pitchDeg.map { baseline.pitchDeg - $0 }
    let bodyPresent = sample.bodyPresent
    // 肩线不可用时，依赖肩线的体态（高低肩、驼背）一律不判：宁可漏报，也不能拿一条不存在的肩线
    // 去提醒孩子或把时间记成不良。`hasShoulderLine` 同时认「关节缺失」与「来源标成不可用」两种
    // 情况。歪头只读头部横滚，v0.6.3 起不看肩线（见 `PostureKind.requiresShoulderLine`）。
    let shoulderLine = sample.hasShoulderLine

    var breached: [PostureKind: Bool] = [:]
    breached[.near] = over(.distance)
    // 低头 = 深度平面的俯仰越阈 + 头高没有升高（v0.6.8）。俯仰本身来自同一帧深度；头高是第二路
    // 信号，用来否掉「下巴上抬却被读成低头」的误判。头高缺测时它不否决——缺测不等于没低头，而
    // 俯仰已经量到了。
    let headRaised = (byFeature[.headHeightDrop]?.value ?? 0) < 0
    breached[.headDown] = over(.headPitch) && !headRaised
    // 歪头的横滚已在采集侧按 眼线 → 耳线 → 深度平面 选好（`VisionPoseMapping.rollDegrees`），
    // 这里只读结果：三个来源都没有时 rollDeg 为 nil，这一行自然缺测。
    breached[.headTilt] = over(.headRoll)
    breached[.shoulderTilt] = shoulderLine && over(.shoulderTilt)
    // `bodyPresent` gates the whole rule and not just the face-lost branch: without it a child who got
    // up and walked away would be read as leaning on the desk.
    let deepDip = pitchDrop.map { $0 > 2 * thresholds.pitchDeg } ?? false
    breached[.deskLean] = bodyPresent && over(.headHeightDrop) && (deepDip || !sample.facePresent)
    // 托腮不做（ADR-0008 第 7 条）：本轮的关节来源不给出腕关节，`hand_to_face` 永远缺测，这个
    // 体态永远不会越阈。枚举与日志词表保留给历史记录与脚本 rig 的回归用例。
    breached[.chinRest] = over(.handToFace)
    breached[.headForward] = over(.headForward)
    breached[.slouch] = shoulderLine && over(.slouch)

    let dominant = PostureKind.allCases
      .filter { breached[$0] == true }
      .min { $0.priority < $1.priority }

    // Only the dominant posture's own signals compete for the highlight, so the red row always
    // explains the posture that currently wins.
    let highlighted = dominant.flatMap { kind -> PostureFeature? in
      let candidates = breachedFeatures(for: kind).compactMap { byFeature[$0] }.filter { $0.isOverThreshold }
      return candidates.max { $0.severity < $1.severity }?.feature
    }

    return PostureAssessment(readings: readings,
                             breached: breached,
                             dominant: dominant,
                             highlighted: highlighted)
  }

  /// 「头部相对肩线高度」：两肩中线 − 鼻点 y（归一化，正数 = 头比肩线高）。缺肩或缺鼻时 nil。
  /// 校准与判定读的是同一个量，头高不再依赖写死的 0.30。
  static func headHeight(joints: [JointID: JointSample]) -> Double? {
    guard let nose = joints[.nose],
          let left = joints[.leftShoulder], let right = joints[.rightShoulder] else { return nil }
    return (left.y + right.y) / 2 - nose.y
  }

  /// The features a kind's rule reads; the highlight is picked from just these.
  static func breachedFeatures(for kind: PostureKind) -> [PostureFeature] {
    switch kind {
    case .deskLean: return [.headHeightDrop]
    case .near: return [.distance]
    case .headForward: return [.headForward]
    case .slouch: return [.slouch]
    case .headDown: return [.headPitch]
    case .headTilt: return [.headRoll]
    case .shoulderTilt: return [.shoulderTilt]
    case .chinRest: return [.handToFace]
    }
  }

  /// One reading per `PostureFeature`, in `allCases` order.
  private static func read(_ sample: PostureSample,
                           baseline: PostureBaseline,
                           thresholds: PostureThresholds) -> [FeatureReading] {
    let joints = sample.joints
    let nose = joints[.nose]
    var readings: [FeatureReading] = []

    readings.append(sample.distanceCM.map {
      reading(.distance, value: $0, threshold: thresholds.distanceCM, baseline: baseline.distanceCM)
    } ?? missing(.distance, thresholds.distanceCM, baseline: baseline.distanceCM))

    readings.append(sample.pitchDeg.map {
      reading(.headPitch, value: baseline.pitchDeg - $0, threshold: thresholds.pitchDeg, baseline: baseline.pitchDeg)
    } ?? missing(.headPitch, thresholds.pitchDeg, baseline: baseline.pitchDeg))

    readings.append(sample.rollDeg.map {
      reading(.headRoll, value: abs($0 - baseline.rollDeg), threshold: thresholds.rollDeg, baseline: baseline.rollDeg)
    } ?? missing(.headRoll, thresholds.rollDeg, baseline: baseline.rollDeg))

    // The rule compares the shoulder line to the calibrated one, so the reading carries that
    // deviation: the overlay can then read the value straight against its threshold.
    readings.append(shoulderTiltDegrees(joints).map {
      reading(.shoulderTilt,
              value: abs($0 - baseline.shoulderTiltDeg),
              threshold: thresholds.shoulderTiltDeg,
              baseline: baseline.shoulderTiltDeg)
    } ?? missing(.shoulderTilt, thresholds.shoulderTiltDeg, baseline: baseline.shoulderTiltDeg))

    // 头部相对肩线高度：鼻点与两肩中线的归一化距离（正数 = 头比肩线高）。头高不再用写死的 0.30
    // 当基线——那个常数跟孩子坐姿无关，只取决于头在画面里的位置（r20 诊断）。
    let headHeight: Double? = {
      guard let nose,
            let left = joints[.leftShoulder], let right = joints[.rightShoulder] else { return nil }
      return (left.y + right.y) / 2 - nose.y
    }()
    readings.append(headHeight.map {
      reading(.headHeightDrop,
              value: (baseline.headHeight) - $0,
              threshold: thresholds.headHeightDrop,
              baseline: baseline.headHeight)
    } ?? missing(.headHeightDrop, thresholds.headHeightDrop, baseline: baseline.headHeight))

    // The nearest wrist decides: the rule is "any wrist at the face".
    let handToFace = nose.flatMap { nose -> Double? in
      [JointID.leftWrist, .rightWrist]
        .compactMap { joints[$0] }
        .map { hypot($0.x - nose.x, $0.y - nose.y) }
        .min()
    }
    readings.append(handToFace.map {
      reading(.handToFace, value: $0, threshold: thresholds.handToFace, baseline: nil)
    } ?? missing(.handToFace, thresholds.handToFace, baseline: nil))

    // An absent baseline depth is exactly the case where this feature has to stay quiet, so both
    // sides have to be there.
    var headForward: Double?
    if let baseDepth = baseline.headDepthM, let headDepth = nose?.depthM {
      headForward = baseDepth - headDepth
    }
    readings.append(headForward.map {
      reading(.headForward, value: $0, threshold: thresholds.headForwardM, baseline: baseline.headDepthM)
    } ?? missing(.headForward, thresholds.headForwardM, baseline: baseline.headDepthM))

    // Either proxy on its own is enough; the reading reports the larger of the ones that could be
    // measured so the overlay shows what tripped the rule.
    var slouchRatios: [Double] = []
    if let width = normalizedDistance(.leftShoulder, .rightShoulder, in: joints), baseline.shoulderWidth > 0 {
      slouchRatios.append((baseline.shoulderWidth - width) / baseline.shoulderWidth)
    }
    if let length = normalizedDistance(.neck, .root, in: joints), baseline.neckToRoot > 0 {
      slouchRatios.append((baseline.neckToRoot - length) / baseline.neckToRoot)
    }
    readings.append(slouchRatios.max().map {
      reading(.slouch, value: $0, threshold: thresholds.slouchRatio, baseline: nil)
    } ?? missing(.slouch, thresholds.slouchRatio, baseline: nil))

    return readings
  }

  private static func reading(_ feature: PostureFeature,
                              value: Double,
                              threshold: Double,
                              baseline: Double?) -> FeatureReading {
    FeatureReading(feature: feature,
                   value: value,
                   threshold: threshold,
                   baseline: baseline,
                   isMeasured: true,
                   isOverThreshold: feature.isSmallerWorse ? value < threshold : value > threshold,
                   severity: FeatureReading.severity(feature: feature, value: value, threshold: threshold))
  }

  /// A feature whose inputs are missing is never over threshold: the value parks at half the
  /// threshold and the severity at 0, so nothing downstream — overlay, highlight, engine — can read
  /// an absent measurement as a breach.
  private static func missing(_ feature: PostureFeature,
                              _ threshold: Double,
                              baseline: Double?) -> FeatureReading {
    FeatureReading(feature: feature,
                   value: threshold / 2,
                   threshold: threshold,
                   baseline: baseline,
                   isMeasured: false,
                   isOverThreshold: false,
                   severity: 0)
  }

  /// Angle between the shoulder line and the horizontal, in degrees; nil without both shoulders.
  /// A rotated line keeps its length, which is why the slouch proxy uses distances, not this angle.
  private static func shoulderTiltDegrees(_ joints: [JointID: JointSample]) -> Double? {
    guard let left = joints[.leftShoulder], let right = joints[.rightShoulder] else { return nil }
    return atan2(abs(right.y - left.y), abs(right.x - left.x)) * 180 / .pi
  }

  /// Normalized image distance between two joints; nil unless both are present.
  private static func normalizedDistance(_ a: JointID,
                                         _ b: JointID,
                                         in joints: [JointID: JointSample]) -> Double? {
    guard let first = joints[a], let second = joints[b] else { return nil }
    return hypot(first.x - second.x, first.y - second.y)
  }
}
