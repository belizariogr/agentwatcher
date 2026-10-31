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
    XCTAssertEqual(limits.map(\.title), ["Semanal", "Fable · Semanal"])
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
    XCTAssertEqual(parsed.limits.map(\.title), ["Sessão (5h)", "Semanal"])
    XCTAssertEqual(parsed.limits[1].used, 0.35, accuracy: 1e-9)
  }

  func testZeroPercentFromRealJSONIsKept() throws {
    let json = #"{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1793479334},"secondary":{"usedPercent":35,"windowDurationMins":10080,"resetsAt":1793799273},"planType":"plus","individualLimit":null}}"#
    let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let parsed = CodexProvider.parse(result)
    XCTAssertEqual(parsed.limits.map(\.title), ["Sessão (5h)", "Semanal"])
    XCTAssertEqual(parsed.limits[0].used, 0)
    XCTAssertNotNil(parsed.limits[0].resetsAt)
  }

  func testModelBucketIsTitledByName() {
    let general: [String: Any] = ["primary": ["usedPercent": 10, "windowDurationMins": 300]]
    let model: [String: Any] = ["limitName": "GPT-5 Pro", "secondary": ["usedPercent": 50, "windowDurationMins": 10080]]
    let parsed = CodexProvider.parse(["rateLimitsByLimitId": ["codex": general, "gpt5pro": model]])
    XCTAssertEqual(parsed.limits.map(\.title), ["Sessão (5h)", "GPT-5 Pro · Semanal"])
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
    XCTAssertEqual(limits.map(\.title), ["Mensal"])
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
    ], defaults: defaults)
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
    let reloaded = UsageStore(providers: [], defaults: defaults)
    XCTAssertEqual(reloaded.refreshInterval, 600)
    XCTAssertEqual(reloaded.alertThreshold, 0.25)
  }
}
