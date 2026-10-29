import Foundation

/// Turns the segmented depth frame into the points the child's screen draws.
///
/// Every point is one depth cell that the segmentation assigned to the body: `x`/`y` are that cell's
/// normalized position and `z` is its measured distance. Nothing is inferred between cells, so the
/// cloud's shape is the silhouette the sensor saw rather than a volume fitted to joints. A stride is
/// chosen so a frame yields at most `maxPoints`, and the walk is row-major, so the same mask always
/// gives the same array.
enum DepthCloud {
  static func points(mask: BodyMask,
                     image: DepthImage,
                     maxPoints: Int = 1200) -> [BodyPoint] {
    guard mask.count > 0, maxPoints > 0 else { return [] }
    let step = max(1, Int((Double(mask.count) / Double(maxPoints)).squareRoot().rounded(.up)))
    var points: [BodyPoint] = []
    points.reserveCapacity(min(mask.count, maxPoints))

    for y in Swift.stride(from: mask.minY, through: mask.maxY, by: step) {
      for x in Swift.stride(from: mask.minX, through: mask.maxX, by: step) {
        guard mask.contains(x: x, y: y), image.isValid(x: x, y: y) else { continue }
        let position = mask.normalized(x: x, y: y)
        points.append(BodyPoint(x: position.x,
                                y: position.y,
                                z: Double(image.value(x: x, y: y))))
      }
    }
    // A stride that jumps over every mask pixel (a very thin arm) still gets its nearest cell.
    if points.isEmpty,
       let first = (0..<mask.cells.count).first(where: { mask.cells[$0] }) {
      let x = first % mask.width
      let y = first / mask.width
      if image.isValid(x: x, y: y) {
        let position = mask.normalized(x: x, y: y)
        points.append(BodyPoint(x: position.x,
                                y: position.y,
                                z: Double(image.value(x: x, y: y))))
      }
    }
    return points
  }
}
