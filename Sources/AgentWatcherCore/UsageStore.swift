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
      scheduleTimer()
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
    usages = (cache?.load() ?? []).filter { known.contains($0.id) && !hiddenProviders.contains($0.id) }
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
      refresh(force: true)
    }
  }

  // MARK: Refreshing

  public func start() {
    refresh()
    scheduleTimer()
  }

  private func scheduleTimer() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  /// Refresh unless the numbers are younger than `maxAge`. Opening the panel
  /// uses this so clicking around doesn't hammer the endpoints.
  public func refreshIfStale(maxAge: TimeInterval = 60) {
    if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
    refresh()
  }

  private var pendingRefresh = false

  public func refresh(force: Bool = false) {
    guard !isRefreshing else {
      // A harness shown mid-refresh still needs its own fetch.
      if force { pendingRefresh = true }
      return
    }
    isRefreshing = true
    let watched = providers.filter { !hiddenProviders.contains($0.id) && $0.isInstalled() }
    let previous = Dictionary(uniqueKeysWithValues: usages.map { ($0.id, $0) })
    Task {
      let fresh = await withTaskGroup(of: (Int, ProviderUsage).self) { group in
        for (index, provider) in watched.enumerated() {
          group.addTask { (index, await provider.fetch()) }
        }
        var results: [(Int, ProviderUsage)] = []
        for await result in group { results.append(result) }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
      }
      // Hidden while the fetch was in flight: drop it.
      self.usages = fresh
        .filter { !self.hiddenProviders.contains($0.id) }
        .map { $0.merged(withPrevious: previous[$0.id]) }
      self.lastRefresh = Date()
      self.isRefreshing = false
      self.cache?.save(self.usages)
      if self.pendingRefresh {
        self.pendingRefresh = false
        self.refresh()
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

/// The usages of the last check, on disk. Rewritten after every refresh.
public struct UsageCache: Sendable {
  public let url: URL

  public init(url: URL) { self.url = url }

  public static var defaultURL: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("AgentWatcher/usage.json")
  }

  private struct File: Codable {
    var savedAt: Date
    var usages: [ProviderUsage]
  }

  public func load() -> [ProviderUsage] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode(File.self, from: data))?.usages ?? []
  }

  public func save(_ usages: [ProviderUsage]) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(File(savedAt: Date(), usages: usages)) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }
}
