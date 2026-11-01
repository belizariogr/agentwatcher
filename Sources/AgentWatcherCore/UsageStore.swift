import Combine
import Foundation

@MainActor
public final class UsageStore: ObservableObject {
  @Published public private(set) var usages: [ProviderUsage] = []
  @Published public private(set) var isRefreshing = false
  @Published public private(set) var lastRefresh: Date?

  // MARK: Settings (persisted in UserDefaults)

  public enum Keys {
    public static let refreshInterval = "refreshInterval"
    /// Kept under its old name: it was the single threshold before there were two.
    public static let warningThreshold = "alertThreshold"
    public static let criticalThreshold = "criticalThreshold"
    public static let hiddenProviders = "hiddenProviders"
    /// Harness the tray icon follows. Absent means automatic: the tightest window.
    public static let pinnedProvider = "pinnedProvider"
  }

  public static let refreshIntervalChoices: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600]

  /// Seconds between automatic refreshes.
  @Published public var refreshInterval: TimeInterval {
    didSet {
      guard refreshInterval != oldValue else { return }
      defaults.set(refreshInterval, forKey: Keys.refreshInterval)
      if timer != nil { scheduleTimer() }
    }
  }

  /// Share of an allowance left at which the icon turns orange.
  @Published public var warningThreshold: Double {
    didSet {
      defaults.set(warningThreshold, forKey: Keys.warningThreshold)
      // Red always sits below orange.
      if criticalThreshold > warningThreshold - Alert.step / 2 {
        criticalThreshold = max(0, warningThreshold - Alert.step)
      }
    }
  }

  /// Share of an allowance left at which the icon turns red.
  @Published public var criticalThreshold: Double {
    didSet {
      defaults.set(criticalThreshold, forKey: Keys.criticalThreshold)
      if warningThreshold < criticalThreshold + Alert.step / 2 {
        warningThreshold = criticalThreshold + Alert.step
      }
    }
  }

  /// Harnesses the user chose not to watch: not fetched, not shown, and
  /// never color the icon.
  @Published public private(set) var hiddenProviders: Set<String> {
    didSet { defaults.set(hiddenProviders.sorted(), forKey: Keys.hiddenProviders) }
  }

  /// When set, the tray icon follows this harness. Nil is automatic: the
  /// account-level window closest to its limit, across every harness.
  @Published public private(set) var pinnedProviderID: String? {
    didSet {
      guard pinnedProviderID != oldValue else { return }
      if let pinnedProviderID {
        defaults.set(pinnedProviderID, forKey: Keys.pinnedProvider)
      } else {
        defaults.removeObject(forKey: Keys.pinnedProvider)
      }
    }
  }

  nonisolated public static let allProviders: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), CursorProvider()]

  public let providers: [any UsageProvider]
  private let defaults: UserDefaults
  private let cache: UsageCache?
  private var timer: Timer?
  /// When each harness was last checked and how its failures stand. Saved with
  /// the usages, so the schedule survives a relaunch.
  private var checks: [String: HarnessCheck] = [:]

  public init(
    providers: [any UsageProvider] = UsageStore.allProviders,
    defaults: UserDefaults = .standard,
    cacheURL: URL? = UsageCache.defaultURL
  ) {
    self.providers = providers
    self.defaults = defaults
    self.cache = cacheURL.map(UsageCache.init(url:))
    let interval = defaults.double(forKey: Keys.refreshInterval)
    refreshInterval = interval >= 60 ? interval : 300
    let storedWarning = defaults.double(forKey: Keys.warningThreshold)
    let warning = storedWarning > 0 && storedWarning < 1 ? storedWarning : Alert.defaultWarning
    let storedCritical = defaults.object(forKey: Keys.criticalThreshold) as? Double
    warningThreshold = warning
    if let storedCritical, storedCritical >= 0, storedCritical < warning {
      criticalThreshold = storedCritical
    } else {
      criticalThreshold = Alert.defaultCritical < warning ? Alert.defaultCritical : max(0, warning - Alert.step)
    }
    hiddenProviders = Set(defaults.stringArray(forKey: Keys.hiddenProviders) ?? [])
    let storedPin = defaults.string(forKey: Keys.pinnedProvider)
    pinnedProviderID = storedPin?.isEmpty == false ? storedPin : nil
    // Last known numbers, so a rate-limited first refresh after launch still
    // has something to show and to fall back on.
    let known = Set(providers.map(\.id))
    let stored = cache?.read()
    usages = (stored?.usages ?? []).filter { known.contains($0.id) && !hiddenProviders.contains($0.id) }
    // When they were checked, so a relaunch doesn't check ahead of the interval.
    // Files from older versions only have the time of the whole check.
    lastRefresh = stored?.savedAt
    checks = stored?.checks ?? [:]
    if let savedAt = stored?.savedAt {
      for usage in usages where checks[usage.id] == nil {
        checks[usage.id] = HarnessCheck(lastCheck: savedAt)
      }
    }
  }

  public func isHidden(_ id: String) -> Bool { hiddenProviders.contains(id) }

  /// Selects `id` for the tray icon, or returns to automatic when it is already selected.
  public func togglePinnedProvider(_ id: String) {
    pinnedProviderID = pinnedProviderID == id ? nil : id
  }

  public func setHidden(_ id: String, _ hidden: Bool) {
    guard hidden != isHidden(id) else { return }
    if hidden {
      hiddenProviders.insert(id)
      usages.removeAll { $0.id == id }
      if pinnedProviderID == id { pinnedProviderID = nil }
    } else {
      hiddenProviders.remove(id)
      // It has nothing to show yet. Mid-refresh, it gets its own fetch after.
      if isRefreshing { pendingRefresh.insert(id) } else { fetch([id]) }
    }
  }

  // MARK: Refreshing

  public func start() {
    refreshIfStale()
    scheduleTimer()
  }

  private func scheduleTimer() {
    timer?.invalidate()
    let timer = Timer(fire: nextRefresh(), interval: 0, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.refreshIfStale() }
    }
    RunLoop.main.add(timer, forMode: .default)
    self.timer = timer
  }

  private var watchedProviders: [any UsageProvider] {
    providers.filter { !hiddenProviders.contains($0.id) && $0.isInstalled() }
  }

  /// A harness never checked is due right away.
  private func due(_ provider: any UsageProvider, now: Date) -> Date {
    checks[provider.id]?.due(interval: refreshInterval, now: now) ?? now
  }

  /// When the next automatic check is due, for whichever harness comes first.
  public func nextRefresh(now: Date = Date()) -> Date {
    watchedProviders.map { due($0, now: now) }.min() ?? now.addingTimeInterval(refreshInterval)
  }

  /// Failures in a row of a harness' current cycle.
  public func failureCount(_ id: String) -> Int { checks[id]?.failures ?? 0 }

  /// Checks only the harnesses that are due, so retrying one never hits the
  /// others ahead of the interval. Launching, waking the Mac and the timer all
  /// come through here.
  public func refreshIfStale(now: Date = Date()) {
    let ids = watchedProviders.filter { due($0, now: now) <= now }.map(\.id)
    if ids.isEmpty {
      if timer != nil { scheduleTimer() }
    } else {
      fetch(Set(ids))
    }
  }

  private var pendingRefresh: Set<String> = []

  /// Checks every harness now, whatever is due.
  public func refresh() { fetch(nil) }

  private func fetch(_ ids: Set<String>?) {
    guard !isRefreshing else { return }
    isRefreshing = true
    let watched = watchedProviders.filter { ids?.contains($0.id) ?? true }
    Task {
      let fresh = await withTaskGroup(of: ProviderUsage.self) { group in
        for provider in watched {
          group.addTask { await provider.fetch() }
        }
        var results: [ProviderUsage] = []
        for await result in group { results.append(result) }
        return results
      }
      let now = Date()
      // A partial check leaves the other harnesses as they are; a full one
      // also drops what is no longer installed.
      var latest = ids == nil ? [:] : Dictionary(uniqueKeysWithValues: self.usages.map { ($0.id, $0) })
      let previous = Dictionary(uniqueKeysWithValues: self.usages.map { ($0.id, $0) })
      for usage in fresh {
        latest[usage.id] = usage.merged(withPrevious: previous[usage.id])
        self.checks[usage.id] = (self.checks[usage.id] ?? HarnessCheck(lastCheck: now)).recording(usage, at: now)
      }
      // Hidden while the fetch was in flight: drop it.
      self.usages = self.providers.compactMap { latest[$0.id] }.filter { !self.hiddenProviders.contains($0.id) }
      self.lastRefresh = now
      self.isRefreshing = false
      self.cache?.save(self.usages, at: now, checks: self.checks)
      if !self.pendingRefresh.isEmpty {
        let pending = self.pendingRefresh
        self.pendingRefresh = []
        self.fetch(pending)
      } else if self.timer != nil {
        self.scheduleTimer()
      }
    }
  }

  public var worstRemaining: Double? { Alert.worstRemaining(usages) }

  /// Remaining allowance drawn on the tray icon.
  public var iconRemaining: Double? {
    if let id = pinnedProviderID, let usage = usages.first(where: { $0.id == id }) {
      return usage.tightest()?.remaining()
    }
    return worstRemaining
  }

  public var alertLevel: AlertLevel? {
    iconRemaining.flatMap { alertLevel(remaining: $0) }
  }

  public func alertLevel(remaining: Double) -> AlertLevel? {
    Alert.level(remaining: remaining, warning: warningThreshold, critical: criticalThreshold)
  }

  /// What the menu bar icon is drawn in; nil keeps the system color.
  public var alertColor: RGB? {
    iconRemaining.flatMap { Alert.color(remaining: $0, warning: warningThreshold, critical: criticalThreshold) }
  }
}

/// When a harness was last checked and how many failures it has in a row.
public struct HarnessCheck: Codable, Equatable, Sendable {
  /// Failures in a row that retry after `retryDelay`: the first and the second.
  /// The third waits the regular interval, and the next failure starts over.
  public static let failuresPerCycle = 3
  public static let retryDelay: TimeInterval = 60
  /// A check further ahead than this means the clock changed: check right away.
  public static let clockTolerance: TimeInterval = 600

  public var lastCheck: Date
  public var failures: Int

  public init(lastCheck: Date, failures: Int = 0) {
    self.lastCheck = lastCheck
    self.failures = failures
  }

  public func recording(_ usage: ProviderUsage, at date: Date) -> HarnessCheck {
    guard usage.isTemporaryFailure else { return HarnessCheck(lastCheck: date) }
    return HarnessCheck(lastCheck: date, failures: failures >= Self.failuresPerCycle ? 1 : failures + 1)
  }

  public func due(interval: TimeInterval, now: Date) -> Date {
    if lastCheck.timeIntervalSince(now) > Self.clockTolerance { return now }
    let retrying = failures > 0 && failures < Self.failuresPerCycle
    return lastCheck.addingTimeInterval(retrying ? Self.retryDelay : interval)
  }
}

/// The usages of the last check, on disk. Rewritten after every refresh.
public struct UsageCache: Sendable {
  public let url: URL

  public init(url: URL) { self.url = url }

  public static var defaultURL: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("AgentWatcher/usage.json")
  }

  fileprivate struct File: Codable {
    var savedAt: Date
    var usages: [ProviderUsage]
    /// Absent in files from older versions.
    var checks: [String: HarnessCheck]?
  }

  public func load() -> [ProviderUsage] { read()?.usages ?? [] }

  fileprivate func read() -> File? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(File.self, from: data)
  }

  public func save(_ usages: [ProviderUsage], at savedAt: Date = Date(), checks: [String: HarnessCheck]? = nil) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(File(savedAt: savedAt, usages: usages, checks: checks)) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }
}
