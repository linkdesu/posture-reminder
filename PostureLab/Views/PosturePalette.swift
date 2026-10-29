import SwiftUI

/// One colour per posture, shared by every surface that draws a posture: the avatar tints the
/// body part that is in trouble with it, and the parent report's day timeline and legend read the
/// same table. It lives in the view layer rather than on `PostureKind` so the domain stays free of
/// SwiftUI — the domain is the pure, time-injected state machine of ADR-0001 and has no business
/// importing a drawing framework.
///
/// Keys are `PostureKind.rawValue`, plus `PostureStatus.noPerson.rawValue` for the absence
/// segment and `pausedKind`/`detectingKind` for the two bands a report timeline has to draw that
/// are neither postures nor absences. Warm to cool, and deliberately far apart in hue so adjacent
/// timeline segments stay distinguishable.
enum PosturePalette {
  /// The segment kind a report draws for a pause (PRD v0.5.1 B2). A pause is a band for time the
  /// child was not being measured, not a posture: the domain never classifies it, and the report
  /// neither scores it nor counts it in the good-posture ratio. The engine, the timeline and the
  /// legend share this one spelling.
  static let pausedKind = PostureSegment.pausedKind

  /// The segment kind a report draws for "detecting" (PRD v0.6): the wall-clock time between the
  /// child tapping 开始 and the first posture sample of that focus. It is neither a posture nor an
  /// absence — the camera has not said anything yet — so it is kept as its own timeline segment,
  /// stays out of the bad-posture tally and out of the good ratio's denominator. The engine, the
  /// timeline and the legend share this one spelling.
  static let detectingKind = PostureSegment.detectingKind

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
    // "Detecting" is the palest and coolest of the three neutrals: it is the emptiest band of all,
    // since nothing has been judged yet. Three greys, three meanings, in descending darkness —
    // pause (0.60) is time taken out of the countdown, absence (0.80) is a measured "nobody here",
    // detecting (0.90) is the short wait before the first sample.
    PosturePalette.detectingKind: Color(.sRGB, red: 0.90, green: 0.91, blue: 0.93, opacity: 1),
  ]

  /// The calm colour for a segment whose posture has no entry, so a caller never has to unwrap.
  static let calm = Color(.sRGB, red: 0.44, green: 0.49, blue: 0.58, opacity: 1)

  static func color(for rawValue: String) -> Color {
    colors[rawValue] ?? calm
  }

  /// The states a legend lists, good posture first so a good day reads top-down, then the postures
  /// in the order the domain ranks them, then the bands that are not postures: absence, pause, and
  /// finally "detecting" — the wait before the first sample, the least interesting row of all.
  static var legendOrder: [String] {
    [PostureStatus.good.rawValue]
      + PostureKind.allCases.map(\.rawValue)
      + [PostureStatus.noPerson.rawValue, pausedKind, detectingKind]
  }
}
