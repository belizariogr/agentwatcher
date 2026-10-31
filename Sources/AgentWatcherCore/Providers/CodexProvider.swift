import Foundation

/// Codex: limits and plan come from the CLI's own app-server over JSON-RPC
/// (`account/rateLimits/read`), so no token ever leaves the CLI.
public struct CodexProvider: UsageProvider {
  public let id = "codex"
  public let name = "Codex"

  public init() {}

  var codexHome: URL {
    if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
      return URL(fileURLWithPath: NSString(string: custom).expandingTildeInPath)
    }
    return Shell.home.appendingPathComponent(".codex")
  }

  public func isInstalled() -> Bool {
    Shell.which("codex") != nil
  }

  public func fetch() async -> ProviderUsage {
    var usage = ProviderUsage(id: id, name: name)
    guard let binary = Shell.which("codex") else {
      usage.message = "CLI `codex` não encontrado."
      return usage
    }
    guard FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path) else {
      usage.message = "Sem login. Rode `codex login` para ver os limites."
      return usage
    }

    let response: JSON
    do {
      response = try await Self.readRateLimits(binary: binary)
    } catch {
      usage.message = "O app-server do Codex não respondeu."
      return usage
    }
    if let error = response.object("error") {
      let text = error.string("message") ?? ""
      usage.message = text.localizedCaseInsensitiveContains("chatgpt") || text.localizedCaseInsensitiveContains("auth")
        ? "Limites só existem com login ChatGPT (`codex login`)."
        : "Codex: \(text.isEmpty ? "erro ao ler limites" : text)"
      return usage
    }
    let result = response.object("result") ?? [:]
    let parsed = Self.parse(result)
    usage.limits = parsed.limits
    usage.plan = parsed.plan
    usage.fetchedAt = Date()
    if usage.limits.isEmpty { usage.message = "O Codex não retornou limites." }
    return usage
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
        let title = general ? span : "\(bucketName) · \(span)"
        limits.append(UsageLimit(title: title, used: used / 100, resetsAt: Dates.parse(window["resetsAt"])))
      }
    }

    let rawPlan = buckets.lazy.compactMap { $0.1.string("planType") }.first
      ?? result.object("rateLimits")?.string("planType")
    return (limits, rawPlan.map(planLabel))
  }

  static func windowTitle(_ minutes: Int) -> String {
    if minutes >= 28 * 24 * 60 { return "Mensal" }
    if minutes == 7 * 24 * 60 { return "Semanal" }
    if minutes >= 24 * 60 { return "\(minutes / (24 * 60))d" }
    if minutes > 0 { return minutes % 60 == 0 ? "Sessão (\(minutes / 60)h)" : "Sessão (\(minutes)m)" }
    return "Limite"
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
