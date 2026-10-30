import CoreGraphics
import Foundation

/// Joint names from the Vision 2D pose vocabulary: enough to draw a COCO-style skeleton and enough to
/// derive the proxy measurements the classifier works from.
enum JointID: String, CaseIterable, Equatable {
  case nose, leftEye, rightEye, leftEar, rightEar
  case neck, root
  case leftShoulder, rightShoulder
  case leftElbow, rightElbow
  case leftWrist, rightWrist
  case leftHip, rightHip
}

/// One joint. `x`/`y` are normalized image coordinates (0...1, y downwards), `depthM` is the distance
/// to the camera in metres.
struct JointSample: Equatable {
  var x: Double
  var y: Double
  var depthM: Double?
  var confidence: Double

  var position: CGPoint { CGPoint(x: x, y: y) }
}

/// One coarse depth frame, shaped like what TrueDepth hands us: metres, 0 meaning no reading here.
/// Deliberately coarse (24 by 32) so it is enough to drive the avatar and small enough to sit in
/// memory and in a log summary.
struct DepthFrame: Equatable {
  static let width = 24
  static let height = 32

  /// Row major, `count == width * height`. 0 means no reading.
  var metres: [Float]

  init(metres: [Float]) {
    let cells = Self.width * Self.height
    if metres.count == cells {
      self.metres = metres
    } else {
      // A frame that does not match the grid is padded or cut, so a malformed source can never make
      // a reader walk off the buffer during a session.
      self.metres = Array(metres.prefix(cells)) + [Float](repeating: 0, count: max(0, cells - metres.count))
    }
  }

  /// For when there is no depth stream at all.
  static var empty: DepthFrame { DepthFrame(metres: [Float](repeating: 0, count: width * height)) }

  /// 0 both for a cell outside the grid and for a cell with no reading.
  func value(x: Int, y: Int) -> Float {
    guard (0..<Self.width).contains(x), (0..<Self.height).contains(y) else { return 0 }
    return metres[y * Self.width + x]
  }
}

/// The body geometry one sample produces: the joints a joint source measured, the coarse depth grid,
/// the points sampled straight from the segmented depth frame, and the joints the source could not
/// measure.
struct PoseGeometry: Equatable {
  var joints: [JointID: JointSample]
  var depth: DepthFrame?
  /// Points taken from the depth mask itself. Empty when the source had no depth to sample.
  var cloud: [BodyPoint] = []
  /// Joints the source reported as unmeasurable on this frame; the overlay names them 不可用.
  var unavailableJoints: Set<JointID> = []
  /// 这一帧点云与上一帧之间的实际间隔（秒）。画布的插值用它，而不是写死的 1/30；
  /// 脚本 rig 的样本没有间隔，保持 nil。
  var cloudInterval: TimeInterval? = nil
  /// 嘴的外轮廓（归一化坐标）；没有面部特征时为空。
  var mouth: [CGPointLike] = []
  /// 深度轮廓背景是否开启（设置项，默认开）。
  var outlineEnabled: Bool = true
}
