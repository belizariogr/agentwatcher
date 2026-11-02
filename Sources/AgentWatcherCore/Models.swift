import Foundation

/// One rate-limit window of a harness: a 5-hour session, a week, a model's
/// own allowance, a spend cap.
public struct UsageLimit: Identifiable, Equatable, Sendable, Codable {
  public var id: String { title }
  public let title: String
  /// Share of the allowance already used, 0...1.
  public let used: Double
  public let resetsAt: Date?
  /// Model-scoped windows (Fable) and Cursor's Auto/API pools still show in
  /// the panel but do not color the menu bar icon. The icon follows the
  /// account-level allowance: session/weekly for Claude, Overall for Cursor.
  public let countsTowardAlert: Bool
  /// Cursor's Overall figure drives the icon but is not a third quota, so it
  /// stays off the panel when the two pools are listed.
  public let shownInPanel: Bool

  public init(title: String, used: Double, resetsAt: Date?, countsTowardAlert: Bool = true, shownInPanel: Bool = true) {
    self.title = title
    self.used = min(1, max(0, used))
    self.resetsAt = resetsAt
    self.countsTowardAlert = countsTowardAlert
    self.shownInPanel = shownInPanel
  }

  enum CodingKeys: String, CodingKey { case title, used, resetsAt, countsTowardAlert, shownInPanel }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    title = try c.decode(String.self, forKey: .title)
    used = try c.decode(Double.self, forKey: .used)
    resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
    countsTowardAlert = try c.decodeIfPresent(Bool.self, forKey: .countsTowardAlert) ?? true
    shownInPanel = try c.decodeIfPresent(Bool.self, forKey: .shownInPanel) ?? (title != "Overall")
  }

  /// A window whose reset time has passed is empty again, even if the last
  /// reading predates the reset.
  public func effectiveUsed(now: Date = Date()) -> Double {
    if let resetsAt, resetsAt <= now { return 0 }
    return used
  }

  public func remaining(now: Date = Date()) -> Double {
    1 - effectiveUsed(now: now)
  }
}

/// Everything the panel shows for one harness.
public struct ProviderUsage: Identifiable, Equatable, Sendable, Codable {
  public let id: String
  public let name: String
  public var plan: String?
  public var limits: [UsageLimit]
  /// Shown under the harness name when the last refresh went wrong.
  public var message: String?
  /// When `limits` were measured.
  public var fetchedAt: Date?
  /// The harness has no usable login (missing, expired or rejected). The last
  /// numbers stay on screen, labelled as old: a token left to expire says
  /// nothing about the allowance, which other machines may still be using.
  public var needsLogin: Bool
  /// The endpoint asked us to slow down. Routine (Anthropic rate-limits the
  /// usage endpoint readily), so the panel keeps the last numbers silently.
  public var rateLimited: Bool

  public init(id: String, name: String, plan: String? = nil, limits: [UsageLimit] = [], message: String? = nil, fetchedAt: Date? = nil, needsLogin: Bool = false, rateLimited: Bool = false) {
    self.id = id
    self.name = name
    self.plan = plan
    self.limits = limits
    self.message = message
    self.fetchedAt = fetchedAt
    self.needsLogin = needsLogin
    self.rateLimited = rateLimited
  }

  enum CodingKeys: String, CodingKey { case id, name, plan, limits, message, fetchedAt, needsLogin, rateLimited }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    plan = try c.decodeIfPresent(String.self, forKey: .plan)
    limits = try c.decodeIfPresent([UsageLimit].self, forKey: .limits) ?? []
    message = try c.decodeIfPresent(String.self, forKey: .message)
    fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
    needsLogin = try c.decodeIfPresent(Bool.self, forKey: .needsLogin) ?? false
    rateLimited = try c.decodeIfPresent(Bool.self, forKey: .rateLimited) ?? false
  }

  /// The check itself failed (no network, a server error, a bad answer), which
  /// a retry can fix. A rate limit or a lost login waits for the regular interval.
  public var isTemporaryFailure: Bool {
    message != nil && !needsLogin && !rateLimited && fetchedAt == nil
  }

  /// Rows drawn in the panel. Cursor's Overall is kept for the icon only.
  public var visibleLimits: [UsageLimit] { limits.filter(\.shownInPanel) }

  /// The account-level window with the least room left. Model-scoped and
  /// breakdown rows are ignored so they cannot turn the icon red on their own.
  public func tightest(now: Date = Date()) -> UsageLimit? {
    limits.filter(\.countsTowardAlert).min { $0.remaining(now: now) < $1.remaining(now: now) }
  }

  /// Icon tooltip. Cursor's Overall is omitted from the label because it is
  /// not a row in the panel.
  public func tooltipLine(now: Date = Date()) -> String {
    guard let tight = tightest(now: now) else { return "\(name): no data" }
    let percent = "\(Alert.percentLeftText(tight.remaining(now: now))) left"
    return tight.shownInPanel ? "\(name): \(percent) (\(tight.title))" : "\(name): \(percent)"
  }

  /// Keep the last good numbers when a refresh fails (the Claude endpoint
  /// rate-limits readily) or the login is gone, but surface why they are not
  /// fresh. The next good refresh replaces them.
  public func merged(withPrevious previous: ProviderUsage?) -> ProviderUsage {
    guard limits.isEmpty, let previous, !previous.limits.isEmpty else { return self }
    var copy = self
    copy.limits = previous.limits
    copy.fetchedAt = previous.fetchedAt
    copy.plan = plan ?? previous.plan
    return copy
  }
}

public protocol UsageProvider: Sendable {
  var id: String { get }
  var name: String { get }
  /// Whether the harness is on this machine at all. Cheap: no network.
  func isInstalled() -> Bool
  func fetch() async -> ProviderUsage
}
