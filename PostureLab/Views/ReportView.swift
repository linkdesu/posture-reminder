import SwiftUI

/// The parent's report: one day as a sleep-chart-style posture timeline, a week or a month as plain
/// daily columns, and the only destructive action the parent owns.
///
/// The view stays thin on purpose. Every figure comes from the controller's report values, which
/// `PomodoroHistory` aggregates; nothing here judges a posture, times anything or combines a ratio.
/// The band and its legend are drawn from the same `day.segments` array and the same shared colour
/// table (`PosturePalette`), so a colour can never appear without its legend row, and a legend row
/// can never appear without its colour.
struct ReportView: View {
  @EnvironmentObject private var controller: SessionController

  /// Raised by 清空历史; the dialog below is the confirmation that has to come before the store
  /// clears, so a stray tap can never wipe the family's history.
  @State private var asksToClearHistory = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          scopePicker

          switch controller.reportScope {
          case .day:
            dayReport
          case .week, .month:
            periodReport
          }

          clearButton
        }
        .padding(20)
      }
      .navigationTitle("报告")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("返回") { controller.showPomodoro() }
        }
      }
      .confirmationDialog("清空全部历史？",
                          isPresented: $asksToClearHistory,
                          titleVisibility: .visible) {
        Button("清空", role: .destructive) { controller.clearPomodoroHistory() }
        Button("取消", role: .cancel) {}
      } message: {
        Text("本机保存的番茄记录与姿态时间轴会全部删除，无法找回。")
      }
    }
  }

  // MARK: - Scope

  private var scopePicker: some View {
    Picker("报告范围", selection: $controller.reportScope) {
      Text("日").tag(ReportScope.day)
      Text("周").tag(ReportScope.week)
      Text("月").tag(ReportScope.month)
    }
    .pickerStyle(.segmented)
  }

  // MARK: - Day

  /// The day's timeline, or a plain statement that the day holds nothing. An empty day never draws
  /// an empty band: a bare track would read as "no posture problems", which is a different claim
  /// from "nothing was measured".
  @ViewBuilder
  private var dayReport: some View {
    if let day = controller.reportDays.last {
      VStack(alignment: .leading, spacing: 20) {
        dayHeader(day)

        if day.segments.isEmpty {
          emptyNotice("这一天还没有姿态记录。")
        } else {
          timeline(day)
          hourAxis
          legend(day)
        }
      }
    } else {
      emptyNotice("本地还没有任何报告数据。")
    }
  }

  private func dayHeader(_ day: ReportDay) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(Self.dayTitleFormatter.string(from: day.date))
        .font(.headline)

      Text(dayDetail(day))
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  /// The day's headline figures. The good-posture ratio is left out on a day with no segments at
  /// all: the aggregate reports 0 there, and printing "0%" would misread "nothing measured" as
  /// "everything was bad".
  private func dayDetail(_ day: ReportDay) -> String {
    var parts = ["完成 \(day.completedPomodoros) 个番茄", "专注 \(durationText(day.focusSeconds))"]
    if !day.segments.isEmpty {
      parts.append("良好占比 \(percentText(day.goodRatio))")
    }
    return parts.joined(separator: " · ")
  }

  /// A segment reduced to a fraction of its day, so the band can be drawn at any width.
  private struct TimelineBar {
    let kind: String
    let start: Double
    let end: Double
  }

  /// Clamps every segment to the day it was reported on and turns it into fractions of that day.
  /// A segment running past midnight is drawn up to the boundary rather than escaping the band.
  private func timelineBars(_ segments: [PostureSegment], of date: Date) -> [TimelineBar] {
    let window = dayWindow(date)
    let span = window.upperBound - window.lowerBound
    return segments.map { segment in
      let lower = min(max((segment.start - window.lowerBound) / span, 0), 1)
      let upper = min(max((segment.end - window.lowerBound) / span, 0), 1)
      return TimelineBar(kind: segment.kind, start: lower, end: max(upper, lower))
    }
  }

  /// The sleep-chart band: the whole calendar day, left to right, one rectangle per segment.
  private func timeline(_ day: ReportDay) -> some View {
    let bars = timelineBars(day.segments, of: day.date)
    return GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        Rectangle()
          .fill(Color(uiColor: .tertiarySystemFill))

        ForEach(bars.indices, id: \.self) { index in
          Rectangle()
            .fill(PosturePalette.color(for: bars[index].kind))
            // A sub-point run still gets one point of colour, so the band never hides a segment
            // the legend below is counting.
            .frame(width: max(1, CGFloat(bars[index].end - bars[index].start) * proxy.size.width))
            .offset(x: CGFloat(bars[index].start) * proxy.size.width)
        }
      }
    }
    .frame(height: 44)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  /// A plain hour ruler under the band, so the reader can place a colour in the day.
  private var hourAxis: some View {
    HStack(spacing: 0) {
      Text("0")
      Spacer(minLength: 0)
      Text("6")
      Spacer(minLength: 0)
      Text("12")
      Spacer(minLength: 0)
      Text("18")
      Spacer(minLength: 0)
      Text("24")
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }

  /// One legend row: a kind the day actually contains, and the seconds it was held.
  private struct LegendEntry: Identifiable {
    let kind: String
    let seconds: Double

    var id: String { kind }
  }

  /// Groups the very segments the band draws, so the legend can neither list a kind the day does not
  /// contain nor miss one it does, and the two stay in step by construction. Ordering follows the
  /// shared palette, with 良好 pulled to the front and unknown kinds appended by name.
  private func legendEntries(_ segments: [PostureSegment]) -> [LegendEntry] {
    var secondsByKind: [String: Double] = [:]
    for segment in segments {
      secondsByKind[segment.kind, default: 0] += segment.seconds
    }

    let order = PosturePalette.legendOrder
    return secondsByKind
      .map { LegendEntry(kind: $0.key, seconds: $0.value) }
      .sorted { left, right in
        let leftRank = self.legendRank(of: left.kind, in: order)
        let rightRank = self.legendRank(of: right.kind, in: order)
        if leftRank != rightRank { return leftRank < rightRank }
        return left.kind < right.kind
      }
  }

  /// `legendOrder` covers the seven postures and the absence state; 良好 is a state the report also
  /// draws, so it ranks ahead of them and a good day reads top-down.
  private func legendRank(of kind: String, in order: [String]) -> Int {
    if kind == PostureStatus.good.rawValue { return -1 }
    return order.firstIndex(of: kind) ?? order.count
  }

  private func legend(_ day: ReportDay) -> some View {
    let entries = legendEntries(day.segments)
    return VStack(alignment: .leading, spacing: 0) {
      ForEach(entries) { entry in
        HStack(spacing: 12) {
          RoundedRectangle(cornerRadius: 3)
            .fill(PosturePalette.color(for: entry.kind))
            .frame(width: 14, height: 14)

          Text(Self.displayName(for: entry.kind))
            .font(.subheadline)

          Spacer(minLength: 12)

          Text(self.clockText(entry.seconds))
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
      }
    }
    .padding(.horizontal, 16)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
  }

  // MARK: - Week and month

  /// The period view: the scope's totals, then one row a day. Each row carries three gauge columns
  /// and the exact numbers beside them, so the shape and the figure can be read together.
  private var periodReport: some View {
    let days = controller.reportDays
    return VStack(alignment: .leading, spacing: 20) {
      totalsCard(controller.reportTotals, dayCount: days.count)

      if days.isEmpty || days.allSatisfy({ self.hasNoData($0) }) {
        emptyNotice("这段时间还没有番茄记录。")
      } else {
        Text("每行一天：三根柱子依次是完成番茄数、专注时长和当天良好占比，右侧是当天的数字。")
          .font(.caption)
          .foregroundStyle(.secondary)

        dailyRows(days)
      }
    }
  }

  private func totalsCard(_ totals: ReportTotals, dayCount: Int) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(periodTitle(dayCount))
        .font(.headline)

      HStack(alignment: .top, spacing: 20) {
        figure("完成番茄", "\(totals.completedPomodoros) 个")
        figure("专注总时长", durationText(totals.focusSeconds))
        figure("良好占比", percentText(totals.goodRatio))
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
  }

  private func periodTitle(_ dayCount: Int) -> String {
    dayCount > 0 ? "最近 \(dayCount) 天" : "这段时间"
  }

  private func figure(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(value)
        .font(.title3)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Per-series maxima: the columns are gauges, so each is drawn against its own scale. The ratio
  /// column is scaled to 100% instead, which makes its height read as a share.
  private struct ColumnScale {
    let pomodoros: Double
    let focusSeconds: Double

    init(days: [ReportDay]) {
      pomodoros = max(1, days.map { Double($0.completedPomodoros) }.max() ?? 0)
      focusSeconds = max(1, days.map(\.focusSeconds).max() ?? 0)
    }
  }

  private func dailyRows(_ days: [ReportDay]) -> some View {
    let columns = ColumnScale(days: days)
    return VStack(spacing: 0) {
      ForEach(days, id: \.date) { day in
        self.dayRow(day, columns: columns)

        if day.date != days.last?.date {
          Divider()
        }
      }
    }
    .padding(.horizontal, 16)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
  }

  private func dayRow(_ day: ReportDay, columns: ColumnScale) -> some View {
    HStack(spacing: 12) {
      Text(Self.rowDateFormatter.string(from: day.date))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(width: 44, alignment: .leading)

      column(value: Double(day.completedPomodoros), of: columns.pomodoros, color: .accentColor)
      column(value: day.focusSeconds, of: columns.focusSeconds, color: .blue)
      // The daily good-posture ratio, drawn against 100%: this column is the period's mini trend.
      column(value: day.goodRatio, of: 1, color: .green)

      Spacer(minLength: 8)

      dayNumbers(day)
    }
    .padding(.vertical, 10)
  }

  /// The day's three figures, right-aligned beside its columns.
  private func dayNumbers(_ day: ReportDay) -> some View {
    HStack(spacing: 8) {
      Text("\(day.completedPomodoros)")
        .font(.subheadline.monospacedDigit())
        .frame(width: 26, alignment: .trailing)

      Text(durationText(day.focusSeconds))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(width: 58, alignment: .trailing)

      Text(percentText(day.goodRatio))
        .font(.subheadline.monospacedDigit())
        .frame(width: 42, alignment: .trailing)
    }
  }

  /// One gauge column: a track, and a fill whose height is the value's share of its series. A zero
  /// value draws no fill at all rather than a stub that would look like data.
  private func column(value: Double, of maximum: Double, color: Color) -> some View {
    let share = maximum > 0 ? min(max(value / maximum, 0), 1) : 0
    return ZStack(alignment: .bottom) {
      RoundedRectangle(cornerRadius: 2)
        .fill(Color(uiColor: .tertiarySystemFill))

      if share > 0 {
        RoundedRectangle(cornerRadius: 2)
          .fill(color)
          .frame(height: max(3, CGFloat(24 * share)))
      }
    }
    .frame(width: 10, height: 24)
  }

  // MARK: - Clear history

  private var clearButton: some View {
    Button("清空历史", role: .destructive) {
      asksToClearHistory = true
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 14)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
  }

  // MARK: - Shared bits

  private func hasNoData(_ day: ReportDay) -> Bool {
    day.segments.isEmpty && day.completedPomodoros == 0 && day.focusSeconds == 0
  }

  /// A plain statement where a chart would otherwise look like data.
  private func emptyNotice(_ text: String) -> some View {
    Text(text)
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
  }

  /// The epoch-second window of a calendar day, from the same calendar the history was aggregated
  /// with, so the band lines up with the numbers underneath it.
  private func dayWindow(_ date: Date) -> Range<Double> {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: date)
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    return start.timeIntervalSince1970..<end.timeIntervalSince1970
  }

  /// The name of a segment kind, read back through the one state vocabulary the domain logs, so a
  /// kind added there needs no second table here.
  private static func displayName(for kind: String) -> String {
    PostureStatus(rawValue: kind)?.displayName ?? kind
  }

  /// "1 小时 15 分" / "45 分" / "30 秒": the form the focus totals are read in.
  private func durationText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let minutes = total / 60
    let hours = minutes / 60

    if hours > 0 {
      let remainder = minutes % 60
      return remainder == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainder) 分"
    }
    return minutes > 0 ? "\(minutes) 分" : "\(total) 秒"
  }

  /// mm:ss, the clock the session summary already uses for a run of posture seconds.
  private func clockText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%02d:%02d", total / 60, total % 60)
  }

  private func percentText(_ ratio: Double) -> String {
    "\(Int((ratio * 100).rounded()))%"
  }

  // MARK: - Formatters

  /// The app's copy is Chinese throughout, so report dates are formatted in zh_CN rather than the
  /// device locale: a screenshot reads the same whatever language the simulator is set to.
  private static let dayTitleFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy年M月d日 EEE"
    return formatter
  }()

  private static let rowDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M/d"
    return formatter
  }()
}
