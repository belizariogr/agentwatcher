import Foundation

/// Claude Code: limits come from Anthropic's OAuth usage endpoint, signed
/// with the token the CLI keeps in the macOS Keychain (or in
/// `.credentials.json` on setups that store it on disk).
public struct ClaudeProvider: UsageProvider {
  public let id = "claude"
  public let name = "Claude Code"

  static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
  static let keychainService = "Claude Code-credentials"
  /// Anthropic rate-limits this endpoint aggressively unless the request looks
  /// like Claude Code. T3 Code's native path uses the CLI `get_usage` probe
  /// (4 s); we keep the HTTP endpoint and the CLI's User-Agent instead.
  static let fallbackUserAgent = "claude-code/2.0.0"
  static let userAgent: String = {
    guard let binary = Shell.which("claude"),
          let raw = Shell.run(binary.path, ["--version"], timeout: 2) else { return fallbackUserAgent }
    return userAgent(fromVersionOutput: raw)
  }()
  static let requestTimeout: TimeInterval = 10
  static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = requestTimeout
    config.timeoutIntervalForResource = requestTimeout
    return URLSession(configuration: config)
  }()

  public init() {}

  var configDir: URL {
    if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
      return URL(fileURLWithPath: NSString(string: custom).expandingTildeInPath)
    }
    return Shell.home.appendingPathComponent(".claude")
  }

  public func isInstalled() -> Bool {
    FileManager.default.fileExists(atPath: configDir.path) || Shell.which("claude") != nil
  }

  struct Login {
    let accessToken: String
    let expiresAt: Date?
    let plan: String?
  }

  /// The CLI writes its Keychain item through `/usr/bin/security`, so asking
  /// the same tool keeps macOS from prompting for access on every read.
  func login() async -> Login? {
    var oauth: JSON?
    if let raw = await Shell.output("/usr/bin/security", ["find-generic-password", "-s", Self.keychainService, "-w"]),
       let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
       let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON {
      oauth = json.object("claudeAiOauth")
    }
    if oauth == nil {
      oauth = Shell.readJSON(configDir.appendingPathComponent(".credentials.json"))?.object("claudeAiOauth")
    }
    guard let oauth, let token = oauth.string("accessToken") else { return nil }
    let tier = profileTier() ?? oauth.string("rateLimitTier")
    return Login(
      accessToken: token,
      expiresAt: Dates.parse(oauth["expiresAt"]),
      plan: Self.planLabel(tier: tier, subscription: oauth.string("subscriptionType"))
    )
  }

  /// The profile is refreshed against the account; the credentials keep the
  /// tier their token was minted with, so an upgrade shows here first.
  func profileTier() -> String? {
    let profile = Shell.readJSON(Shell.home.appendingPathComponent(".claude.json"))?.object("oauthAccount")
    guard let tier = profile?.string("userRateLimitTier") ?? profile?.string("organizationRateLimitTier"),
          tier.range(of: #"max_\d+x"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
    return tier
  }

  /// "max" + "default_claude_max_20x" → "Max 20x"; a Team seat stays "Team 5x".
  static func planLabel(tier: String?, subscription: String?) -> String? {
    let plan = subscription.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    guard let tier, let range = tier.range(of: #"max_(\d+x)"#, options: [.regularExpression, .caseInsensitive]) else {
      return plan
    }
    let multiplier = tier[range].dropFirst(4)
    return "\(plan ?? "Max") \(multiplier)"
  }

  public func fetch() async -> ProviderUsage {
    var usage = ProviderUsage(id: id, name: name)
    guard let login = await login() else {
      usage.message = "Not logged in. Run `claude` and log in to see limits."
      usage.needsLogin = true
      return usage
    }
    usage.plan = login.plan

    let request = Self.usageRequest(token: login.accessToken)

    do {
      let (data, response) = try await Self.session.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      switch status {
      case 200:
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
          usage.message = "Invalid response from Anthropic's usage endpoint."
          return usage
        }
        usage.limits = Self.parseLimits(payload)
        usage.fetchedAt = Date()
        if usage.limits.isEmpty { usage.message = "Anthropic returned no limits." }
      case 401, 403:
        let expired = login.expiresAt.map { $0 < Date() } ?? false
        usage.needsLogin = true
        usage.message = expired
          ? "Token expired. Open Claude Code to renew the login."
          : "Anthropic rejected the login. Run `claude auth login`."
      case 429:
        usage.message = "Usage endpoint is rate limiting; will retry later."
        usage.rateLimited = true
      default:
        usage.message = "Usage endpoint answered HTTP \(status)."
      }
    } catch {
      usage.message = "Could not reach Anthropic."
    }
    return usage
  }

  static func usageRequest(token: String) -> URLRequest {
    var request = URLRequest(url: endpoint, timeoutInterval: requestTimeout)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    return request
  }

  /// `claude --version` prints e.g. "2.1.69 (Claude Code)".
  static func userAgent(fromVersionOutput raw: String) -> String {
    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let range = line.range(of: #"\d+\.\d+(?:\.\d+)?"#, options: .regularExpression) else {
      return fallbackUserAgent
    }
    return "claude-code/\(line[range])"
  }

  static func parseLimits(_ payload: JSON) -> [UsageLimit] {
    var limits: [UsageLimit] = []
    func add(_ key: String, _ title: String) {
      guard let bucket = payload.object(key), let pct = bucket.number("utilization"), pct >= 0 else { return }
      limits.append(UsageLimit(title: title, used: pct / 100, resetsAt: Dates.parse(bucket["resets_at"]), fullIsExact: false))
    }
    add("five_hour", "Session (5h)")
    add("seven_day", "Weekly")

    // T3 Code maps hub `limits` the same way: unscoped rows fill Session/Weekly
    // when the top-level buckets are null; `weekly_scoped` (Fable) is a
    // model allowance and does not color the icon.
    var seen = Set(limits.map(\.title))
    for entry in payload["limits"] as? [JSON] ?? [] {
      guard let pct = entry.number("percent") ?? entry.number("utilization"), pct >= 0 else { continue }
      let kind = entry.string("kind") ?? ""
      let window = kind.hasPrefix("weekly") || kind.hasPrefix("seven_day") ? "Weekly"
        : kind.hasPrefix("five_hour") || kind.hasPrefix("session") ? "Session" : ""
      let model = entry.object("scope")?.object("model")
      let modelName = model?.string("display_name") ?? model?.string("id")
      let title: String
      let countsTowardAlert: Bool
      if let modelName {
        title = window.isEmpty ? modelName : "\(modelName) · \(window)"
        countsTowardAlert = false
      } else if window == "Session" {
        title = "Session (5h)"
        countsTowardAlert = true
      } else if !window.isEmpty {
        title = window
        countsTowardAlert = true
      } else {
        continue
      }
      guard seen.insert(title).inserted else { continue }
      limits.append(UsageLimit(
        title: title,
        used: pct / 100,
        resetsAt: Dates.parse(entry["resets_at"]),
        countsTowardAlert: countsTowardAlert,
        fullIsExact: false
      ))
    }
    return limits
  }
}
