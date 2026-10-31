@testable import AgentWatcherCore
import XCTest

final class AlertTests: XCTestCase {
  func testNoAlertAboveWarning() {
    XCTAssertNil(Alert.level(remaining: 0.21, warning: 0.2, critical: 0.1))
    XCTAssertNil(Alert.level(remaining: 1, warning: 0.2, critical: 0.1))
  }

  func testOrangeThenRed() {
    XCTAssertEqual(Alert.level(remaining: 0.2, warning: 0.2, critical: 0.1), .warning)
    XCTAssertEqual(Alert.level(remaining: 0.11, warning: 0.2, critical: 0.1), .warning)
    XCTAssertEqual(Alert.level(remaining: 0.1, warning: 0.2, critical: 0.1), .critical)
    XCTAssertEqual(Alert.level(remaining: 0, warning: 0.2, critical: 0.1), .critical)
    XCTAssertEqual(Alert.color(.warning), Alert.orange)
    XCTAssertEqual(Alert.color(.critical), Alert.red)
  }

  func testColorReddensTowardCritical() {
    XCTAssertNil(Alert.color(remaining: 0.21, warning: 0.2, critical: 0.1))
    XCTAssertEqual(Alert.color(remaining: 0.2, warning: 0.2, critical: 0.1), Alert.orange)
    let near = Alert.color(remaining: 0.11, warning: 0.2, critical: 0.1)!
    XCTAssertEqual(near.g, Alert.orange.g + (Alert.red.g - Alert.orange.g) * 0.9, accuracy: 1e-9)
    XCTAssertEqual(Alert.color(remaining: 0.1, warning: 0.2, critical: 0.1), Alert.red)
    XCTAssertEqual(Alert.color(remaining: 0, warning: 0.2, critical: 0.1), Alert.red)
  }

  func testPercentLeftIsTruncated() {
    XCTAssertEqual(Alert.percentLeft(0.109), 10)
    XCTAssertEqual(Alert.percentLeft(0.29), 29)
    XCTAssertEqual(Alert.percentLeft(1 - 0.71), 29)
    XCTAssertEqual(Alert.percentLeft(0.999), 99)
    XCTAssertEqual(Alert.percentLeft(1), 100)
    XCTAssertEqual(Alert.percentLeft(-0.1), 0)
  }

  func testThresholdsMatchTheTruncatedPercentShown() {
    XCTAssertEqual(Alert.level(remaining: 0.109, warning: 0.2, critical: 0.1), .critical, "shown as 10% left")
    XCTAssertEqual(Alert.level(remaining: 0.11, warning: 0.2, critical: 0.1), .warning, "shown as 11% left")
    XCTAssertEqual(Alert.level(remaining: 0.209, warning: 0.2, critical: 0.1), .warning, "shown as 20% left")
    XCTAssertNil(Alert.level(remaining: 0.21, warning: 0.2, critical: 0.1), "shown as 21% left")
    XCTAssertEqual(Alert.color(remaining: 0.109, warning: 0.2, critical: 0.1), Alert.red)
  }

  func testRedOnlyWhenExhaustedWithZeroCritical() {
    XCTAssertEqual(Alert.level(remaining: 0.01, warning: 0.2, critical: 0), .warning)
    XCTAssertEqual(Alert.level(remaining: 0, warning: 0.2, critical: 0), .critical)
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

  func testModelScopedLimitDoesNotColorTheIcon() {
    let future = Date().addingTimeInterval(3600)
    let claude = ProviderUsage(id: "claude", name: "Claude Code", limits: [
      UsageLimit(title: "Weekly", used: 0.4, resetsAt: future),
      UsageLimit(title: "Fable · Weekly", used: 1, resetsAt: future, countsTowardAlert: false),
    ])
    XCTAssertEqual(claude.tightest()?.title, "Weekly")
    XCTAssertEqual(Alert.worstRemaining([claude])!, 0.6, accuracy: 1e-9)
    XCTAssertNil(Alert.level(remaining: Alert.worstRemaining([claude])!, warning: 0.2, critical: 0.1))
  }

  func testCursorOverallDecidesTheIconNotCursorModels() {
    let future = Date().addingTimeInterval(3600)
    let cursor = ProviderUsage(id: "cursor", name: "Cursor", limits: [
      UsageLimit(title: "Overall", used: 0.8784, resetsAt: future, shownInPanel: false),
      UsageLimit(title: "Cursor Models", used: 0.9174, resetsAt: future, countsTowardAlert: false),
      UsageLimit(title: "Other Models", used: 0.4529, resetsAt: future, countsTowardAlert: false),
    ])
    XCTAssertEqual(cursor.tightest()?.title, "Overall")
    XCTAssertEqual(Alert.worstRemaining([cursor])!, 1 - 0.8784, accuracy: 1e-9)
    XCTAssertEqual(cursor.tooltipLine(), "Cursor: 12% left")
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
    XCTAssertTrue(limits[0].countsTowardAlert)
    XCTAssertEqual(limits[1].used, 0.05, accuracy: 1e-9)
    XCTAssertFalse(limits[1].countsTowardAlert)
    XCTAssertEqual(ProviderUsage(id: "claude", name: "Claude Code", limits: limits).tooltipLine(), "Claude Code: 7% left (Weekly)")
  }

  func testFillsWeeklyFromUnscopedLimitsWhenTopLevelBucketIsMissing() {
    let payload: [String: Any] = [
      "five_hour": NSNull(),
      "seven_day": NSNull(),
      "limits": [
        ["kind": "weekly_all", "percent": 40, "resets_at": "2026-11-02T07:00:00Z", "scope": NSNull()],
        ["kind": "weekly_scoped", "percent": 100, "resets_at": "2026-11-02T07:00:00Z",
         "scope": ["model": ["display_name": "Fable"]]],
      ],
    ]
    let limits = ClaudeProvider.parseLimits(payload)
    XCTAssertEqual(limits.map(\.title), ["Weekly", "Fable · Weekly"])
    XCTAssertTrue(limits[0].countsTowardAlert)
    XCTAssertFalse(limits[1].countsTowardAlert)
    XCTAssertEqual(limits[0].used, 0.4, accuracy: 1e-9)
    XCTAssertEqual(limits[1].used, 1, accuracy: 1e-9)
  }

  func testUsageRequestLooksLikeClaudeCode() {
    let request = ClaudeProvider.usageRequest(token: "tok")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), ClaudeProvider.userAgent)
    XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("claude-code/") == true)
    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    XCTAssertEqual(request.timeoutInterval, ClaudeProvider.requestTimeout)
  }

  func testUserAgentFromClaudeVersionOutput() {
    XCTAssertEqual(ClaudeProvider.userAgent(fromVersionOutput: "2.1.69 (Claude Code)\n"), "claude-code/2.1.69")
    XCTAssertEqual(ClaudeProvider.userAgent(fromVersionOutput: "not a version"), ClaudeProvider.fallbackUserAgent)
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

  func testIgnoresModelBucketsAndKeepsTheMainCodexAllowance() {
    let spark: [String: Any] = [
      "limitId": "codex_bengalfox",
      "primary": ["usedPercent": 0, "windowDurationMins": 300],
      "secondary": ["usedPercent": 90, "windowDurationMins": 10080],
    ]
    let parsed = CodexProvider.parse([
      "rateLimits": spark,
      "rateLimitsByLimitId": [
        "codex_bengalfox": spark,
        "codex": ["secondary": ["usedPercent": 42, "windowDurationMins": 10080]] as JSON,
        "gpt5pro": ["limitName": "GPT-5 Pro", "secondary": ["usedPercent": 50, "windowDurationMins": 10080]] as JSON,
      ] as JSON,
    ])
    XCTAssertEqual(parsed.limits.map(\.title), ["Weekly"])
    XCTAssertEqual(parsed.limits[0].used, 0.42, accuracy: 1e-9)
  }

  func testSparkOnlySnapshotIsIgnored() {
    let spark: [String: Any] = [
      "limitId": "codex_bengalfox",
      "planType": "plus",
      "primary": ["usedPercent": 0, "windowDurationMins": 300],
      "secondary": ["usedPercent": 90, "windowDurationMins": 10080],
    ]
    let parsed = CodexProvider.parse(["rateLimits": spark, "rateLimitsByLimitId": ["codex_bengalfox": spark] as JSON])
    XCTAssertEqual(parsed.plan, "Plus")
    XCTAssertEqual(parsed.limits, [])
  }

  func testFreePlanWithoutDurationIsMonthly() {
    let parsed = CodexProvider.parse(["rateLimits": ["planType": "free", "primary": ["usedPercent": 80] as JSON] as JSON])
    XCTAssertEqual(parsed.plan, "Free")
    XCTAssertEqual(parsed.limits.map(\.title), ["Monthly"])
    XCTAssertEqual(parsed.limits[0].used, 0.8, accuracy: 1e-9)
  }

  func testEnterpriseMonthlyCreditLimit() {
    let parsed = CodexProvider.parse(["rateLimitsByLimitId": ["codex": [
      "planType": "enterprise_cbp_usage_based",
      "individualLimit": ["remainingPercent": 99, "resetsAt": 1_784_500_000],
    ] as JSON]])
    XCTAssertEqual(parsed.plan, "Enterprise")
    XCTAssertEqual(parsed.limits.map(\.title), ["Monthly credit"])
    XCTAssertEqual(parsed.limits[0].used, 0.01, accuracy: 1e-9)
    XCTAssertEqual(parsed.limits[0].resetsAt, Date(timeIntervalSince1970: 1_784_500_000))
  }
}

final class CursorParsingTests: XCTestCase {
  func testParsesPoolsFromRealJSON() throws {
    let raw = #"{"billingCycleStart":"1791982045000","billingCycleEnd":"1794660445000","planUsage":{"totalSpend":115072,"includedSpend":7000,"limit":7000,"autoPercentUsed":91.74,"apiPercentUsed":45.29,"totalPercentUsed":87.84},"enabled":true}"#
    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? JSON)
    let limits = CursorProvider.parseLimits(payload)
    XCTAssertEqual(limits.map(\.title), ["Overall", "Cursor Models", "Other Models"])
    XCTAssertEqual(limits[0].used, 0.8784, accuracy: 1e-6)
    XCTAssertTrue(limits[0].countsTowardAlert)
    XCTAssertFalse(limits[0].shownInPanel)
    XCTAssertEqual(limits[1].used, 0.9174, accuracy: 1e-6)
    XCTAssertFalse(limits[1].countsTowardAlert)
    XCTAssertTrue(limits[1].shownInPanel)
    XCTAssertFalse(limits[2].countsTowardAlert)
    XCTAssertTrue(limits[2].shownInPanel)
    XCTAssertEqual(limits[0].resetsAt, Date(timeIntervalSince1970: 1794660445))
    let usage = ProviderUsage(id: "cursor", name: "Cursor", limits: limits)
    XCTAssertEqual(usage.visibleLimits.map(\.title), ["Cursor Models", "Other Models"])
    XCTAssertEqual(usage.tightest()?.title, "Overall")
    XCTAssertEqual(usage.tooltipLine(), "Cursor: 12% left")
  }

  func testPoolsCountTowardAlertWhenOverallIsMissing() {
    let limits = CursorProvider.parseLimits(["planUsage": ["autoPercentUsed": 91.74, "apiPercentUsed": 45.29] as JSON])
    XCTAssertEqual(limits.map(\.title), ["Cursor Models", "Other Models"])
    XCTAssertTrue(limits.allSatisfy(\.countsTowardAlert))
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
    XCTAssertNil(store.alertLevel)
    XCTAssertEqual(defaults.stringArray(forKey: UsageStore.Keys.hiddenProviders), ["b"])

    store.setHidden("b", false)
    await waitForRefresh(store)
    XCTAssertEqual(store.usages.map(\.id), ["a", "b"])
    XCTAssertEqual(store.alertLevel, .critical)
  }

  func testSettingsPersist() {
    let (store, defaults) = makeStore("aw.test.persist")
    store.refreshInterval = 600
    store.warningThreshold = 0.3
    store.criticalThreshold = 0.15
    let reloaded = UsageStore(providers: [], defaults: defaults, cacheURL: nil)
    XCTAssertEqual(reloaded.refreshInterval, 600)
    XCTAssertEqual(reloaded.warningThreshold, 0.3)
    XCTAssertEqual(reloaded.criticalThreshold, 0.15)
  }

  func testRedStaysBelowOrange() {
    let (store, _) = makeStore("aw.test.order")
    store.warningThreshold = 0.3
    store.criticalThreshold = 0.15
    store.warningThreshold = 0.1
    XCTAssertEqual(store.criticalThreshold, 0.09, accuracy: 1e-9)
    store.criticalThreshold = 0.25
    XCTAssertEqual(store.warningThreshold, 0.26, accuracy: 1e-9)
  }

  func testOldSingleThresholdBecomesOrange() {
    let defaults = UserDefaults(suiteName: "aw.test.migrate")!
    defaults.removePersistentDomain(forName: "aw.test.migrate")
    defaults.set(0.15, forKey: "alertThreshold")
    let store = UsageStore(providers: [], defaults: defaults, cacheURL: nil)
    XCTAssertEqual(store.warningThreshold, 0.15)
    XCTAssertEqual(store.criticalThreshold, 0.1)
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
    XCTAssertNil(store.alertLevel, "a logged-out harness does not color the icon")
    XCTAssertEqual(UsageCache(url: url).load().first?.limits, [])
  }

  func testOldCacheWithoutNeedsLoginStillLoads() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aw-\(UUID().uuidString).json")
    try Data(#"{"savedAt":"2026-10-31T16:11:12Z","usages":[{"id":"a","name":"A","limits":[{"title":"w","used":0.5}]}]}"#.utf8).write(to: url)
    XCTAssertEqual(UsageCache(url: url).load().first?.limits.first?.used, 0.5)
    XCTAssertEqual(UsageCache(url: url).load().first?.limits.first?.countsTowardAlert, true)
    XCTAssertEqual(UsageCache(url: url).load().first?.limits.first?.shownInPanel, true)
  }

  func testCachedOverallWithoutShownFlagStaysOffThePanel() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aw-\(UUID().uuidString).json")
    try Data(#"{"savedAt":"2026-10-31T16:11:12Z","usages":[{"id":"cursor","name":"Cursor","limits":[{"title":"Overall","used":0.8},{"title":"Cursor Models","used":0.9}]}]}"#.utf8).write(to: url)
    let limits = UsageCache(url: url).load().first?.limits ?? []
    XCTAssertEqual(limits.map(\.shownInPanel), [false, true])
  }
}

final class ReviewFixTests: XCTestCase {
  func testOnlyExplicitAuthErrorsMeanLoggedOut() {
    XCTAssertTrue(CodexProvider.isLoginError("codex account authentication required to read rate limits"))
    XCTAssertTrue(CodexProvider.isLoginError("401 Unauthorized"))
    XCTAssertFalse(CodexProvider.isLoginError("request to https://chatgpt.com/backend-api/wham/usage failed: 503"))
    XCTAssertFalse(CodexProvider.isLoginError("too many tokens; rate limited"))
    XCTAssertFalse(CodexProvider.isLoginError("authorization server unavailable"))
  }

  func testCodexWindowsWithoutDurationUsePaidFallbacks() {
    let parsed = CodexProvider.parse(["rateLimits": [
      "primary": ["usedPercent": 10] as JSON,
      "secondary": ["usedPercent": 20] as JSON,
    ] as JSON])
    XCTAssertEqual(parsed.limits.map(\.title), ["Session (5h)", "Weekly"])
  }

  func testCursorTriesUnexpiredLoginsFirst() {
    func jwt(_ exp: Int) -> String {
      "h." + Data(#"{"exp":\#(exp)}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".s"
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let stale = jwt(1_700_000_000), fresh = jwt(1_900_000_000)
    XCTAssertEqual(CursorProvider.ordered([stale, fresh, fresh, ""], now: now), [fresh, stale])
    XCTAssertEqual(CursorProvider.ordered(["opaque", stale], now: now), ["opaque", stale])
  }
}

final class RateLimitTests: XCTestCase {
  func testRateLimitedRefreshKeepsNumbersAndFlag() {
    let old = ProviderUsage(id: "c", name: "C", limits: [UsageLimit(title: "w", used: 0.4, resetsAt: nil)], fetchedAt: Date())
    let limited = ProviderUsage(id: "c", name: "C", message: "slow down", rateLimited: true)
    let merged = limited.merged(withPrevious: old)
    XCTAssertEqual(merged.limits, old.limits)
    XCTAssertTrue(merged.rateLimited)
  }
}

final class UpdaterTests: XCTestCase {
  func testVersionOrdering() {
    XCTAssertLessThan(AppVersion("0.9.9")!, AppVersion("v0.10.0")!)
    XCTAssertLessThan(AppVersion("1.2")!, AppVersion("1.2.1")!)
    XCTAssertEqual(AppVersion("1.2.0")!, AppVersion("v1.2")!)
    XCTAssertFalse(AppVersion("1.3.0")! < AppVersion("1.2.9")!)
    XCTAssertNil(AppVersion("1.2.0-beta"))
    XCTAssertNil(AppVersion(""))
  }

  private func release(tag: String = "v1.4.0", prerelease: Bool = false, assets: [String]) -> Data {
    let list = assets.map { "{\"name\":\"\($0)\",\"browser_download_url\":\"https://github.com/o/r/releases/download/\(tag)/\($0)\"}" }
    return Data("""
      {"tag_name":"\(tag)","html_url":"https://github.com/o/r/releases/tag/\(tag)","draft":false,
       "prerelease":\(prerelease),"assets":[\(list.joined(separator: ","))]}
      """.utf8)
  }

  func testParsesLatestRelease() {
    let info = ReleaseInfo.parse(release(assets: ["SHA256SUMS.txt", "AgentWatcher-1.4.0.dmg"]))!
    XCTAssertEqual(info.version, AppVersion("1.4.0"))
    XCTAssertEqual(info.dmgName, "AgentWatcher-1.4.0.dmg")
    XCTAssertEqual(info.dmgURL.lastPathComponent, "AgentWatcher-1.4.0.dmg")
    XCTAssertEqual(info.checksumsURL?.lastPathComponent, "SHA256SUMS.txt")
  }

  func testRejectsUnusableReleases() {
    XCTAssertNil(ReleaseInfo.parse(release(assets: ["SHA256SUMS.txt"])))
    XCTAssertNil(ReleaseInfo.parse(release(prerelease: true, assets: ["AgentWatcher-1.4.0.dmg"])))
    XCTAssertNil(ReleaseInfo.parse(release(tag: "nightly", assets: ["AgentWatcher-1.4.0.dmg"])))
    XCTAssertNil(ReleaseInfo.parse(Data("not json".utf8)))
  }

  func testChecksumLookup() {
    let hash = String(repeating: "ab", count: 32)
    let listing = "\(String(repeating: "0", count: 64))  Other.dmg\n\(hash.uppercased())  AgentWatcher-1.4.0.dmg\n"
    XCTAssertEqual(ReleaseInfo.checksum(for: "AgentWatcher-1.4.0.dmg", in: listing), hash)
    XCTAssertNil(ReleaseInfo.checksum(for: "Missing.dmg", in: listing))
    XCTAssertNil(ReleaseInfo.checksum(for: "Bad.dmg", in: "xyz  Bad.dmg"))
  }
}
