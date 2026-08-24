import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite("History store")
struct HistoryStoreTests {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cut-history-\(UUID().uuidString).json")
    }

    @Test("samples round-trip through disk")
    func roundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = HistoryStore(url: url, minimumWriteInterval: 0)
        for i in 0..<5 {
            _ = store.append(
                UsageSample(t: Date.fixedNow.plus(minutes: Double(i)), limits: ["session": Double(i * 10)]),
                retention: 86_400, now: Date.fixedNow.plus(minutes: Double(i))
            )
        }
        store.flush()

        let reloaded = HistoryStore(url: url).load()
        #expect(reloaded.count == 5)
        #expect(reloaded.last?.limits["session"] == 40)
    }

    @Test("retention drops samples older than the window")
    func retention() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url, minimumWriteInterval: 0)

        let old = Date.fixedNow.plus(days: -10)
        _ = store.append(UsageSample(t: old, limits: ["session": 5]), retention: 7 * 86_400, now: .fixedNow)
        let kept = store.append(
            UsageSample(t: .fixedNow, limits: ["session": 50]), retention: 7 * 86_400, now: .fixedNow
        )
        #expect(kept.count == 1)
        #expect(kept.first?.limits["session"] == 50)
    }

    @Test("retention never leaves the panel with nothing to show")
    func retentionKeepsNewest() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url, minimumWriteInterval: 0)
        // Every sample is older than the cutoff.
        _ = store.append(
            UsageSample(t: Date.fixedNow.plus(days: -30), limits: ["session": 5]),
            retention: 86_400, now: .fixedNow
        )
        let result = store.load()
        #expect(result.count == 1)
    }

    @Test("a duplicate timestamp replaces rather than accumulates")
    func duplicateTimestamps() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url, minimumWriteInterval: 0)
        _ = store.append(UsageSample(t: .fixedNow, limits: ["session": 10]), retention: 86_400, now: .fixedNow)
        let after = store.append(
            UsageSample(t: .fixedNow, limits: ["session": 11]), retention: 86_400, now: .fixedNow
        )
        #expect(after.count == 1)
        #expect(after.first?.limits["session"] == 11)
    }

    @Test("a corrupt history file starts fresh instead of crashing")
    func corruptFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "not json at all".write(to: url, atomically: true, encoding: .utf8)
        let store = HistoryStore(url: url, minimumWriteInterval: 0)
        #expect(store.load().isEmpty)
        let after = store.append(
            UsageSample(t: .fixedNow, limits: ["session": 1]), retention: 86_400, now: .fixedNow
        )
        #expect(after.count == 1)
    }

    @Test("clearing removes the file and the in-memory series")
    func clear() throws {
        let url = tempURL()
        let store = HistoryStore(url: url, minimumWriteInterval: 0)
        _ = store.append(UsageSample(t: .fixedNow, limits: ["s": 1]), retention: 86_400, now: .fixedNow)
        store.flush()
        store.clear()
        #expect(store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a sample is built from a snapshot's limit ids")
    func sampleFromSnapshot() throws {
        let snapshot = try Fixture.snapshot("usage-current")
        let sample = UsageSample.from(snapshot)
        #expect(sample.limits["session"] == 18)
        #expect(sample.limits["weekly_all"] == 32)
        #expect(sample.limits["weekly_scoped|m:fable"] == 45)
        #expect(sample.spend == 100)
    }
}

@Suite("Settings")
struct SettingsTests {
    private func tempDefaults() -> UserDefaults {
        UserDefaults(suiteName: "cut-tests-\(UUID().uuidString)")!
    }

    @Test("settings persist and reload")
    func persistence() {
        let defaults = tempDefaults()
        let store = SettingsStore(defaults: defaults)
        _ = store.update {
            $0.refreshInterval = .thirtySeconds
            $0.primaryMetric = .weekly
            $0.usageThresholds = [42]
        }
        let reloaded = SettingsStore(defaults: defaults).current
        #expect(reloaded.refreshInterval == .thirtySeconds)
        #expect(reloaded.primaryMetric == .weekly)
        #expect(reloaded.usageThresholds == [42])
    }

    @Test("a stored blob missing new keys keeps their defaults")
    func forwardCompatibleSettings() throws {
        let defaults = tempDefaults()
        // Simulate settings written by an older build that lacked most fields.
        let partial = #"{"refreshInterval":300}"#.data(using: .utf8)!
        defaults.set(partial, forKey: "settings.v2")
        let loaded = SettingsStore(defaults: defaults).current
        #expect(loaded.refreshInterval == .fiveMinutes)
        #expect(loaded.displayMode == .iconAndPercent)
        #expect(loaded.usageThresholds == [50, 75, 90, 95, 100])
        #expect(loaded.selectedProvider == .claude)
    }

    @Test("reset restores every default")
    func reset() {
        let store = SettingsStore(defaults: tempDefaults())
        _ = store.update { $0.notificationsEnabled = false }
        #expect(store.resetToDefaults().notificationsEnabled)
    }
}

@Suite("API error handling")
struct APIErrorTests {

    @Test("transient errors are the ones worth retrying")
    func transience() {
        #expect(UsageAPIError.rateLimited(retryAfter: 30).isTransient)
        #expect(UsageAPIError.server(status: 503).isTransient)
        #expect(UsageAPIError.offline.isTransient)
        #expect(UsageAPIError.timedOut.isTransient)
        #expect(!UsageAPIError.unauthorized.isTransient)
        #expect(!UsageAPIError.forbidden.isTransient)
        #expect(!UsageAPIError.invalidJSON.isTransient)
    }

    @Test("every error has a title and a usable explanation")
    func messaging() {
        let cases: [UsageAPIError] = [
            .missingToken, .unauthorized, .forbidden, .rateLimited(retryAfter: 12),
            .server(status: 500), .http(status: 418), .offline, .timedOut,
            .network("boom"), .invalidJSON, .unrecognizedSchema("no limits"),
        ]
        for error in cases {
            #expect(!error.title.isEmpty)
            #expect(!error.detail.isEmpty)
        }
        #expect(UsageAPIError.rateLimited(retryAfter: 12).detail.contains("12"))
    }

    @Test("backoff grows, is capped, and honours Retry-After")
    func backoff() {
        let policy = BackoffPolicy(base: 30, maximum: 300, jitterFraction: 0)
        #expect(policy.delay(failureCount: 1, randomUnit: 0.5) == 30)
        #expect(policy.delay(failureCount: 2, randomUnit: 0.5) == 60)
        #expect(policy.delay(failureCount: 3, randomUnit: 0.5) == 120)
        #expect(policy.delay(failureCount: 4, randomUnit: 0.5) == 240)
        #expect(policy.delay(failureCount: 5, randomUnit: 0.5) == 300)
        #expect(policy.delay(failureCount: 99, randomUnit: 0.5) == 300)
        // The server's instruction wins, but is still capped.
        #expect(policy.delay(failureCount: 1, retryAfter: 45, randomUnit: 0.5) == 45)
        #expect(policy.delay(failureCount: 1, retryAfter: 9_999, randomUnit: 0.5) == 300)
    }

    @Test("jitter stays inside its band and never goes below a second")
    func jitterBounds() {
        let policy = BackoffPolicy(base: 30, maximum: 300, jitterFraction: 0.2)
        for unit in stride(from: 0.0, through: 1.0, by: 0.1) {
            let d = policy.delay(failureCount: 1, randomUnit: unit)
            #expect(d >= 24 - 0.001 && d <= 36 + 0.001)
        }
        let tiny = BackoffPolicy(base: 1, maximum: 2, jitterFraction: 1)
        #expect(tiny.delay(failureCount: 1, randomUnit: 0) >= 1)
    }
}

@Suite("Menu bar metric selection")
struct MetricTests {

    @Test("auto picks the most constrained limit, preferring the active one on a tie")
    func autoPicksBottleneck() {
        let snapshot = makeSnapshot(limits: [
            makeLimit(id: "session", percent: 25, resetsAt: nil),
            makeLimit(id: "weekly_all", kind: "weekly_all", group: .weekly, percent: 91, resetsAt: nil),
        ])
        #expect(snapshot.bottleneck?.id == "weekly_all")

        let tied = makeSnapshot(limits: [
            makeLimit(id: "a", percent: 60.4, resetsAt: nil),
            makeLimit(id: "b", kind: "weekly_scoped", group: .weekly, percent: 60.0,
                      resetsAt: nil, isActive: true, model: "Fable"),
        ])
        #expect(tied.bottleneck?.id == "b")
    }

    @Test("worst severity spans limits and spend")
    func worstSeverity() {
        let snapshot = makeSnapshot(
            limits: [makeLimit(percent: 10, resetsAt: nil, severity: .normal)],
            spend: SpendInfo(
                enabled: true, used: nil, limit: nil, percent: 100, severity: .critical,
                disabledReason: nil, userDisabled: nil, limitReached: true,
                everEnabled: true, balance: nil, disclaimer: nil
            )
        )
        #expect(snapshot.worstSeverity == .critical)
    }

    @Test("severity thresholds behave at the boundaries")
    func severityBoundaries() {
        #expect(Severity.from(percent: 74.9) == .normal)
        #expect(Severity.from(percent: 75) == .warning)
        #expect(Severity.from(percent: 89.9) == .warning)
        #expect(Severity.from(percent: 90) == .critical)
        #expect(Severity.critical > Severity.warning)
        #expect(Severity.warning > Severity.normal)
    }

    @Test("spend with no data at all is not presentable")
    func spendPresentability() {
        let empty = SpendInfo(
            enabled: false, used: nil, limit: nil, percent: nil, severity: .normal,
            disabledReason: nil, userDisabled: nil, limitReached: nil,
            everEnabled: false, balance: nil, disclaimer: nil
        )
        #expect(!empty.isPresentable)
    }

    @Test("money formatting respects the exponent")
    func moneyFormatting() {
        #expect(Money(amountMinor: 3303, currency: "USD", exponent: 2).amount == 33.03)
        #expect(Money(amountMinor: 3303, currency: "USD", exponent: 0).amount == 3303)
        // An absurd exponent is clamped rather than producing a denormal.
        #expect(Money(amountMinor: 100, currency: "USD", exponent: 99).exponent == 6)
    }
}
