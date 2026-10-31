import Foundation

/// Claude Code: limits come from Anthropic's OAuth usage endpoint, signed
/// with the token the CLI keeps in the macOS Keychain (or in
/// `.credentials.json` on setups that store it on disk).
public struct ClaudeProvider: UsageProvider {
  public let id = "claude"
  public let name = "Claude Code"

  static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
  static let keychainService = "Claude Code-credentials"

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
  func login() -> Login? {
    var oauth: JSON?
    if let raw = Shell.run("/usr/bin/security", ["find-generic-password", "-s", Self.keychainService, "-w"]),
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
    guard let login = login() else {
      usage.message = "Sem login. Rode `claude` e faça login para ver os limites."
      return usage
    }
    usage.plan = login.plan

    var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
    request.setValue("Bearer \(login.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      switch status {
      case 200:
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
          usage.message = "Resposta inválida do endpoint de uso da Anthropic."
          return usage
        }
        usage.limits = Self.parseLimits(payload)
        usage.fetchedAt = Date()
        if usage.limits.isEmpty { usage.message = "A Anthropic não retornou limites." }
      case 401, 403:
        let expired = login.expiresAt.map { $0 < Date() } ?? false
        usage.message = expired
          ? "Token expirado. Abra o Claude Code para renovar o login."
          : "A Anthropic recusou o login. Rode `claude auth login`."
      case 429:
        usage.message = "Endpoint de uso limitando consultas; tentando de novo mais tarde."
      default:
        usage.message = "Endpoint de uso respondeu HTTP \(status)."
      }
    } catch {
      usage.message = "Não foi possível falar com a Anthropic."
    }
    return usage
  }

  static func parseLimits(_ payload: JSON) -> [UsageLimit] {
    var limits: [UsageLimit] = []
    func add(_ key: String, _ title: String) {
      guard let bucket = payload.object(key), let pct = bucket.number("utilization"), pct >= 0 else { return }
      limits.append(UsageLimit(title: title, used: pct / 100, resetsAt: Dates.parse(bucket["resets_at"])))
    }
    add("five_hour", "Sessão (5h)")
    add("seven_day", "Semanal")

    // Model-scoped windows ("Fable Semanal") live in the `limits` list.
    var seen = Set<String>()
    for entry in payload["limits"] as? [JSON] ?? [] {
      guard let model = entry.object("scope")?.object("model"),
            let modelName = model.string("display_name") ?? model.string("id"),
            let pct = entry.number("percent"), pct >= 0 else { continue }
      let kind = entry.string("kind") ?? ""
      let window = kind.hasPrefix("weekly") || kind.hasPrefix("seven_day") ? "Semanal"
        : kind.hasPrefix("five_hour") || kind.hasPrefix("session") ? "Sessão" : ""
      let title = window.isEmpty ? modelName : "\(modelName) · \(window)"
      guard seen.insert(title).inserted else { continue }
      limits.append(UsageLimit(title: title, used: pct / 100, resetsAt: Dates.parse(entry["resets_at"])))
    }
    return limits
  }
}
