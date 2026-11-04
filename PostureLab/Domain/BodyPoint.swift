import Foundation

/// One point of the avatar's body cloud. `x` and `y` are normalized image coordinates — the same
/// (0...1, y downwards) space as the joints, so `PoseProjection` can place them — and `z` is the
/// distance to the camera in metres, positive away from it.
struct BodyPoint: Equatable {
  var x: Double
  var y: Double
  var z: Double
  /// 固定采样网格的槽位编号。槽位与画面位置一一对应，所以两帧里 `slot` 相同的点就是身体上同一处，
  /// 帧间平滑与插值都按它配对，而不是按数组下标。脚本 rig 没有网格，用 -1 表示「没有槽位」。
  var slot: Int = -1
}
