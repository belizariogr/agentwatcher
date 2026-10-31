import Foundation

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
  func object(_ key: String) -> JSON? { self[key] as? JSON }
  func string(_ key: String) -> String? {
    guard let s = self[key] as? String, !s.isEmpty else { return nil }
    return s
  }
  func number(_ key: String) -> Double? {
    if let n = self[key] as? NSNumber {
      // NSNumber(0) and NSNumber(1) bridge to Bool, so ask CoreFoundation.
      if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
      return n.doubleValue.isFinite ? n.doubleValue : nil
    }
    if let s = self[key] as? String { return Double(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
    return nil
  }
}

enum Dates {
  /// ISO-8601 with or without fractional seconds, or a unix timestamp in
  /// seconds or milliseconds.
  static func parse(_ value: Any?) -> Date? {
    if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
      let t = n.doubleValue
      guard t > 0 else { return nil }
      return Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t)
    }
    guard var s = value as? String, !s.isEmpty else { return nil }
    if let t = Double(s) { return parse(NSNumber(value: t)) }
    // ISO8601DateFormatter accepts at most millisecond precision.
    if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
      let digits = s[s.index(after: dot)..<end]
      if digits.count > 3 { s.replaceSubrange(s.index(dot, offsetBy: 4)..<end, with: "") }
    }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
  }
}

enum Shell {
  static let home = FileManager.default.homeDirectoryForCurrentUser

  /// GUI apps start with a bare PATH; harness CLIs live in the user's.
  static let searchPath: [String] = {
    var dirs = [
      "~/.local/bin", "~/.bun/bin", "~/.npm-global/bin", "~/.volta/bin", "~/.cargo/bin",
      "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
    ].map { NSString(string: $0).expandingTildeInPath }
    let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for dir in inherited where !dirs.contains(dir) { dirs.append(dir) }
    return dirs
  }()

  static var environment: [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = searchPath.joined(separator: ":")
    return env
  }

  static func which(_ name: String) -> URL? {
    for dir in searchPath {
      let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    return nil
  }

  /// Run a short command and return its stdout, or nil when it fails.
  static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    killer.cancel()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// `run` off Swift's cooperative pool: these calls block (a Keychain
  /// prompt can hold `security` for seconds) and must not starve other tasks.
  static func output(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) async -> String? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: run(executable, arguments, timeout: timeout))
      }
    }
  }

  static func readJSON(_ url: URL) -> JSON? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? JSON
  }
}
