import Foundation

/// What one depth observation says about the body.
///
/// The joints are what a posture reading is allowed to use; `unavailable` names every joint the
/// source could not measure on this frame, so a consumer can say "not available" instead of
/// inventing a limb. `pitchDeg`/`rollDeg`/`distanceCM` are the coarse head readings a depth-only
/// pipeline can derive today.
struct JointEstimate: Equatable {
  var joints: [JointID: JointSample]
  var unavailable: Set<JointID>
  var cloud: [BodyPoint]
  var distanceCM: Double?
  var pitchDeg: Double?
  var rollDeg: Double?
  var mask: BodyMask?

  /// Nobody in the frame: no joints, every joint unavailable, no cloud.
  static var empty: JointEstimate {
    JointEstimate(joints: [:],
                  unavailable: Set(JointID.allCases),
                  cloud: [],
                  distanceCM: nil,
                  pitchDeg: nil,
                  rollDeg: nil,
                  mask: nil)
  }
}

/// The one seam between "where the body comes from" and everything that reads it.
///
/// The depth build ships `DepthJointSource`. A later branch that estimates joints some other way
/// (its own depth model, a different sensor) conforms to this protocol and is handed to
/// `DepthCaptureSource` instead; the classifier, the point cloud, the overlay and the controller
/// never change. The input is a depth image on purpose: this build must not be able to feed a video
/// frame into the seam.
protocol JointSource: AnyObject {
  /// Short name written into the log's provenance and shown nowhere else.
  var identifier: String { get }
  func estimate(from depth: DepthImage) -> JointEstimate
}
