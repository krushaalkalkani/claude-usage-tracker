import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite("Cursor usage parsing")
struct CursorUsageParserTests {
    @Test("normal included-usage and Grok Bot windows parse with plan label")
    func normalWindows() throws {
        let parsed = CursorUsageParser.parse(
            planInfo: try Fixture.json("cursor-plan-info"),
            currentPeriodUsage: try Fixture.json("cursor-current-period-usage"),
            sandUsageStatus: try Fixture.json("cursor-sand-usage-status"),
            now: .fixedNow
        )
        #expect(parsed.snapshot.provider == .cursor)
        #expect(parsed.planLabel == "Pro+")
        #expect(parsed.snapshot.limits.count == 2)

        let included = try #require(parsed.snapshot.limits.first { $0.id == "included_usage" })
        #expect(included.percent == 30)
        #expect(included.provider == .cursor)
        #expect(included.resetsAt == Date(timeIntervalSince1970: 1_790_224_537))

        let grokBot = try #require(parsed.snapshot.limits.first { $0.id == "grok_bot" })
        #expect(grokBot.shortTitle == "Grok Bot")
        #expect(abs(grokBot.percent - 23.727263) < 0.0001)
        #expect(grokBot.resetsAt == ISO8601.parse("2026-08-31T19:28:09.358Z")?.truncatingSubsecond)

        // Included usage (30%) is the tighter of the two, so it is the bottleneck.
        #expect(parsed.snapshot.bottleneck?.id == "included_usage")
    }

    @Test("only the included-usage window parses when Grok Bot status is unavailable")
    func missingSandStatus() throws {
        let parsed = CursorUsageParser.parse(
            planInfo: nil,
            currentPeriodUsage: try Fixture.json("cursor-current-period-usage"),
            sandUsageStatus: nil,
            now: .fixedNow
        )
        #expect(parsed.snapshot.limits.count == 1)
        #expect(parsed.snapshot.limits.first?.id == "included_usage")
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
        // totalPercentUsed arrived as the string "-15": still readable, then clamped to 0.
        let included = try #require(parsed.snapshot.limits.first { $0.id == "included_usage" })
        #expect(included.percent == 0)
        #expect(included.rawPercent == -15)
        #expect(included.resetsAt == nil)  // billingCycleEnd was not a number.

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
                    id: "included_usage", kind: "cursor_included_usage", group: .other,
                    title: "Included usage", shortTitle: "Included usage",
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
        #expect(result.snapshot.limits.count == 2)
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
