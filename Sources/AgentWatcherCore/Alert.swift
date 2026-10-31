import Foundation

public struct RGB: Equatable, Sendable {
  public let r: Double, g: Double, b: Double
  public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

  func mix(_ other: RGB, _ t: Double) -> RGB {
    RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
  }
}

/// How alarming a remaining allowance is. Nothing happens while more than
/// `threshold` is left; from there the color walks yellow → orange → red,
/// arriving at red when the allowance is gone.
public enum Alert {
  public static let defaultThreshold = 0.15

  public static let yellow = RGB(0.98, 0.80, 0.18)
  public static let orange = RGB(1.00, 0.55, 0.15)
  public static let red = RGB(0.96, 0.20, 0.24)

  /// nil while above the threshold, else 0 (just crossed) ... 1 (exhausted).
  public static func severity(remaining: Double, threshold: Double = defaultThreshold) -> Double? {
    guard threshold > 0, remaining <= threshold else { return nil }
    let left = min(max(remaining, 0), threshold)
    return 1 - left / threshold
  }

  public static func color(severity: Double) -> RGB {
    let s = min(max(severity, 0), 1)
    return s < 0.5 ? yellow.mix(orange, s / 0.5) : orange.mix(red, (s - 0.5) / 0.5)
  }

  /// The tightest window across every harness decides the icon.
  public static func worstRemaining(_ usages: [ProviderUsage], now: Date = Date()) -> Double? {
    usages.compactMap { $0.tightest(now: now)?.remaining(now: now) }.min()
  }
}
