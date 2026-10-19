import SwiftUI

/// One colour per posture, shared by every surface that draws a posture: the avatar tints the
/// body part that is in trouble with it, and the parent report's day timeline and legend read the
/// same table. It lives in the view layer rather than on `PostureKind` so the domain stays free of
/// SwiftUI — the domain is the pure, time-injected state machine of ADR-0001 and has no business
/// importing a drawing framework.
///
/// Keys are `PostureKind.rawValue`, plus `PostureStatus.noPerson.rawValue` for the absence
/// segment and `pausedKind` for the pause band a report timeline has to draw. Warm to cool, and
/// deliberately far apart in hue so adjacent timeline segments stay distinguishable.
enum PosturePalette {
  /// The segment kind a report draws for a pause (PRD v0.5.1 B2). A pause is a band for time the
  /// child was not being measured, not a posture: the domain never classifies it, and the report
  /// neither scores it nor counts it in the good-posture ratio. The engine, the timeline and the
  /// legend share this one spelling.
  static let pausedKind = "paused"

  static let colors: [String: Color] = [
    // Good posture is the band's substance, so it is solid; "nobody here" is the empty state, so
    // it is light. Before this entry existed, good posture fell through to `calm` and came out all
    // but identical to the absence colour, which put two indistinguishable rows in one legend.
    PostureStatus.good.rawValue: Color(.sRGB, red: 0.42, green: 0.47, blue: 0.44, opacity: 1),
    PostureKind.deskLean.rawValue: Color(.sRGB, red: 0.97, green: 0.62, blue: 0.24, opacity: 1),
    PostureKind.near.rawValue: Color(.sRGB, red: 0.94, green: 0.35, blue: 0.34, opacity: 1),
    PostureKind.headForward.rawValue: Color(.sRGB, red: 0.90, green: 0.42, blue: 0.72, opacity: 1),
    PostureKind.slouch.rawValue: Color(.sRGB, red: 0.62, green: 0.48, blue: 0.94, opacity: 1),
    PostureKind.headDown.rawValue: Color(.sRGB, red: 0.40, green: 0.66, blue: 0.97, opacity: 1),
    PostureKind.headTilt.rawValue: Color(.sRGB, red: 0.26, green: 0.78, blue: 0.75, opacity: 1),
    PostureKind.shoulderTilt.rawValue: Color(.sRGB, red: 0.78, green: 0.80, blue: 0.30, opacity: 1),
    PostureKind.chinRest.rawValue: Color(.sRGB, red: 0.50, green: 0.83, blue: 0.40, opacity: 1),
    PostureStatus.noPerson.rawValue: Color(.sRGB, red: 0.80, green: 0.81, blue: 0.83, opacity: 1),
    // A pause is neither a posture nor an absence, so it is a neutral mid grey: clearly darker than
    // the pale absence grey and clearly lighter and less green than the solid good-posture sage.
    PosturePalette.pausedKind: Color(.sRGB, red: 0.60, green: 0.60, blue: 0.62, opacity: 1),
  ]

  /// The calm colour for a segment whose posture has no entry, so a caller never has to unwrap.
  static let calm = Color(.sRGB, red: 0.44, green: 0.49, blue: 0.58, opacity: 1)

  static func color(for rawValue: String) -> Color {
    colors[rawValue] ?? calm
  }

  /// The states a legend lists, good posture first so a good day reads top-down, then the postures
  /// in the order the domain ranks them, then the bands that are not postures: absence, then pause.
  static var legendOrder: [String] {
    [PostureStatus.good.rawValue]
      + PostureKind.allCases.map(\.rawValue)
      + [PostureStatus.noPerson.rawValue, pausedKind]
  }
}
