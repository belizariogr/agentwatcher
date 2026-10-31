@testable import AgentWatcherCore
import XCTest

final class AlertTests: XCTestCase {
  func testNoAlertAboveThreshold() {
    XCTAssertNil(Alert.severity(remaining: 0.16, threshold: 0.15))
    XCTAssertNil(Alert.severity(remaining: 1, threshold: 0.15))
  }

  func testSeverityRampsToRed() {
    XCTAssertEqual(Alert.severity(remaining: 0.15, threshold: 0.15)!, 0, accuracy: 1e-9)
    XCTAssertEqual(Alert.severity(remaining: 0.075, threshold: 0.15)!, 0.5, accuracy: 1e-9)
    XCTAssertEqual(Alert.severity(remaining: 0, threshold: 0.15)!, 1, accuracy: 1e-9)
    XCTAssertEqual(Alert.color(severity: 0), Alert.yellow)
    XCTAssertEqual(Alert.color(severity: 0.5), Alert.orange)
    XCTAssertEqual(Alert.color(severity: 1), Alert.red)
  }

  func testWorstRemainingAcrossProviders() {
    let future = Date().addingTimeInterval(3600)
    let a = ProviderUsage(id: "a", name: "A", limits: [UsageLimit(title: "s", used: 0.2, resetsAt: future)])
    let b = ProviderUsage(id: "b", name: "B", limits: [
      UsageLimit(title: "s", used: 0.5, resetsAt: future),
      UsageLimit(title: "w", used: 0.93, resetsAt: future),
    ])
    XCTAssertEqual(Alert.worstRemaining([a, b])!, 0.07, accuracy: 1e-9)
  }

  func testExpiredWindowCountsAsEmpty() {
    let limit = UsageLimit(title: "s", used: 0.99, resetsAt: Date().addingTimeInterval(-1))
    XCTAssertEqual(limit.remaining(), 1)
  }

  func testFailedRefreshKeepsLastGoodLimits() {
    let old = ProviderUsage(id: "c", name: "C", plan: "Max", limits: [UsageLimit(title: "w", used: 0.4, resetsAt: nil)], fetchedAt: Date())
    let failed = ProviderUsage(id: "c", name: "C", message: "429")
    let merged = failed.merged(withPrevious: old)
    XCTAssertEqual(merged.limits, old.limits)
    XCTAssertEqual(merged.message, "429")
    XCTAssertEqual(merged.plan, "Max")
  }

  func testLostLoginDropsLastKnownLimits() {
    let old = ProviderUsage(id: "c", name: "C", plan: "Max", limits: [UsageLimit(title: "w", used: 0.4, resetsAt: nil)], fetchedAt: Date())
    let loggedOut = ProviderUsage(id: "c", name: "C", message: "Not logged in", needsLogin: true)
    XCTAssertEqual(loggedOut.merged(withPrevious: old), loggedOut)
  }
}

final class ClaudeParsingTests: XCTestCase {
  func testParsesWindowsAndScopedLimits() {
    let payload: [String: Any] = [
      "five_hour": NSNull(),
      "seven_day": ["utilization": 93.0, "resets_at": "2026-11-02T07:00:00.349888+00:00"],
      "limits": [
        ["kind": "weekly_all", "percent": 93, "scope": NSNull()],
        ["kind": "weekly_scoped", "percent": 5, "resets_at": "2026-11-02T07:00:00.350072+00:00",
         "scope": ["model": ["id": NSNull(), "display_name": "Fable"]]],
      ],
    ]
    let limits = ClaudeProvider.parseLimits(payload)
    XCTAssertEqual(limits.map(\.title), ["Weekly", "Fable · Weekly"])
    XCTAssertEqual(limits[0].used, 0.93, accuracy: 1e-9)
    XCTAssertNotNil(limits[0].resetsAt)
    XCTAssertEqual(limits[1].used, 0.05, accuracy: 1e-9)
  }

  func testPlanLabel() {
    XCTAssertEqual(ClaudeProvider.planLabel(tier: "default_claude_max_20x", subscription: "max"), "Max 20x")
    XCTAssertEqual(ClaudeProvider.planLabel(tier: "default_claude_max_5x", subscription: "team"), "Team 5x")
    XCTAssertEqual(ClaudeProvider.planLabel(tier: nil, subscription: "pro"), "Pro")
  }
}

final class CodexParsingTests: XCTestCase {
  func testParsesBuckets() {
    let window: (Double, Int) -> [String: Any] = { ["usedPercent": $0, "windowDurationMins": $1, "resetsAt": 1793479334] }
    let bucket: [String: Any] = ["limitId": "codex", "primary": window(0, 300), "secondary": window(35, 10080), "planType": "plus"]
    let result: [String: Any] = ["rateLimits": bucket, "rateLimitsByLimitId": ["codex": bucket]]
    let parsed = CodexProvider.parse(result)
    XCTAssertEqual(parsed.plan, "Plus")
    XCTAssertEqual(parsed.limits.map(\.title), ["Session (5h)", "Weekly"])
    XCTAssertEqual(parsed.limits[1].used, 0.35, accuracy: 1e-9)
  }

  func testZeroPercentFromRealJSONIsKept() throws {
    let json = #"{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1793479334},"secondary":{"usedPercent":35,"windowDurationMins":10080,"resetsAt":1793799273},"planType":"plus","individualLimit":null}}"#
    let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let parsed = CodexProvider.parse(result)
    XCTAssertEqual(parsed.limits.map(\.title), ["Session (5h)", "Weekly"])
    XCTAssertEqual(parsed.limits[0].used, 0)
    XCTAssertNotNil(parsed.limits[0].resetsAt)
  }

  func testModelBucketIsTitledByName() {
    let general: [String: Any] = ["primary": ["usedPercent": 10, "windowDurationMins": 300]]
    let model: [String: Any] = ["limitName": "GPT-5 Pro", "secondary": ["usedPercent": 50, "windowDurationMins": 10080]]
    let parsed = CodexProvider.parse(["rateLimitsByLimitId": ["codex": general, "gpt5pro": model]])
    XCTAssertEqual(parsed.limits.map(\.title), ["Session (5h)", "GPT-5 Pro · Weekly"])
  }
}

final class CursorParsingTests: XCTestCase {
  func testParsesPoolsFromRealJSON() throws {
    let raw = #"{"billingCycleStart":"1791982045000","billingCycleEnd":"1794660445000","planUsage":{"totalSpend":115072,"includedSpend":7000,"limit":7000,"autoPercentUsed":91.74,"apiPercentUsed":45.29,"totalPercentUsed":87.84},"enabled":true}"#
    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? JSON)
    let limits = CursorProvider.parseLimits(payload)
    XCTAssertEqual(limits.map(\.title), ["Cursor Models", "Other Models"])
    XCTAssertEqual(limits[0].used, 0.9174, accuracy: 1e-6)
    XCTAssertEqual(limits[0].resetsAt, Date(timeIntervalSince1970: 1794660445))
  }

  func testFallsBackToIncludedSpend() {
    let limits = CursorProvider.parseLimits(["planUsage": ["includedSpend": 1500, "limit": 2000] as JSON])
    XCTAssertEqual(limits.map(\.title), ["Monthly"])
    XCTAssertEqual(limits[0].used, 0.75, accuracy: 1e-9)
  }

  func testTokenExpiryFromJWT() {
    let claims = Data(#"{"exp":1798152383}"#.utf8).base64EncodedString()
      .replacingOccurrences(of: "=", with: "")
    XCTAssertEqual(CursorProvider.expiry(of: "x.\(claims).y"), Date(timeIntervalSince1970: 1798152383))
  }
}

struct FakeProvider: UsageProvider {
  let id: String
  let name: String
  let used: Double
  func isInstalled() -> Bool { true }
  func fetch() async -> ProviderUsage {
    ProviderUsage(id: id, name: name, limits: [UsageLimit(title: "w", used: used, resetsAt: nil)], fetchedAt: Date())
  }
}

@MainActor
final class StoreSettingsTests: XCTestCase {
  func makeStore(_ suite: String) -> (UsageStore, UserDefaults) {
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = UsageStore(providers: [
      FakeProvider(id: "a", name: "A", used: 0.2),
      FakeProvider(id: "b", name: "B", used: 0.95),
    ], defaults: defaults, cacheURL: nil)
    return (store, defaults)
  }

  func waitForRefresh(_ store: UsageStore) async {
    while store.isRefreshing || store.lastRefresh == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
  }

  func testHiddenHarnessIsNotFetchedAndDoesNotColorTheIcon() async {
    let (store, defaults) = makeStore("aw.test.hidden")
    store.setHidden("b", true)
    store.refresh()
    await waitForRefresh(store)
    XCTAssertEqual(store.usages.map(\.id), ["a"])
    XCTAssertNil(store.severity)
    XCTAssertEqual(defaults.stringArray(forKey: UsageStore.Keys.hiddenProviders), ["b"])

    store.setHidden("b", false)
    await waitForRefresh(store)
    XCTAssertEqual(store.usages.map(\.id), ["a", "b"])
    XCTAssertNotNil(store.severity)
  }

  func testSettingsPersist() {
    let (store, defaults) = makeStore("aw.test.persist")
    store.refreshInterval = 600
    store.alertThreshold = 0.25
    let reloaded = UsageStore(providers: [], defaults: defaults, cacheURL: nil)
    XCTAssertEqual(reloaded.refreshInterval, 600)
    XCTAssertEqual(reloaded.alertThreshold, 0.25)
  }
}

struct RateLimitedProvider: UsageProvider {
  let id: String
  let name: String
  func isInstalled() -> Bool { true }
  func fetch() async -> ProviderUsage { ProviderUsage(id: id, name: name, message: "rate limited") }
}

@MainActor
final class UsageCacheTests: XCTestCase {
  func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("aw-\(UUID().uuidString)/usage.json")
  }

  func waitForRefresh(_ store: UsageStore) async {
    while store.isRefreshing || store.lastRefresh == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
  }

  func testEveryRefreshIsSavedToDisk() async {
    let url = tempURL()
    let store = UsageStore(providers: [FakeProvider(id: "a", name: "A", used: 0.3)], defaults: .init(suiteName: "aw.test.cache1")!, cacheURL: url)
    store.refresh()
    await waitForRefresh(store)
    let saved = UsageCache(url: url).load()
    XCTAssertEqual(saved.map(\.id), ["a"])
    XCTAssertEqual(saved.first?.limits.first?.used, 0.3)
  }

  func testRateLimitAfterRelaunchKeepsLastKnownValues() async {
    let url = tempURL()
    let resets = Date(timeIntervalSince1970: 1_900_000_000)
    let measured = Date(timeIntervalSince1970: 1_800_000_000)
    UsageCache(url: url).save([
      ProviderUsage(id: "a", name: "A", plan: "Max", limits: [UsageLimit(title: "w", used: 0.8, resetsAt: resets)], fetchedAt: measured),
    ])

    let store = UsageStore(providers: [RateLimitedProvider(id: "a", name: "A")], defaults: .init(suiteName: "aw.test.cache2")!, cacheURL: url)
    XCTAssertEqual(store.usages.first?.limits.first?.used, 0.8, "cached values show before the first refresh")

    store.refresh()
    await waitForRefresh(store)
    let usage = try? XCTUnwrap(store.usages.first)
    XCTAssertEqual(usage?.limits, [UsageLimit(title: "w", used: 0.8, resetsAt: resets)])
    XCTAssertEqual(usage?.fetchedAt, measured)
    XCTAssertEqual(usage?.plan, "Max")
    XCTAssertEqual(usage?.message, "rate limited")
    XCTAssertEqual(UsageCache(url: url).load().first?.limits.first?.used, 0.8, "still on disk after the failed check")
  }

  func testCacheIgnoresHiddenAndUnknownHarnesses() {
    let url = tempURL()
    UsageCache(url: url).save([ProviderUsage(id: "gone", name: "Gone"), ProviderUsage(id: "a", name: "A")])
    let defaults = UserDefaults(suiteName: "aw.test.cache3")!
    defaults.removePersistentDomain(forName: "aw.test.cache3")
    XCTAssertEqual(UsageStore(providers: [FakeProvider(id: "a", name: "A", used: 0)], defaults: defaults, cacheURL: url).usages.map(\.id), ["a"])
    defaults.set(["a"], forKey: UsageStore.Keys.hiddenProviders)
    XCTAssertEqual(UsageStore(providers: [FakeProvider(id: "a", name: "A", used: 0)], defaults: defaults, cacheURL: url).usages.map(\.id), [])
  }
}

struct LoggedOutProvider: UsageProvider {
  let id: String
  let name: String
  func isInstalled() -> Bool { true }
  func fetch() async -> ProviderUsage { ProviderUsage(id: id, name: name, message: "Not logged in", needsLogin: true) }
}

@MainActor
final class LoggedOutTests: XCTestCase {
  func testLostLoginReplacesCachedValuesOnScreenAndOnDisk() async {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aw-\(UUID().uuidString)/usage.json")
    UsageCache(url: url).save([ProviderUsage(id: "a", name: "A", limits: [UsageLimit(title: "w", used: 0.9, resetsAt: nil)], fetchedAt: Date())])
    let store = UsageStore(providers: [LoggedOutProvider(id: "a", name: "A")], defaults: .init(suiteName: "aw.test.logout")!, cacheURL: url)
    store.refresh()
    while store.isRefreshing || store.lastRefresh == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(store.usages.first?.limits, [])
    XCTAssertEqual(store.usages.first?.needsLogin, true)
    XCTAssertNil(store.severity, "a logged-out harness does not color the icon")
    XCTAssertEqual(UsageCache(url: url).load().first?.limits, [])
  }

  func testOldCacheWithoutNeedsLoginStillLoads() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aw-\(UUID().uuidString).json")
    try Data(#"{"savedAt":"2026-10-31T16:11:12Z","usages":[{"id":"a","name":"A","limits":[{"title":"w","used":0.5}]}]}"#.utf8).write(to: url)
    XCTAssertEqual(UsageCache(url: url).load().first?.limits.first?.used, 0.5)
  }
}
