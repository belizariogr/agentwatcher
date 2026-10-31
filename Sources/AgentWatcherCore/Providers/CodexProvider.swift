import Foundation

/// Codex: limits and plan come from the CLI's own app-server over JSON-RPC
/// (`account/rateLimits/read`), so no token ever leaves the CLI.
public struct CodexProvider: UsageProvider {
  public let id = "codex"
  public let name = "Codex"

  public init() {}

  public func isInstalled() -> Bool {
    Shell.which("codex") != nil
  }

  public func fetch() async -> ProviderUsage {
    var usage = ProviderUsage(id: id, name: name)
    guard let binary = Shell.which("codex") else {
      usage.message = "`codex` CLI not found."
      return usage
    }
    // No auth.json check: Codex can keep its login in the system keyring, so
    // the app-server's answer is the only reliable signal.
    let response: JSON
    do {
      response = try await Self.readRateLimits(binary: binary)
    } catch {
      usage.message = "Codex app-server did not answer."
      return usage
    }
    if let error = response.object("error") {
      let text = error.string("message") ?? ""
      usage.needsLogin = Self.isLoginError(text)
      usage.message = usage.needsLogin
        ? "Not logged in with ChatGPT. Run `codex login` to see limits."
        : "Codex: \(text.isEmpty ? "could not read limits" : text)"
      return usage
    }
    let result = response.object("result") ?? [:]
    let parsed = Self.parse(result)
    usage.limits = parsed.limits
    usage.plan = parsed.plan
    usage.fetchedAt = Date()
    if usage.limits.isEmpty { usage.message = "Codex returned no limits." }
    return usage
  }

  /// Only explicit authentication failures count as a lost login; anything
  /// else (backend down, rate limits, URLs that mention chatgpt.com) keeps the
  /// last known numbers. The app-server says e.g. "codex account
  /// authentication required to read rate limits".
  static func isLoginError(_ text: String) -> Bool {
    let lower = text.lowercased()
    return ["authentication required", "not logged in", "login required", "not authenticated",
            "unauthorized", "please log in", "please login", "sign in again"].contains { lower.contains($0) }
  }

  // MARK: - Parsing

  static func parse(_ result: JSON) -> (limits: [UsageLimit], plan: String?) {
    // New app-servers return every metered bucket; `rateLimits` is the
    // backward-compatible single-bucket view. Never count both.
    var buckets: [(String, JSON)] = []
    if let byId = result.object("rateLimitsByLimitId") {
      buckets = byId.compactMap { key, value in (value as? JSON).map { (key, $0) } }
        .sorted { ($0.0 != "codex" ? 1 : 0, $0.0) < ($1.0 != "codex" ? 1 : 0, $1.0) }
    }
    if buckets.isEmpty, let legacy = result.object("rateLimits") {
      buckets = [("codex", legacy)]
    }

    var limits: [UsageLimit] = []
    for (limitId, bucket) in buckets {
      let general = limitId == "codex" || (buckets.count == 1 && bucket.string("limitName") == nil)
      let bucketName = bucket.string("limitName") ?? limitId
      for key in ["primary", "secondary"] {
        guard let window = bucket.object(key), let used = window.number("usedPercent") else { continue }
        let minutes = Int(window.number("windowDurationMins") ?? 0)
        let span = windowTitle(minutes)
        var title = general ? span : "\(bucketName) · \(span)"
        // Titles are the rows' identity in the panel; keep them unique.
        if limits.contains(where: { $0.title == title }) { title += " (\(key))" }
        limits.append(UsageLimit(title: title, used: used / 100, resetsAt: Dates.parse(window["resetsAt"])))
      }
    }

    let rawPlan = buckets.lazy.compactMap { $0.1.string("planType") }.first
      ?? result.object("rateLimits")?.string("planType")
    return (limits, rawPlan.map(planLabel))
  }

  static func windowTitle(_ minutes: Int) -> String {
    if minutes >= 28 * 24 * 60 { return "Monthly" }
    if minutes == 7 * 24 * 60 { return "Weekly" }
    if minutes >= 24 * 60 { return "\(minutes / (24 * 60))d" }
    if minutes > 0 { return minutes % 60 == 0 ? "Session (\(minutes / 60)h)" : "Session (\(minutes)m)" }
    return "Limit"
  }

  static func planLabel(_ raw: String) -> String {
    switch raw.lowercased() {
    case "plus": return "Plus"
    case "pro": return "Pro"
    case "team": return "Team"
    case "business": return "Business"
    case "enterprise": return "Enterprise"
    case "edu": return "Edu"
    case "free": return "Free"
    default: return raw.prefix(1).uppercased() + raw.dropFirst()
    }
  }

  // MARK: - JSON-RPC

  struct RPCError: Error {}

  /// Start `codex app-server`, initialize, ask for the limits, and stop it.
  static func readRateLimits(binary: URL, timeout: TimeInterval = 15) async throws -> JSON {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-s", "read-only", "-a", "on-request", "app-server"]
        process.environment = Shell.environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
          continuation.resume(throwing: error)
          return
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        let frames: [JSON] = [
          ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "agentwatcher", "version": "1"]]],
          ["method": "initialized", "params": [String: Any]()],
          ["id": 2, "method": "account/rateLimits/read", "params": [String: Any]()],
        ]
        for frame in frames {
          if var data = try? JSONSerialization.data(withJSONObject: frame) {
            data.append(0x0A)
            try? input.fileHandleForWriting.write(contentsOf: data)
          }
        }

        // Read line-delimited frames until the answer to request 2 arrives;
        // the killer closes the pipe if the server stalls.
        var answer: JSON?
        var buffer = Data()
        let reader = output.fileHandleForReading
        reading: while true {
          let chunk = reader.availableData
          if chunk.isEmpty { break }
          buffer.append(chunk)
          while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let frame = (try? JSONSerialization.jsonObject(with: line)) as? JSON,
               (frame["id"] as? NSNumber)?.intValue == 2 {
              answer = frame
              break reading
            }
          }
        }
        killer.cancel()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        if let answer {
          continuation.resume(returning: answer)
        } else {
          continuation.resume(throwing: RPCError())
        }
      }
    }
  }
}
