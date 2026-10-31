import Combine
import CryptoKit
import Foundation
import Security

/// A dotted numeric version (`1.2.3`, with or without a leading `v`).
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
  public let parts: [Int]

  public init?(_ string: String) {
    var s = string.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
    let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
    self.parts = parts.map { $0! }
  }

  public static func < (a: AppVersion, b: AppVersion) -> Bool {
    for i in 0..<max(a.parts.count, b.parts.count) {
      let x = i < a.parts.count ? a.parts[i] : 0
      let y = i < b.parts.count ? b.parts[i] : 0
      if x != y { return x < y }
    }
    return false
  }

  public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

  public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// The parts of a GitHub release the updater needs.
public struct ReleaseInfo: Equatable, Sendable {
  public let version: AppVersion
  public let tag: String
  public let pageURL: URL
  public let dmgName: String
  public let dmgURL: URL
  public let checksumsURL: URL?

  /// Parses `GET /repos/{owner}/{repo}/releases/latest`. Nil for drafts,
  /// prereleases, tags that aren't versions, or a release without a DMG.
  public static func parse(_ data: Data) -> ReleaseInfo? {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
          json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
          let tag = json.string("tag_name"), let version = AppVersion(tag),
          let page = json.string("html_url").flatMap(URL.init(string:)) else { return nil }
    let assets = (json["assets"] as? [JSON] ?? []).compactMap { asset -> (String, URL)? in
      guard let name = asset.string("name"),
            let url = asset.string("browser_download_url").flatMap(URL.init(string:)),
            url.scheme == "https" else { return nil }
      return (name, url)
    }
    guard let dmg = assets.first(where: { $0.0.hasPrefix("AgentWatcher-") && $0.0.hasSuffix(".dmg") }) else { return nil }
    let sums = assets.first(where: { $0.0 == "SHA256SUMS.txt" })?.1
    return ReleaseInfo(version: version, tag: tag, pageURL: page, dmgName: dmg.0, dmgURL: dmg.1, checksumsURL: sums)
  }

  /// The hash for `name` in a `shasum -a 256` listing.
  public static func checksum(for name: String, in listing: String) -> String? {
    for line in listing.split(whereSeparator: \.isNewline) {
      let fields = line.split(separator: " ", omittingEmptySubsequences: true)
      guard fields.count >= 2 else { continue }
      var file = String(fields[1])
      if file.hasPrefix("*") { file.removeFirst() } // binary-mode marker
      let hash = fields[0].lowercased()
      if file == name, hash.count == 64, hash.allSatisfy(\.isHexDigit) { return hash }
    }
    return nil
  }
}

public enum UpdateError: LocalizedError {
  case network(String)
  case badRelease
  case checksumMismatch
  case badSignature
  case notInstallable(String)
  case install(String)

  public var errorDescription: String? {
    switch self {
    case .network(let m): return "Couldn't reach GitHub: \(m)"
    case .badRelease: return "The latest release has no usable DMG."
    case .checksumMismatch: return "The download doesn't match the release's SHA-256."
    case .badSignature: return "The downloaded app isn't signed by the Agent Watcher developer."
    case .notInstallable(let m): return m
    case .install(let m): return "Install failed: \(m)"
    }
  }
}

/// Checks the GitHub "latest release" and, when it is newer, downloads the
/// DMG, verifies it (SHA-256 + Developer ID of the same team), swaps the app
/// bundle in place and relaunches.
@MainActor
public final class Updater: ObservableObject {
  public enum State: Equatable {
    case idle
    case checking
    case upToDate
    case available(ReleaseInfo)
    case installing(ReleaseInfo)
    case failed(String)
  }

  public enum Keys {
    public static let checkAutomatically = "checkForUpdates"
    public static let installAutomatically = "installUpdatesAutomatically"
    public static let lastCheck = "lastUpdateCheck"
  }

  nonisolated public static let repository = "belizariogr/agentwatcher"
  nonisolated public static let teamID = "3Z7C3Q7NMT"
  nonisolated public static let bundleID = "com.belizariogr.agentwatcher"
  nonisolated public static let checkInterval: TimeInterval = 6 * 3600
  nonisolated public static var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }
  nonisolated static var latestURL: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }

  @Published public private(set) var state: State = .idle
  @Published public private(set) var lastCheck: Date?

  @Published public var checkAutomatically: Bool {
    didSet {
      defaults.set(checkAutomatically, forKey: Keys.checkAutomatically)
      scheduleTimer()
    }
  }

  @Published public var installAutomatically: Bool {
    didSet { defaults.set(installAutomatically, forKey: Keys.installAutomatically) }
  }

  public let currentVersion: AppVersion?
  public let versionString: String
  public let buildString: String
  public let bundleURL: URL
  /// Called after the new bundle is in place; the app should quit so the
  /// relauncher can open the new copy.
  public var onWillRelaunch: () -> Void = {}
  /// Auto-install waits while this returns true (e.g. the panel is open).
  public var isBusy: () -> Bool = { false }

  private let defaults: UserDefaults
  private var timer: Timer?

  public init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    bundleURL = bundle.bundleURL
    versionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    buildString = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    currentVersion = AppVersion(versionString)
    checkAutomatically = defaults.object(forKey: Keys.checkAutomatically) as? Bool ?? true
    installAutomatically = defaults.object(forKey: Keys.installAutomatically) as? Bool ?? true
    lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
  }

  // MARK: Installability

  /// Why this copy can't replace itself, or nil when it can.
  public var notInstallableReason: String? {
    guard bundleURL.pathExtension == "app" else { return "Updates only install into the AgentWatcher.app bundle." }
    if bundleURL.path.contains("/AppTranslocation/") {
      return "Move Agent Watcher to the Applications folder to install updates."
    }
    let parent = bundleURL.deletingLastPathComponent().path
    guard FileManager.default.isWritableFile(atPath: parent) else {
      return "No permission to replace the app in \(parent)."
    }
    return nil
  }

  /// Release builds (Developer ID of our team) update themselves; local
  /// `make install` builds only report that an update exists.
  public var isReleaseBuild: Bool { Self.isSignedByTeam(bundleURL) }

  // MARK: Scheduling

  public func start() {
    scheduleTimer()
    guard checkAutomatically else { return }
    // Shortly after launch, unless a check ran recently.
    let due = lastCheck.map { Date().timeIntervalSince($0) >= Self.checkInterval } ?? true
    if due {
      Task {
        try? await Task.sleep(for: .seconds(20))
        self.check(userInitiated: false)
      }
    }
  }

  private func scheduleTimer() {
    timer?.invalidate()
    timer = nil
    guard checkAutomatically else { return }
    // Hourly tick; a check runs once the interval since the last one passed.
    // An `available` update waiting for the panel to close is retried too.
    timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
  }

  private func tick() {
    if case .available(let release) = state, shouldAutoInstall {
      install(release)
      return
    }
    if lastCheck.map({ Date().timeIntervalSince($0) >= Self.checkInterval }) ?? true {
      check(userInitiated: false)
    }
  }

  private var shouldAutoInstall: Bool {
    installAutomatically && isReleaseBuild && notInstallableReason == nil && !isBusy()
  }

  // MARK: Check

  public func check(userInitiated: Bool = true) {
    switch state {
    case .checking, .installing: return
    default: break
    }
    state = .checking
    Task {
      do {
        let release = try await Self.fetchLatest()
        lastCheck = Date()
        defaults.set(lastCheck, forKey: Keys.lastCheck)
        guard let release, let current = currentVersion, release.version > current else {
          state = .upToDate
          return
        }
        state = .available(release)
        if !userInitiated, shouldAutoInstall { install(release) }
      } catch {
        // Background checks fail quietly (offline, GitHub rate limit).
        state = userInitiated ? .failed(error.localizedDescription) : .idle
      }
    }
  }

  nonisolated static func fetchLatest() async throws -> ReleaseInfo? {
    var request = URLRequest(url: latestURL, timeoutInterval: 30)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("AgentWatcher", forHTTPHeaderField: "User-Agent")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let data: Data, response: URLResponse
    do { (data, response) = try await URLSession.shared.data(for: request) } catch {
      throw UpdateError.network(error.localizedDescription)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 404 { return nil } // no release published yet
    guard status == 200 else { throw UpdateError.network("HTTP \(status)") }
    guard let release = ReleaseInfo.parse(data) else { throw UpdateError.badRelease }
    return release
  }

  // MARK: Install

  public func install(_ release: ReleaseInfo) {
    if case .installing = state { return }
    if let reason = notInstallableReason {
      state = .failed(reason)
      return
    }
    state = .installing(release)
    let bundleURL = self.bundleURL
    Task {
      do {
        try await Task.detached(priority: .utility) {
          try await Self.downloadAndReplace(release, at: bundleURL)
        }.value
        Self.relaunch(bundleURL)
        onWillRelaunch()
      } catch {
        state = .failed(error.localizedDescription)
      }
    }
  }

  nonisolated static func downloadAndReplace(_ release: ReleaseInfo, at bundleURL: URL) async throws {
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("AgentWatcher-update-\(UUID().uuidString)")
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }

    // Download and check the SHA-256 published with the release.
    let dmg = work.appendingPathComponent(release.dmgName)
    do {
      let (tmp, response) = try await URLSession.shared.download(from: release.dmgURL)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.network("download failed") }
      try fm.moveItem(at: tmp, to: dmg)
    } catch let error as UpdateError { throw error } catch {
      throw UpdateError.network(error.localizedDescription)
    }
    if let sumsURL = release.checksumsURL {
      let (sums, _) = try await URLSession.shared.data(from: sumsURL)
      guard let expected = ReleaseInfo.checksum(for: release.dmgName, in: String(decoding: sums, as: UTF8.self)),
            try sha256(of: dmg) == expected else { throw UpdateError.checksumMismatch }
    }

    // Mount, copy the app next to the installed one (same volume, so the
    // swap is a rename), unmount.
    let mount = work.appendingPathComponent("mount")
    try fm.createDirectory(at: mount, withIntermediateDirectories: true)
    guard Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-quiet",
                                         "-mountpoint", mount.path, dmg.path], timeout: 120) != nil else {
      throw UpdateError.install("couldn't open the DMG")
    }
    let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                             appropriateFor: bundleURL, create: true)
    defer { try? fm.removeItem(at: staging) }
    let newApp = staging.appendingPathComponent(bundleURL.lastPathComponent)
    let copied = Shell.run("/usr/bin/ditto", [mount.appendingPathComponent("AgentWatcher.app").path, newApp.path], timeout: 120)
    _ = Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"], timeout: 60)
    guard copied != nil else { throw UpdateError.install("couldn't copy the app from the DMG") }

    // Only an intact app, signed by our team, with our bundle id.
    guard isSignedByTeam(newApp),
          Bundle(url: newApp)?.bundleIdentifier == bundleID else { throw UpdateError.badSignature }

    do {
      _ = try fm.replaceItemAt(bundleURL, withItemAt: newApp, backupItemName: nil, options: [])
    } catch {
      throw UpdateError.install(error.localizedDescription)
    }
  }

  nonisolated static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Valid, strict, all architectures, Developer ID of `teamID`.
  nonisolated static func isSignedByTeam(_ url: URL) -> Bool {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
    let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
      + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
  }

  /// Opens the app at `url` once this process is gone.
  nonisolated static func relaunch(_ url: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                         "relaunch", String(ProcessInfo.processInfo.processIdentifier), url.path]
    try? process.run()
  }
}
