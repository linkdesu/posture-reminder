import CoreVideo
import Foundation
import Vision

/// Joints estimated by Vision's 2D human body pose model, with each joint's distance read off the
/// depth frame captured alongside it.
///
/// **The colour frame is borrowed, never kept.** `estimate(from:colour:)` receives the pixel buffer,
/// hands it to one `VNImageRequestHandler`, converts the observation into plain `VisionPosePoint`
/// values and returns. Nothing in this file stores the buffer on `self`, draws it, copies it into an
/// image, encodes it or writes it anywhere; the capture source drops its own reference as soon as the
/// call returns. The body mask, the point cloud and the avatar still come from the depth frame alone
/// (`DepthSegmentation` / `DepthCloud` through `VisionPoseMapping`), so no colour pixel can reach the
/// screen or the log.
///
/// The model is the 2D one on purpose: 2D joints plus an aligned depth map give every joint a
/// distance without trusting a monocular 3D regression on a seated child, and they are the joints the
/// classifier and the overlay were written against.
final class VisionJointSource: JointSource {
  let identifier = "vision-pose"

  func estimate(from depth: DepthImage) -> JointEstimate {
    // A pose model needs pixels. Without them this frame can still show the depth silhouette, which
    // is exactly the point cloud and mask the depth build would have produced, and no joints.
    VisionPoseMapping.estimate(points: [], depth: depth)
  }

  func estimate(from depth: DepthImage, colour: CVPixelBuffer?) -> JointEstimate {
    guard let colour else { return estimate(from: depth) }
    return VisionPoseMapping.estimate(points: joints(in: colour), depth: depth)
  }

  /// Runs the pose request once and translates the observation. The request handler keeps no state;
  /// neither does the observation after this function returns its plain values.
  private func joints(in buffer: CVPixelBuffer) -> [VisionPosePoint] {
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    guard width > 0, height > 0 else { return [] }
    let portrait = height >= width

    let request = VNDetectHumanBodyPoseRequest()
    // The capture graph asks for portrait, mirrored buffers, so Vision sees the image the child
    // sees. A landscape buffer means the rotation was unsupported: `.right` is the quarter turn that
    // stands a front camera's portrait scene upright.
    let orientation: CGImagePropertyOrientation = portrait ? .up : .right
    let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return []
    }
    guard let observation = request.results?.first else { return [] }

    var points: [VisionPosePoint] = []
    for name in Self.jointNames {
      guard let recognized = try? observation.recognizedPoint(name.key), recognized.confidence > 0 else {
        continue
      }
      let image = VisionPoseMapping.imagePoint(x: Double(recognized.location.x),
                                               y: Double(recognized.location.y),
                                               portrait: portrait)
      points.append(VisionPosePoint(joint: name.id,
                                    x: image.x,
                                    y: image.y,
                                    confidence: Double(recognized.confidence)))
    }
    return points
  }

  /// The model's vocabulary and the app's fifteen joint names. Vision names a joint from the
  /// subject's point of view, which is what a mirror shows; the classifier only reads distances and
  /// absolute deviations, so the naming never changes a verdict.
  private static let jointNames: [(key: VNHumanBodyPoseObservation.JointName, id: JointID)] = [
    (.nose, .nose),
    (.leftEye, .leftEye), (.rightEye, .rightEye),
    (.leftEar, .leftEar), (.rightEar, .rightEar),
    (.neck, .neck),
    (.root, .root),
    (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
    (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
    (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
    (.leftHip, .leftHip), (.rightHip, .rightHip),
  ]
}
