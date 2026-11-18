import Foundation

/// Days the pace leaves out: an allowance spent only on workdays should not
/// look under-used over the weekend. Applies to windows of a week or longer;
/// a 5-hour session is paced by the clock.
public struct PaceOptions: Equatable, Sendable {
  public var skipSaturday: Bool
  public var skipSunday: Bool

  public init(skipSaturday: Bool = false, skipSunday: Bool = false) {
    self.skipSaturday = skipSaturday
    self.skipSunday = skipSunday
  }

  /// `Calendar` weekdays: 1 is Sunday, 7 is Saturday.
  var skippedWeekdays: Set<Int> {
    var days: Set<Int> = []
    if skipSaturday { days.insert(7) }
    if skipSunday { days.insert(1) }
    return days
  }
}

/// Where a window stands against an even spread of its allowance until the reset.
public struct PaceReading: Equatable, Sendable {
  /// Share of the allowance an even spread would have used by now, 0...1.
  public let expectedUsed: Double
  /// Used minus expected: positive means spending faster than the pace
  /// (a deficit), negative means room saved (a reserve).
  public let delta: Double
  /// When the allowance runs out at the rate so far, if that is before the reset.
  public let runsOutAt: Date?
  /// Day boundaries as shares of the allowance, for windows of a week. Each
  /// counted day gets an equal slice; skipped days get none.
  public let dayMarks: [Double]

  /// What an even spread leaves by now: where the pace marker sits on a bar
  /// that shrinks as the allowance is used.
  public var expectedRemaining: Double { 1 - expectedUsed }

  /// Whole percents off the pace, rounded. Zero reads as on pace.
  public var deltaPercent: Int { Int((abs(delta) * 100).rounded()) }

  public var label: String {
    let off = deltaPercent
    if off == 0 { return "On pace" }
    return delta > 0 ? "\(off)% in deficit" : "\(off)% in reserve"
  }
}

public enum Pace {
  public static let day: TimeInterval = 86_400
  /// Skipped weekdays apply from weekly windows up (with slack for a window
  /// reported a little short).
  static let skipFrom: TimeInterval = 6 * day
  /// Day marks only on weekly windows: a session has no days, and a month
  /// has too many to read.
  static let dayMarksUpTo: TimeInterval = 8 * day
  /// Too early in a window, the rate so far says little about the end.
  static let minimumElapsedForProjection = 0.05

  public static func reading(
    for limit: UsageLimit,
    now: Date = Date(),
    options: PaceOptions = PaceOptions(),
    calendar: Calendar = .current
  ) -> PaceReading? {
    guard let end = limit.resetsAt, let duration = limit.duration, duration > 0, now < end else { return nil }
    let start = end.addingTimeInterval(-duration)
    let skip = duration >= skipFrom ? options.skippedWeekdays : []
    let segments = countedSegments(from: start, to: end, skipping: skip, calendar: calendar)
    let total = segments.reduce(0) { $0 + $1.duration }
    guard total > 0 else { return nil }

    let elapsed = counted(segments, from: start, to: now)
    let expected = min(max(elapsed / total, 0), 1)
    let used = limit.effectiveUsed(now: now)
    let delta = used - expected

    var runsOutAt: Date?
    if delta > 0, used > 0, used < 1, expected >= minimumElapsedForProjection {
      let rate = used / elapsed
      runsOutAt = wallDate(after: (1 - used) / rate, from: now, in: segments)
    }

    var marks: [Double] = []
    if duration >= skipFrom, duration <= dayMarksUpTo {
      var sum: TimeInterval = 0
      for segment in segments.dropLast() {
        sum += segment.duration
        let mark = sum / total
        if mark > 0.005, mark < 0.995, marks.last.map({ mark - $0 > 0.005 }) ?? true { marks.append(mark) }
      }
    }
    return PaceReading(expectedUsed: expected, delta: delta, runsOutAt: runsOutAt, dayMarks: marks)
  }

  /// The window split at local midnights, without the skipped days.
  static func countedSegments(from start: Date, to end: Date, skipping skip: Set<Int>, calendar: Calendar) -> [DateInterval] {
    var segments: [DateInterval] = []
    var cursor = start
    while cursor < end {
      let dayStart = calendar.startOfDay(for: cursor)
      let next = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? cursor.addingTimeInterval(day)
      let segmentEnd = min(max(next, cursor.addingTimeInterval(1)), end)
      if !skip.contains(calendar.component(.weekday, from: cursor)) {
        segments.append(DateInterval(start: cursor, end: segmentEnd))
      }
      cursor = segmentEnd
    }
    return segments
  }

  /// Counted time between two instants.
  static func counted(_ segments: [DateInterval], from start: Date, to end: Date) -> TimeInterval {
    segments.reduce(0) { sum, segment in
      let lower = max(segment.start, start), upper = min(segment.end, end)
      return upper > lower ? sum + upper.timeIntervalSince(lower) : sum
    }
  }

  /// The instant `amount` of counted time after `from`, or nil when the
  /// window ends first.
  static func wallDate(after amount: TimeInterval, from: Date, in segments: [DateInterval]) -> Date? {
    var left = amount
    for segment in segments where segment.end > from {
      let lower = max(segment.start, from)
      let available = segment.end.timeIntervalSince(lower)
      if left <= available { return lower.addingTimeInterval(left) }
      left -= available
    }
    return nil
  }

  /// One calendar month before a monthly reset, for windows whose length is
  /// not reported.
  static func monthBefore(_ date: Date?, calendar: Calendar = .current) -> TimeInterval? {
    guard let date, let start = calendar.date(byAdding: .month, value: -1, to: date) else { return nil }
    return date.timeIntervalSince(start)
  }
}
