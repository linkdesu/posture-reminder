import SwiftUI

/// One colour per posture, shared by every surface that draws a posture: the avatar tints the
/// body part that is in trouble with it, and the parent report's day timeline and legend read the
/// same table. It lives in the view layer rather than on `PostureKind` so the domain stays free of
/// SwiftUI — the domain is the pure, time-injected state machine of ADR-0001 and has no business
/// importing a drawing framework.
///
/// Keys are `PostureKind.rawValue`, plus `PostureStatus.noPerson.rawValue` for the absence
/// segment a report timeline has to draw. Warm to cool, and deliberately far apart in hue so
/// adjacent timeline segments stay distinguishable.
enum PosturePalette {
  static let colors: [String: Color] = [
    PostureKind.deskLean.rawValue: Color(.sRGB, red: 0.97, green: 0.62, blue: 0.24, opacity: 1),
    PostureKind.near.rawValue: Color(.sRGB, red: 0.94, green: 0.35, blue: 0.34, opacity: 1),
    PostureKind.headForward.rawValue: Color(.sRGB, red: 0.90, green: 0.42, blue: 0.72, opacity: 1),
    PostureKind.slouch.rawValue: Color(.sRGB, red: 0.62, green: 0.48, blue: 0.94, opacity: 1),
    PostureKind.headDown.rawValue: Color(.sRGB, red: 0.40, green: 0.66, blue: 0.97, opacity: 1),
    PostureKind.headTilt.rawValue: Color(.sRGB, red: 0.26, green: 0.78, blue: 0.75, opacity: 1),
    PostureKind.chinRest.rawValue: Color(.sRGB, red: 0.50, green: 0.83, blue: 0.40, opacity: 1),
    PostureStatus.noPerson.rawValue: Color(.sRGB, red: 0.46, green: 0.51, blue: 0.60, opacity: 1),
  ]

  /// The calm colour for a segment whose posture has no entry, so a caller never has to unwrap.
  static let calm = Color(.sRGB, red: 0.44, green: 0.49, blue: 0.58, opacity: 1)

  static func color(for rawValue: String) -> Color {
    colors[rawValue] ?? calm
  }

  /// The postures a legend lists, in the order the domain ranks them.
  static var legendOrder: [String] {
    PostureKind.allCases.map(\.rawValue) + [PostureStatus.noPerson.rawValue]
  }
}
