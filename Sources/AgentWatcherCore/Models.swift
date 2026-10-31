import Foundation

/// One rate-limit window of a harness: a 5-hour session, a week, a model's
/// own allowance, a spend cap.
public struct UsageLimit: Identifiable, Equatable, Sendable, Codable {
  public var id: String { title }
  public let title: String
  /// Share of the allowance already used, 0...1.
  public let used: Double
  public let resetsAt: Date?

  public init(title: String, used: Double, resetsAt: Date?) {
    self.title = title
    self.used = min(1, max(0, used))
    self.resetsAt = resetsAt
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
  /// The harness has no usable login (missing, expired or rejected). Unlike a
  /// rate limit or a network error, old numbers are not kept: they belong to
  /// a session that is gone.
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

  /// The window with the least room left.
  public func tightest(now: Date = Date()) -> UsageLimit? {
    limits.min { $0.remaining(now: now) < $1.remaining(now: now) }
  }

  /// Keep the last good numbers when a refresh fails (the Claude endpoint
  /// rate-limits readily), but surface why they are not fresh. A lost login
  /// drops them instead.
  public func merged(withPrevious previous: ProviderUsage?) -> ProviderUsage {
    guard limits.isEmpty, !needsLogin, let previous, !previous.limits.isEmpty else { return self }
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
