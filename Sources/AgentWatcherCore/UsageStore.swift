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
    public static let alertThreshold = "alertThreshold"
    public static let hiddenProviders = "hiddenProviders"
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

  /// Share of an allowance left at which the icon starts turning red.
  @Published public var alertThreshold: Double {
    didSet { defaults.set(alertThreshold, forKey: Keys.alertThreshold) }
  }

  /// Harnesses the user chose not to watch: not fetched, not shown, and
  /// never color the icon.
  @Published public private(set) var hiddenProviders: Set<String> {
    didSet { defaults.set(hiddenProviders.sorted(), forKey: Keys.hiddenProviders) }
  }

  nonisolated public static let allProviders: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), CursorProvider()]

  public let providers: [any UsageProvider]
  private let defaults: UserDefaults
  private var timer: Timer?

  public init(providers: [any UsageProvider] = UsageStore.allProviders, defaults: UserDefaults = .standard) {
    self.providers = providers
    self.defaults = defaults
    let interval = defaults.double(forKey: Keys.refreshInterval)
    refreshInterval = interval >= 60 ? interval : 300
    let threshold = defaults.double(forKey: Keys.alertThreshold)
    alertThreshold = threshold > 0 && threshold < 1 ? threshold : Alert.defaultThreshold
    hiddenProviders = Set(defaults.stringArray(forKey: Keys.hiddenProviders) ?? [])
  }

  public func isHidden(_ id: String) -> Bool { hiddenProviders.contains(id) }

  public func setHidden(_ id: String, _ hidden: Bool) {
    guard hidden != isHidden(id) else { return }
    if hidden {
      hiddenProviders.insert(id)
      usages.removeAll { $0.id == id }
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
      if self.pendingRefresh {
        self.pendingRefresh = false
        self.refresh()
      }
    }
  }

  public var worstRemaining: Double? { Alert.worstRemaining(usages) }

  public var severity: Double? {
    worstRemaining.flatMap { Alert.severity(remaining: $0, threshold: alertThreshold) }
  }
}
