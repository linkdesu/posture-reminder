import Foundation

/// One point of the avatar's body cloud. `x` and `y` are normalized image coordinates — the same
/// (0...1, y downwards) space as the joints, so `PoseProjection` can place them — and `z` is the
/// distance to the camera in metres, positive away from it.
struct BodyPoint: Equatable {
  var x: Double
  var y: Double
  var z: Double
}
