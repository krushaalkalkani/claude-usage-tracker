import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite("Usage payload parsing")
struct ParsingTests {

    // MARK: The shape the API returns today

    @Test("limits[] is used in preference to the legacy top-level keys")
    func currentShape() throws {
        let snapshot = try Fixture.snapshot("usage-current")

        #expect(snapshot.limits.count == 3)
        #expect(snapshot.sessionLimit?.percent == 18)
        #expect(snapshot.weeklyLimit?.percent == 32)
        // The legacy `five_hour` / `seven_day` keys describe the same windows and must not
        // produce duplicate entries.
        #expect(snapshot.limits.filter { $0.group == .session }.count == 1)
    }

    @Test("model-scoped limits come from limits[].scope, not seven_day_<model>")
    func modelScoped() throws {
        let snapshot = try Fixture.snapshot("usage-current")
        // seven_day_opus / seven_day_sonnet are null in this payload — the only model limit
        // is the scoped entry, which v1 never rendered.
        let models = snapshot.modelLimits
        #expect(models.count == 1)
        #expect(models.first?.modelName == "Fable")
        #expect(models.first?.percent == 45)
        #expect(models.first?.isActive == true)
        #expect(models.first?.shortTitle == "Fable")
    }

    @Test("internal codename keys never become labelled limits")
    func codenameKeysIgnored() throws {
        let snapshot = try Fixture.snapshot("usage-current")
        // `nimbus_quill` has a limit-shaped body but no documented meaning.
        let titles = snapshot.limits.map(\.title).joined(separator: " ")
        #expect(!titles.lowercased().contains("nimbus"))
        #expect(!titles.lowercased().contains("tangelo"))
    }

    @Test("bottleneck is the most-consumed limit, not the first one")
    func bottleneck() throws {
        let snapshot = try Fixture.snapshot("usage-current")
        #expect(snapshot.bottleneck?.modelName == "Fable")
        #expect(snapshot.bottleneck?.percent == 45)
    }

    @Test("display order puts session first, then weekly, then scoped")
    func ordering() throws {
        let snapshot = try Fixture.snapshot("usage-current")
        #expect(snapshot.limits[0].group == .session)
        #expect(snapshot.limits[1].kind == "weekly_all")
        #expect(snapshot.limits[2].kind == "weekly_scoped")
    }

    // MARK: Money

    @Test("extra usage credits are minor units — $33.03, not $3303")
    func moneyExponent() throws {
        let snapshot = try Fixture.snapshot("usage-current")
        let spend = try #require(snapshot.spend)
        #expect(spend.used?.amountMinor == 3303)
        #expect(spend.used?.amount == 33.03)
        #expect(spend.limit?.amount == 30.00)
        #expect(spend.percent == 100)
        #expect(spend.enabled == false)
    }

    @Test("overage is computed from minor units")
    func overage() throws {
        let snapshot = try Fixture.snapshot("usage-current")
        let over = try #require(snapshot.spend?.overage)
        #expect(over.amountMinor == 303)
        #expect(abs(over.amount - 3.03) < 0.0001)
    }

    @Test("a non-2 exponent is respected rather than assumed")
    func exponentThree() throws {
        let snapshot = try Fixture.snapshot("usage-unknown-shape")
        let spend = try #require(snapshot.spend)
        // 12345 minor units with exponent 3 = 12.345
        #expect(abs((spend.used?.amount ?? 0) - 12.345) < 0.0001)
        #expect(spend.used?.currency == "EUR")
    }

    @Test("server severity wins over local thresholds")
    func serverSeverity() throws {
        let snapshot = try Fixture.snapshot("usage-current")
        // spend is at 100% and the server calls it critical.
        #expect(snapshot.spend?.severity == .critical)
        // The Fable limit is at 45% and the server calls it normal — a local rule would too,
        // but the point is we take the server's word.
        #expect(snapshot.modelLimits.first?.severity == .normal)
    }

    // MARK: Legacy accounts

    @Test("accounts with no limits[] still parse from the legacy keys")
    func legacyShape() throws {
        let snapshot = try Fixture.snapshot("usage-legacy")
        #expect(snapshot.limits.count == 5)
        #expect(snapshot.sessionLimit?.percent == 62.5)
        #expect(snapshot.weeklyLimit?.percent == 88)

        let models = snapshot.modelLimits
        #expect(models.map(\.modelName) == ["Sonnet", "Opus", "Haiku"])
        #expect(models.first?.percent == 41)
        #expect(snapshot.schemaWarnings.contains { $0.contains("limits[] missing") })
    }

    @Test("legacy extra_usage honours decimal_places")
    func legacyMoney() throws {
        let snapshot = try Fixture.snapshot("usage-legacy")
        #expect(snapshot.spend?.used?.amount == 12.50)
        #expect(snapshot.spend?.limit?.amount == 50.00)
        #expect(snapshot.spend?.enabled == true)
    }

    // MARK: Forward compatibility

    @Test("an unknown limit kind renders instead of disappearing")
    func unknownKind() throws {
        let snapshot = try Fixture.snapshot("usage-unknown-shape")
        let experimental = try #require(snapshot.limits.first { $0.kind == "monthly_experimental" })
        #expect(experimental.percent == 7)
        #expect(experimental.modelName == "Nebula")
        #expect(experimental.modelID == "mdl_abc")
        #expect(experimental.surface == "cowork")
        #expect(experimental.severity == .warning)
        // An unrecognized group falls back to `.other` rather than being dropped.
        #expect(experimental.group == .other)
    }

    @Test("a percent that arrives as a string still parses")
    func stringPercent() throws {
        let snapshot = try Fixture.snapshot("usage-unknown-shape")
        #expect(snapshot.sessionLimit?.percent == 55)
    }

    @Test("unknown top-level keys are preserved and harmless")
    func unknownTopLevel() throws {
        let json = try Fixture.json("usage-unknown-shape")
        let snapshot = UsageParser.parse(json, now: .fixedNow)
        #expect(snapshot.raw?["totally_new_top_level_key"] != nil)
        #expect(snapshot.hasAnyData)
    }

    @Test("garbage entries are skipped without failing the whole parse")
    func malformed() throws {
        let snapshot = try Fixture.snapshot("usage-malformed")
        // Nothing usable, but no crash and an explicit warning.
        #expect(snapshot.limits.isEmpty)
        #expect(!snapshot.hasAnyData)
        #expect(!snapshot.schemaWarnings.isEmpty)
    }

    @Test("an empty payload yields no data rather than 0%")
    func emptyPayload() throws {
        let snapshot = try Fixture.snapshot("usage-empty")
        #expect(snapshot.limits.isEmpty)
        #expect(snapshot.spend == nil)
        #expect(!snapshot.hasAnyData)
    }

    @Test("removing every field the app reads never throws")
    func fieldRemovalFuzz() throws {
        let root = try Fixture.json("usage-current")
        guard case .object(let top) = root else { Issue.record("not an object"); return }
        for key in top.keys {
            var reduced = top
            reduced.removeValue(forKey: key)
            // The contract is simply: this must not crash and must not throw.
            let snapshot = UsageParser.parse(.object(reduced), now: .fixedNow)
            #expect(snapshot.fetchedAt == .fixedNow, "removing \(key) broke parsing")
        }
    }

    @Test("JSON scalars of the wrong type do not throw")
    func wrongTypes() throws {
        let weird: JSONValue = .object([
            "limits": .string("not an array"),
            "five_hour": .number(5),
            "spend": .array([.bool(true)]),
        ])
        let snapshot = UsageParser.parse(weird, now: .fixedNow)
        #expect(snapshot.limits.isEmpty)
    }

    // MARK: Timestamps

    @Test("reset timestamps parse with and without fractional seconds, and are truncated")
    func timestamps() throws {
        let withFraction = try #require(Fixture.snapshot("usage-current").sessionLimit?.resetsAt)
        let withoutFraction = try Fixture.snapshot("usage-legacy").sessionLimit?.resetsAt
        #expect(withoutFraction != nil)

        // The fixture carries `…T20:00:00.196578+00:00`. The parser deliberately drops the
        // fractional part: the API varies it on every response for the same window, and
        // anything that compares or keys on the raw value then sees a new window each poll.
        #expect(withFraction == ISO8601.parse("2026-08-08T20:00:00+00:00"))
        #expect(withFraction.timeIntervalSince1970 == withFraction.timeIntervalSince1970.rounded(.down))
    }

    @Test("time until reset is clamped at zero for a past reset")
    func pastReset() {
        let limit = makeLimit(percent: 10, resetsAt: Date.fixedNow.plus(hours: -3))
        #expect(limit.timeUntilReset(now: .fixedNow) == 0)
    }

    // MARK: Profile

    @Test("profile parsing keeps plan metadata and drops everything identifying")
    func profile() throws {
        let json = try Fixture.json("profile")
        let profile = ProfileParser.parse(json)
        #expect(profile.planLabel == "Max")
        #expect(profile.rateLimitTier == "default_claude_max_5x")
        #expect(profile.subscriptionStatus == "active")
        #expect(profile.extraUsageAvailable == true)

        // AccountProfile has no field that could hold an email, name, or uuid.
        let encoded = try JSONEncoder().encode(profile)
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!text.contains("example.com"))
        #expect(!text.contains("Example User"))
        #expect(!text.lowercased().contains("uuid"))
    }

    // MARK: Persistence

    @Test("a persisted snapshot never carries the raw payload to disk")
    func snapshotEncodingExcludesRaw() throws {
        let snapshot = try Fixture.snapshot("usage-current")
        #expect(snapshot.raw != nil)
        let data = try JSONEncoder.store.encode(snapshot)
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(!text.contains("member_dashboard_available"))
        #expect(!text.contains("nimbus_quill"))

        let round = try JSONDecoder.store.decode(UsageSnapshot.self, from: data)
        #expect(round.limits.count == snapshot.limits.count)
        #expect(round.raw == nil)
    }
}
