import Combine
import Foundation

@MainActor
public final class UsageStore: ObservableObject {
  @Published public private(set) var usages: [ProviderUsage] = []
  @Published public private(set) var isRefreshing = false
  @Published public private(set) var lastRefresh: Date?

  nonisolated public static let allProviders: [any UsageProvider] = [ClaudeProvider(), CodexProvider()]

  private let providers: [any UsageProvider]
  private var timer: Timer?

  /// Seconds between automatic refreshes. `defaults write
  /// com.belizariogr.agentwatcher refreshInterval -int 120` to change.
  public var refreshInterval: TimeInterval {
    let stored = UserDefaults.standard.double(forKey: "refreshInterval")
    return stored >= 60 ? stored : 300
  }

  /// Share of an allowance left at which the icon starts turning red.
  /// `defaults write com.belizariogr.agentwatcher alertThreshold -float 0.15`.
  public var alertThreshold: Double {
    let stored = UserDefaults.standard.double(forKey: "alertThreshold")
    return stored > 0 && stored < 1 ? stored : Alert.defaultThreshold
  }

  public init(providers: [any UsageProvider] = UsageStore.allProviders) {
    self.providers = providers
  }

  public func start() {
    refresh()
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

  public func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    let installed = providers.filter { $0.isInstalled() }
    let previous = Dictionary(uniqueKeysWithValues: usages.map { ($0.id, $0) })
    Task {
      let fresh = await withTaskGroup(of: (Int, ProviderUsage).self) { group in
        for (index, provider) in installed.enumerated() {
          group.addTask { (index, await provider.fetch()) }
        }
        var results: [(Int, ProviderUsage)] = []
        for await result in group { results.append(result) }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
      }
      self.usages = fresh.map { $0.merged(withPrevious: previous[$0.id]) }
      self.lastRefresh = Date()
      self.isRefreshing = false
    }
  }

  public var worstRemaining: Double? { Alert.worstRemaining(usages) }

  public var severity: Double? {
    worstRemaining.flatMap { Alert.severity(remaining: $0, threshold: alertThreshold) }
  }
}
