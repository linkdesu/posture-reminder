import Foundation

/// Turns the segmented depth frame into the points the child's screen draws.
///
/// Every point is one depth cell that the segmentation assigned to the body: `x`/`y` are that cell's
/// normalized position and `z` is its measured distance. Nothing is inferred between cells, so the
/// cloud's shape is the silhouette the sensor saw rather than a volume fitted to joints.
///
/// A frame yields at most `maxPoints` cells, chosen in two passes: the silhouette's own boundary
/// cells first — a body that loses its outline reads as a scatter of dots, whatever its interior
/// resolution — then the interior cells that fit in what the boundary left. Both passes walk the same
/// stride-anchored lattice in row-major order, so the same mask always gives the same array, and the
/// boundary a child sees is the boundary the sensor measured.
enum DepthCloud {
  static func points(mask: BodyMask,
                     image: DepthImage,
                     maxPoints: Int = 600) -> [BodyPoint] {
    guard mask.count > 0, maxPoints > 0 else { return [] }
    let step = max(1, Int((Double(mask.count) / Double(maxPoints)).squareRoot().rounded(.up)))
    var points: [BodyPoint] = []
    points.reserveCapacity(min(mask.count, maxPoints))

    // Boundary first: a cell with any neighbour outside the mask is on the silhouette's edge.
    for y in Swift.stride(from: mask.minY, through: mask.maxY, by: step) {
      for x in Swift.stride(from: mask.minX, through: mask.maxX, by: step) {
        guard points.count < maxPoints,
              mask.contains(x: x, y: y),
              image.isValid(x: x, y: y),
              isBoundary(mask, x: x, y: y) else { continue }
        points.append(point(mask: mask, image: image, x: x, y: y))
      }
    }

    // Then the interior, in the same order, until the budget is spent.
    for y in Swift.stride(from: mask.minY, through: mask.maxY, by: step) {
      for x in Swift.stride(from: mask.minX, through: mask.maxX, by: step) {
        guard points.count < maxPoints,
              mask.contains(x: x, y: y),
              image.isValid(x: x, y: y),
              !isBoundary(mask, x: x, y: y) else { continue }
        points.append(point(mask: mask, image: image, x: x, y: y))
      }
    }

    // A stride that jumps over every mask pixel (a very thin arm) still gets its nearest cell.
    if points.isEmpty,
       let first = (0..<mask.cells.count).first(where: { mask.cells[$0] }) {
      let x = first % mask.width
      let y = first / mask.width
      if image.isValid(x: x, y: y) {
        points.append(point(mask: mask, image: image, x: x, y: y))
      }
    }
    return points
  }

  private static func point(mask: BodyMask, image: DepthImage, x: Int, y: Int) -> BodyPoint {
    let position = mask.normalized(x: x, y: y)
    return BodyPoint(x: position.x,
                     y: position.y,
                     z: Double(image.value(x: x, y: y)))
  }

  /// Whether a mask cell touches the background on any of its four sides.
  private static func isBoundary(_ mask: BodyMask, x: Int, y: Int) -> Bool {
    !mask.contains(x: x - 1, y: y)
      || !mask.contains(x: x + 1, y: y)
      || !mask.contains(x: x, y: y - 1)
      || !mask.contains(x: x, y: y + 1)
  }
}
