import Foundation

/// Cursor: the monthly included-usage pools, read from the same dashboard RPC
/// the editor and the CLI call, signed with the session token the CLI keeps in
/// the Keychain (or the one the editor keeps in its state database).
public struct CursorProvider: UsageProvider {
  public let id = "cursor"
  public let name = "Cursor"

  static let api = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/")!
  static let keychainService = "cursor-access-token"

  public init() {}

  static var editorState: URL {
    Shell.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
  }

  public func isInstalled() -> Bool {
    let fm = FileManager.default
    return fm.fileExists(atPath: Shell.home.appendingPathComponent(".config/cursor").path)
      || fm.fileExists(atPath: Self.editorState.path)
      || Shell.which("cursor-agent") != nil
  }

  /// Every login on the machine: the CLI's Keychain item (written by
  /// `/usr/bin/security`, so reading it the same way never prompts) and the
  /// editor's. Unexpired ones first, so a stale CLI login left behind does not
  /// hide a working editor login.
  func accessTokens() async -> [String] {
    var tokens: [String] = []
    if let raw = await Shell.output("/usr/bin/security", ["find-generic-password", "-s", Self.keychainService, "-w"]) {
      tokens.append(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if FileManager.default.fileExists(atPath: Self.editorState.path),
       let raw = await Shell.output("/usr/bin/sqlite3", [
         "-readonly", Self.editorState.path,
         "select value from ItemTable where key = 'cursorAuth/accessToken'",
       ]) {
      tokens.append(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return Self.ordered(tokens)
  }

  static func ordered(_ tokens: [String], now: Date = Date()) -> [String] {
    var unique: [String] = []
    for token in tokens where !token.isEmpty && !unique.contains(token) { unique.append(token) }
    let expired = { (token: String) in expiry(of: token).map { $0 <= now } ?? false }
    return unique.filter { !expired($0) } + unique.filter(expired)
  }

  /// Cursor session tokens are JWTs; `exp` tells an expired login apart from
  /// a revoked one.
  static func expiry(of token: String) -> Date? {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload),
          let claims = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return nil }
    return Dates.parse(claims["exp"])
  }

  enum CallError: Error { case status(Int), invalid, network }

  func call(_ method: String, token: String) async throws -> JSON {
    var request = URLRequest(url: Self.api.appendingPathComponent(method), timeoutInterval: 15)
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    let data: Data, response: URLResponse
    do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw CallError.network }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw CallError.status(status) }
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { throw CallError.invalid }
    return json
  }

  public func fetch() async -> ProviderUsage {
    var usage = ProviderUsage(id: id, name: name)
    let tokens = await accessTokens()
    guard !tokens.isEmpty else {
      usage.message = "Not logged in. Run `cursor-agent login` (or sign in to Cursor) to see limits."
      usage.needsLogin = true
      return usage
    }

    for token in tokens {
      async let planInfo = try? call("GetPlanInfo", token: token)
      do {
        let payload = try await call("GetCurrentPeriodUsage", token: token)
        usage.limits = Self.parseLimits(payload)
        usage.fetchedAt = Date()
        if usage.limits.isEmpty { usage.message = "Cursor returned no limits." }
        usage.plan = await planInfo?.object("planInfo")?.string("planName")
        return usage
      } catch CallError.status(let status) where status == 401 || status == 403 {
        continue // try the next login
      } catch CallError.status(429) {
        usage.message = "Cursor is rate limiting; will retry later."
        usage.rateLimited = true
      } catch CallError.status(let status) {
        usage.message = "Cursor answered HTTP \(status)."
      } catch CallError.invalid {
        usage.message = "Invalid response from Cursor."
      } catch {
        usage.message = "Could not reach Cursor."
      }
      return usage
    }

    // Every login was refused.
    let expired = tokens.allSatisfy { Self.expiry(of: $0).map { $0 <= Date() } ?? false }
    usage.needsLogin = true
    usage.message = expired
      ? "Cursor login expired. Run `cursor-agent login`."
      : "Cursor rejected the login. Run `cursor-agent login`."
    return usage
  }

  /// Included usage is split into the Auto + Composer pool ("Cursor Models")
  /// and the API pool for named third-party models ("Other Models"); both
  /// renew with the billing cycle.
  static func parseLimits(_ payload: JSON) -> [UsageLimit] {
    guard let plan = payload.object("planUsage") else { return [] }
    let resets = Dates.parse(payload["billingCycleEnd"])
    var limits: [UsageLimit] = []
    func add(_ key: String, _ title: String) {
      guard let pct = plan.number(key), pct >= 0 else { return }
      limits.append(UsageLimit(title: title, used: pct / 100, resetsAt: resets))
    }
    add("autoPercentUsed", "Cursor Models")
    add("apiPercentUsed", "Other Models")
    // Older plans only report spend against the included amount.
    if limits.isEmpty, let spent = plan.number("includedSpend"), let limit = plan.number("limit"), limit > 0 {
      limits.append(UsageLimit(title: "Monthly", used: spent / limit, resetsAt: resets))
    }
    return limits
  }
}
