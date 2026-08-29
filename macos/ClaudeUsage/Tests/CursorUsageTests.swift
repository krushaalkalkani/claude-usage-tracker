import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite("Cursor usage parsing")
struct CursorUsageParserTests {
    @Test("Cursor Models, Other Models, and Grok Bot windows parse with plan label")
    func normalWindows() throws {
        let parsed = CursorUsageParser.parse(
            planInfo: try Fixture.json("cursor-plan-info"),
            currentPeriodUsage: try Fixture.json("cursor-current-period-usage"),
            sandUsageStatus: try Fixture.json("cursor-sand-usage-status"),
            now: .fixedNow
        )
        #expect(parsed.snapshot.provider == .cursor)
        #expect(parsed.planLabel == "Pro+")
        #expect(parsed.snapshot.limits.count == 3)

        let cursorModels = try #require(parsed.snapshot.limits.first { $0.id == "cursor_models" })
        #expect(cursorModels.percent == 30)
        #expect(cursorModels.provider == .cursor)
        #expect(cursorModels.resetsAt == Date(timeIntervalSince1970: 1_790_224_537))

        let otherModels = try #require(parsed.snapshot.limits.first { $0.id == "other_models" })
        #expect(otherModels.percent == 0)
        #expect(otherModels.resetsAt == Date(timeIntervalSince1970: 1_790_224_537))

        let grokBot = try #require(parsed.snapshot.limits.first { $0.id == "grok_bot" })
        #expect(grokBot.shortTitle == "Grok Bot")
        #expect(abs(grokBot.percent - 23.727263) < 0.0001)
        #expect(grokBot.resetsAt == ISO8601.parse("2026-08-31T19:28:09.358Z")?.truncatingSubsecond)
        // Without a surface the hero card labels this generically as "Weekly · 7-day" and the
        // name "Grok Bot" appears nowhere on screen.
        #expect(grokBot.surface == "Grok Bot")

        // Cursor Models (30%) is the tightest of the three, so it is the bottleneck.
        #expect(parsed.snapshot.bottleneck?.id == "cursor_models")

        // Both ends of the billing cycle are in the payload, so the window length is known
        // rather than guessed. Without it these windows fall into the "unknown length" path:
        // no pace bar, no window-start cutoff for the burn rate, and a hero eyebrow that
        // invented a period from the internal `kind` ("Cursor Models · cursor models included").
        let cycle = try #require(cursorModels.windowDuration)
        #expect(abs(cycle - 2_678_400) < 1, "31 days, got \(cycle)")
        #expect(otherModels.windowDuration == cursorModels.windowDuration)
        #expect(UsageAnalytics.windowLength(for: cursorModels) == cycle)
        // …and with a length, pace becomes answerable for a Cursor window.
        #expect(UsageAnalytics.pace(
            for: cursorModels, now: Date(timeIntervalSince1970: 1_789_000_000)
        ) != nil)
    }

    @Test("a nonsensical billing cycle is dropped rather than believed")
    func implausibleBillingCycle() throws {
        // A start after its end, or a span no billing cycle could have, means one of the two
        // timestamps is wrong — and a wrong window length silently corrupts pace, the burn
        // rate's window cutoff, and the go/no-go answer built on top of them.
        func duration(start: String, end: String) throws -> TimeInterval? {
            let json = """
            {"billingCycleStart": "\(start)", "billingCycleEnd": "\(end)",
             "planUsage": {"autoPercentUsed": 30, "apiPercentUsed": 0}}
            """
            let parsed = CursorUsageParser.parse(
                planInfo: nil,
                currentPeriodUsage: try JSONValue.parse(Data(json.utf8)),
                sandUsageStatus: nil,
                now: .fixedNow
            )
            return parsed.snapshot.limits.first { $0.id == "cursor_models" }?.windowDuration
        }

        #expect(try duration(start: "1790224537000", end: "1787546137000") == nil, "start after end")
        #expect(try duration(start: "1787546137000", end: "1787549737000") == nil, "one hour")
        #expect(try duration(start: "1", end: "1790224537000") == nil, "epoch to now")
        #expect(try duration(start: "1787546137000", end: "1790224537000") != nil, "the real one")
    }

    @Test("only the included-usage windows parse when Grok Bot status is unavailable")
    func missingSandStatus() throws {
        let parsed = CursorUsageParser.parse(
            planInfo: nil,
            currentPeriodUsage: try Fixture.json("cursor-current-period-usage"),
            sandUsageStatus: nil,
            now: .fixedNow
        )
        #expect(parsed.snapshot.limits.count == 2)
        #expect(parsed.snapshot.limits.contains { $0.id == "cursor_models" })
        #expect(parsed.snapshot.limits.contains { $0.id == "other_models" })
        #expect(parsed.planLabel == nil)
        #expect(parsed.snapshot.schemaWarnings.contains {
            $0.contains("get-sand-usage-status response missing")
        })
    }

    @Test("malformed fields clamp or are dropped instead of throwing")
    func malformedFields() throws {
        let parsed = CursorUsageParser.parse(
            planInfo: nil,
            currentPeriodUsage: try Fixture.json("cursor-current-period-usage-malformed"),
            sandUsageStatus: try Fixture.json("cursor-sand-usage-status-malformed"),
            now: .fixedNow
        )
        // autoPercentUsed arrived as the string "-15": still readable, then clamped to 0.
        let cursorModels = try #require(parsed.snapshot.limits.first { $0.id == "cursor_models" })
        #expect(cursorModels.percent == 0)
        #expect(cursorModels.rawPercent == -15)
        #expect(cursorModels.resetsAt == nil)  // billingCycleEnd was not a number.

        // apiPercentUsed was not a number at all, so no Other Models window is produced.
        #expect(!parsed.snapshot.limits.contains { $0.id == "other_models" })
        #expect(parsed.snapshot.schemaWarnings.contains { $0.contains("missing apiPercentUsed") })

        // usagePercent was not a number at all, so no Grok Bot window is produced.
        #expect(!parsed.snapshot.limits.contains { $0.id == "grok_bot" })
        #expect(parsed.snapshot.schemaWarnings.contains { $0.contains("missing usagePercent") })
    }

    @Test("an empty payload has no synthetic usage")
    func emptyPayload() throws {
        let empty = try Fixture.json("cursor-empty")
        let parsed = CursorUsageParser.parse(
            planInfo: empty, currentPeriodUsage: empty, sandUsageStatus: empty, now: .fixedNow
        )
        #expect(parsed.snapshot.limits.isEmpty)
        #expect(parsed.snapshot.bottleneck == nil)
        #expect(parsed.snapshot.schemaWarnings.contains { $0.contains("no Cursor usage windows") })
    }

    @Test("entirely missing responses are reported, not silently blank")
    func allMissing() {
        let parsed = CursorUsageParser.parse(
            planInfo: nil, currentPeriodUsage: nil, sandUsageStatus: nil, now: .fixedNow
        )
        #expect(parsed.snapshot.limits.isEmpty)
        #expect(parsed.snapshot.schemaWarnings.contains {
            $0.contains("get-current-period-usage response missing")
        })
        #expect(parsed.snapshot.schemaWarnings.contains {
            $0.contains("get-sand-usage-status response missing")
        })
    }
}

@Suite("Cursor provider isolation")
struct CursorProviderIsolationTests {
    @Test("Cursor gets its own compact tag and dashboard URL")
    func identity() {
        #expect(UsageProvider.cursor.compactTag == "C")
        #expect(UsageProvider.cursor.displayName == "Cursor")
        #expect(UsageProvider.cursor.dashboardURL.absoluteString == "https://cursor.com/dashboard/spending")
        #expect(UsageProvider.cursor.compactTag != UsageProvider.claude.compactTag)
        #expect(UsageProvider.cursor.compactTag != UsageProvider.chatgpt.compactTag)
    }

    @Test("a three-way tightest selection can name Cursor as the owner")
    func tightestNamesCursor() {
        let claude = providerSnapshot(.claude, percent: 40)
        let chatGPT = providerSnapshot(.chatgpt, percent: 55)
        let cursor = providerSnapshot(.cursor, percent: 81)
        let selection = ProviderUsageSelection.tightest(snapshots: [
            .claude: claude, .chatgpt: chatGPT, .cursor: cursor,
        ])
        #expect(selection?.provider == .cursor)
        #expect(selection?.limit.percent == 81)
    }

    @Test("provider caches for all three providers cannot collide")
    func threeProviderCaches() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cursorURL = directory.appendingPathComponent("cursor.json")
        let snapshot = providerSnapshot(.cursor, percent: 42)
        LastUsageCache.save(snapshot, provider: .cursor, url: cursorURL)
        #expect(LastUsageCache.load(provider: .cursor, url: cursorURL)?.bottleneck?.percent == 42)
        #expect(LastUsageCache.load(provider: .claude, url: cursorURL) == nil)
    }

    private func providerSnapshot(_ provider: UsageProvider, percent: Double) -> UsageSnapshot {
        UsageSnapshot(
            fetchedAt: .fixedNow,
            limits: [
                LimitWindow(
                    id: "cursor_models", kind: "cursor_models_included", group: .other,
                    title: "Cursor Models", shortTitle: "Cursor Models",
                    percent: percent, resetsAt: nil, severity: Severity.from(percent: percent),
                    provider: provider
                ),
            ],
            spend: nil,
            provider: provider
        )
    }
}

@Suite("Cursor session and networking")
struct CursorUsageServiceTests {
    @Test("no stored session throws missingCursorSession without any network call")
    func missingSession() async throws {
        let transport = StubCursorTransport(responses: [:])
        let service = CursorUsageService(
            cookieStore: StubCursorCookieStore(cookie: nil), transport: transport
        )
        #expect(!service.hasStoredSession())
        do {
            _ = try await service.fetchUsage()
            Issue.record("Expected missingCursorSession")
        } catch let error as UsageAPIError {
            #expect(error == .missingCursorSession)
        }
        let requests = await transport.capturedRequests()
        #expect(requests.isEmpty)
    }

    @Test("a rejected cookie maps to unauthorized without exposing it")
    func rejectedCookie() async throws {
        let transport = StubCursorTransport(responses: [
            CursorUsageService.planInfoURL: CursorHTTPResponse(data: Data(), statusCode: 401),
            CursorUsageService.currentPeriodUsageURL: CursorHTTPResponse(data: Data(), statusCode: 401),
            CursorUsageService.sandUsageStatusURL: CursorHTTPResponse(data: Data(), statusCode: 401),
        ])
        let service = CursorUsageService(
            cookieStore: StubCursorCookieStore(cookie: "SessionCookie=invented-value"),
            transport: transport
        )
        #expect(service.hasStoredSession())
        do {
            _ = try await service.fetchUsage()
            Issue.record("Expected unauthorized")
        } catch let error as UsageAPIError {
            #expect(error == .unauthorized)
        }
        let requests = await transport.capturedRequests()
        #expect(!requests.isEmpty)
        for request in requests {
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "SessionCookie=invented-value")
            #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        }
    }

    @Test("a full set of successful responses combines into one snapshot")
    func successfulFetch() async throws {
        let transport = StubCursorTransport(responses: [
            CursorUsageService.planInfoURL: CursorHTTPResponse(
                data: try Fixture.data("cursor-plan-info"), statusCode: 200
            ),
            CursorUsageService.currentPeriodUsageURL: CursorHTTPResponse(
                data: try Fixture.data("cursor-current-period-usage"), statusCode: 200
            ),
            CursorUsageService.sandUsageStatusURL: CursorHTTPResponse(
                data: try Fixture.data("cursor-sand-usage-status"), statusCode: 200
            ),
        ])
        let service = CursorUsageService(
            cookieStore: StubCursorCookieStore(cookie: "SessionCookie=invented-value"),
            transport: transport
        )
        let result = try await service.fetchUsage()
        #expect(result.planLabel == "Pro+")
        #expect(result.snapshot.provider == .cursor)
        #expect(result.snapshot.limits.count == 3)
    }
}

private actor StubCursorTransport: CursorHTTPTransport {
    private let responses: [URL: CursorHTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [URL: CursorHTTPResponse]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> CursorHTTPResponse {
        requests.append(request)
        guard let url = request.url, let response = responses[url] else {
            return CursorHTTPResponse(data: Data(), statusCode: 404)
        }
        return response
    }

    func capturedRequests() -> [URLRequest] { requests }
}

private struct StubCursorCookieStore: CursorSessionCookieStoreProtocol {
    let cookie: String?
    func load() -> String? { cookie }
    func save(cookie: String) -> Bool { true }
    func clear() -> Bool { true }
}

private func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("claude-usage-cursor-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
