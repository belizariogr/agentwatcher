import Foundation

public struct RGB: Equatable, Sendable {
  public let r: Double, g: Double, b: Double
  public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

  func mix(_ other: RGB, _ t: Double) -> RGB {
    RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
  }
}

/// How alarming a remaining allowance is: nothing while more than the
/// warning threshold is left, warning at or below it, critical at or below
/// the critical threshold.
public enum AlertLevel: Equatable, Sendable {
  case warning, critical
}

public enum Alert {
  public static let defaultWarning = 0.20
  public static let defaultCritical = 0.10
  /// The settings' slider step, and the closest the two thresholds may get.
  public static let step = 0.01

  /// Warning starts here (#FFA915) and mixes toward `red` as remaining falls.
  public static let orange = RGB(1, 169.0 / 255.0, 21.0 / 255.0)
  /// Critical (#FD464D).
  public static let red = RGB(253.0 / 255.0, 70.0 / 255.0, 77.0 / 255.0)

  public static func level(
    remaining: Double, warning: Double = defaultWarning, critical: Double = defaultCritical
  ) -> AlertLevel? {
    // Compare the whole percent the panel shows, so "10% left" counts as
    // 10% even when it is really 10.9%.
    let shown = percentLeft(remaining)
    if shown <= wholePercent(critical) { return .critical }
    if shown <= wholePercent(warning) { return .warning }
    return nil
  }

  /// The whole percent left as shown everywhere: truncated, so 10.9% reads
  /// "10% left". The epsilon keeps 0.29 from reading as 28%.
  public static func percentLeft(_ remaining: Double) -> Int {
    min(max(Int((remaining * 100 + 1e-9).rounded(.down)), 0), 100)
  }

  /// The label for what is left: whole percents, then two decimals under 2%
  /// (when they are not .00) so the last stretch can be followed. Truncated
  /// like `percentLeft`.
  public static func percentLeftText(_ remaining: Double) -> String {
    let left = hundredthsLeft(remaining)
    return left < 200 ? hundredthsText(left) : "\(percentLeft(remaining))%"
  }

  /// The label for what is used, the exact complement of `percentLeftText`.
  public static func percentUsedText(_ remaining: Double) -> String {
    let left = hundredthsLeft(remaining)
    return left < 200 ? hundredthsText(10000 - left) : "\(100 - percentLeft(remaining))%"
  }

  /// Nothing left at the finest precision shown. 0.50% still has room.
  public static func isExhausted(_ remaining: Double) -> Bool {
    hundredthsLeft(remaining) == 0
  }

  /// Hundredths of a percent left, truncated. The epsilon matches `percentLeft`'s.
  private static func hundredthsLeft(_ remaining: Double) -> Int {
    min(max(Int((remaining * 10000 + 1e-7).rounded(.down)), 0), 10000)
  }

  /// A whole value stays whole: harnesses that only report integers read
  /// "1%", not "1.00%".
  private static func hundredthsText(_ value: Int) -> String {
    value % 100 == 0 ? "\(value / 100)%" : String(format: "%d.%02d%%", value / 100, value % 100)
  }

  /// Thresholds are whole percents already; this only absorbs float noise.
  static func wholePercent(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }

  public static func color(_ level: AlertLevel) -> RGB {
    switch level {
    case .warning: orange
    case .critical: red
    }
  }

  /// The color for a remaining allowance: none above the warning threshold,
  /// orange right at it, sliding toward red as it nears the critical
  /// threshold, and solid red from there down.
  public static func color(
    remaining: Double, warning: Double = defaultWarning, critical: Double = defaultCritical
  ) -> RGB? {
    guard let level = level(remaining: remaining, warning: warning, critical: critical) else { return nil }
    guard level == .warning, warning > critical else { return red }
    let t = (warning - remaining) / (warning - critical)
    return orange.mix(red, min(max(t, 0), 1))
  }

  /// The tightest account-level window across every harness decides the icon.
  public static func worstRemaining(_ usages: [ProviderUsage], now: Date = Date()) -> Double? {
    usages.compactMap { $0.tightest(now: now)?.remaining(now: now) }.min()
  }
}
