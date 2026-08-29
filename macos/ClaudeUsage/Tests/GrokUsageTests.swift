import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite("Grok usage parsing")
struct GrokUsageParserTests {
    @Test("the pooled weekly allowance parses with its product split and plan label")
    func normalWindow() throws {
        let parsed = GrokUsageParser.parse(
            credits: try Fixture.json("grok-credits"),
            subscriptions: try Fixture.json("grok-subscriptions"),
            now: .fixedNow
        )
        #expect(parsed.snapshot.provider == .grok)
        #expect(parsed.planLabel == "SuperGrok")

        // One meter, not one per product.
        #expect(parsed.snapshot.limits.count == 1)
        let allowance = try #require(parsed.snapshot.limits.first)
        #expect(allowance.id == "grok_allowance")
        #expect(allowance.percent == 100)
        #expect(allowance.group == .weekly)
        #expect(allowance.shortTitle == "Weekly")
        #expect(allowance.severity == .critical)
        #expect(allowance.provider == .grok)
        #expect(allowance.resetsAt == ISO8601.parse("2026-09-01T09:50:00Z"))
        // Measured from the period itself rather than assumed from the group.
        #expect(allowance.windowDuration == 7 * 86_400)
        #expect(parsed.snapshot.bottleneck?.id == "grok_allowance")
    }

    @Test("product usage becomes shares, ranked, with zero-usage products dropped")
    func productShares() throws {
        let parsed = GrokUsageParser.parse(
            credits: try Fixture.json("grok-credits"), subscriptions: nil, now: .fixedNow
        )
        // Voice reported 0 and contributes nothing to read.
        #expect(parsed.snapshot.productShares.map(\.label) == ["Automations", "Chat", "Imagine"])
        #expect(parsed.snapshot.productShares.map(\.percent) == [97, 2, 1])
        #expect(parsed.snapshot.productShares.first?.id == "grok_tasks")

        // The crux of modelling these as shares: a 97 % slice of a pooled meter must never
        // become a limit window of its own, or it would rank as a peer of the real limit in
        // "Other limits" and raise a critical alert about a quota that does not exist.
        #expect(parsed.snapshot.limits.count == 1)
        #expect(!parsed.snapshot.limits.contains { $0.id.contains("tasks") })
    }

    @Test("an unspent, uncapped account gets no spend section and a zero credits balance")
    func noOnDemandSpend() throws {
        let parsed = GrokUsageParser.parse(
            credits: try Fixture.json("grok-credits"), subscriptions: nil, now: .fixedNow
        )
        #expect(parsed.snapshot.spend == nil)
        #expect(parsed.snapshot.credits?.balance == "$0.00")
        #expect(parsed.snapshot.credits?.hasCredits == false)
    }

    @Test("the RPC encoding parses identically to the REST one")
    func rpcEncoding() throws {
        // Numeric enums and {seconds, nanos} timestamps instead of wire names and RFC 3339.
        let parsed = GrokUsageParser.parse(
            credits: try Fixture.json("grok-credits-rpc-shapes"), subscriptions: nil,
            now: .fixedNow
        )
        let allowance = try #require(parsed.snapshot.limits.first)
        #expect(allowance.percent == 41.5)
        // type 1 = MONTHLY, so it is not filed under the weekly group.
        #expect(allowance.group == .other)
        #expect(allowance.shortTitle == "Monthly")
        #expect(allowance.resetsAt == Date(timeIntervalSince1970: 1_790_246_400))

        #expect(parsed.snapshot.productShares.map(\.label) == ["Chat", "Automations"])

        // int64 cents sent as a number rather than a string.
        let spend = try #require(parsed.snapshot.spend)
        #expect(spend.enabled)
        #expect(spend.used?.formatted == "$12.50")
        #expect(spend.limit?.formatted == "$50.00")
        #expect(spend.percent == 25)
        #expect(parsed.snapshot.credits?.balance == "$14.99")
    }

    @Test("malformed fields clamp or are dropped instead of throwing")
    func malformedFields() throws {
        let parsed = GrokUsageParser.parse(
            credits: try Fixture.json("grok-credits-malformed"), subscriptions: nil,
            now: .fixedNow
        )
        // creditUsagePercent arrived as the string "-12": still readable, then clamped to 0.
        let allowance = try #require(parsed.snapshot.limits.first)
        #expect(allowance.percent == 0)
        #expect(allowance.rawPercent == -12)
        #expect(allowance.resetsAt == nil)  // "tomorrow" is not a timestamp.
        #expect(allowance.windowDuration == nil)  // unspecified period, nothing to assume.

        // A product whose percent is unreadable is dropped; an enum constant this build has
        // never heard of still renders, as "Other", rather than vanishing.
        #expect(parsed.snapshot.productShares.map(\.label) == ["Other", "Other"])
        #expect(parsed.snapshot.productShares.map(\.percent) == [8, 4])

        #expect(parsed.snapshot.spend == nil)
        #expect(parsed.snapshot.credits == nil)
    }

    @Test("a config with no percentage yields no synthetic usage")
    func noUsageReported() throws {
        let parsed = GrokUsageParser.parse(
            credits: try Fixture.json("grok-credits-no-usage"), subscriptions: nil, now: .fixedNow
        )
        #expect(parsed.snapshot.limits.isEmpty)
        #expect(parsed.snapshot.bottleneck == nil)
        #expect(parsed.snapshot.schemaWarnings.contains { $0.contains("missing creditUsagePercent") })
        #expect(parsed.snapshot.schemaWarnings.contains { $0.contains("no Grok usage windows") })
    }

    @Test("a response with no config object is reported, not silently blank")
    func emptyPayload() throws {
        let parsed = GrokUsageParser.parse(
            credits: try Fixture.json("grok-empty"), subscriptions: try Fixture.json("grok-empty"),
            now: .fixedNow
        )
        #expect(parsed.snapshot.limits.isEmpty)
        #expect(parsed.planLabel == nil)
        #expect(parsed.snapshot.schemaWarnings.contains { $0.contains("has no config object") })
    }

    @Test("an entirely missing response is reported, not silently blank")
    func allMissing() {
        let parsed = GrokUsageParser.parse(credits: nil, subscriptions: nil, now: .fixedNow)
        #expect(parsed.snapshot.limits.isEmpty)
        #expect(parsed.snapshot.schemaWarnings.contains {
            $0.contains("the Grok credits response is missing")
        })
    }

    @Test("an active subscription wins the plan label over a lapsed one")
    func planLabelPrefersActive() throws {
        // The fixture lists an expired X Premium+ row before the active SuperGrok row.
        let parsed = GrokUsageParser.parse(
            credits: nil, subscriptions: try Fixture.json("grok-subscriptions"), now: .fixedNow
        )
        #expect(parsed.planLabel == "SuperGrok")
    }

    @Test("an unrecognized tier is dropped rather than shown as a raw enum constant")
    func unknownTier() throws {
        let subscriptions = JSONValue.object([
            "subscriptions": .array([
                .object([
                    "tier": .string("SUBSCRIPTION_TIER_SOMETHING_NEW"),
                    "status": .string("SUBSCRIPTION_STATUS_ACTIVE"),
                ]),
            ]),
        ])
        let parsed = GrokUsageParser.parse(
            credits: nil, subscriptions: subscriptions, now: .fixedNow
        )
        #expect(parsed.planLabel == nil)
    }

    @Test("every known tier maps to the wording grok.com itself uses")
    func tierLabels() {
        func label(_ tier: String) -> String? {
            GrokUsageParser.parse(
                credits: nil,
                subscriptions: .object([
                    "subscriptions": .array([.object(["tier": .string(tier)])]),
                ]),
                now: .fixedNow
            ).planLabel
        }
        #expect(label("SUBSCRIPTION_TIER_GROK_PRO") == "SuperGrok")
        #expect(label("SUBSCRIPTION_TIER_SUPER_GROK_PLUS") == "SuperGrok Plus")
        #expect(label("SUBSCRIPTION_TIER_SUPER_GROK_PRO") == "SuperGrok Heavy")
        #expect(label("SUBSCRIPTION_TIER_SUPER_GROK_LITE") == "SuperGrok Lite")
        #expect(label("SUBSCRIPTION_TIER_X_PREMIUM_PLUS") == "X Premium+")
        #expect(label("SUBSCRIPTION_TIER_X_PREMIUM") == "X Premium")
        #expect(label("SUBSCRIPTION_TIER_X_BASIC") == "X Basic")
    }

    @Test("the raw payload is omitted when the caller asks for no raw")
    func rawOmitted() throws {
        let parsed = GrokUsageParser.parse(
            credits: try Fixture.json("grok-credits"), subscriptions: nil, now: .fixedNow,
            keepRaw: false
        )
        #expect(parsed.snapshot.raw == nil)
    }
}

@Suite("Grok provider isolation")
struct GrokProviderIsolationTests {
    @Test("Grok gets its own compact tag and dashboard URL")
    func identity() {
        #expect(UsageProvider.grok.displayName == "Grok")
        #expect(UsageProvider.grok.dashboardURL.absoluteString == "https://grok.com/?_s=usage")
        // No two providers may share a status-item tag, or the menu bar becomes ambiguous.
        let tags = UsageProvider.allCases.map(\.compactTag)
        #expect(Set(tags).count == tags.count)
    }

    @Test("a four-way tightest selection can name Grok as the owner")
    func tightestNamesGrok() {
        let selection = ProviderUsageSelection.tightest(snapshots: [
            .claude: providerSnapshot(.claude, percent: 40),
            .chatgpt: providerSnapshot(.chatgpt, percent: 55),
            .cursor: providerSnapshot(.cursor, percent: 81),
            .grok: providerSnapshot(.grok, percent: 96),
        ])
        #expect(selection?.provider == .grok)
        #expect(selection?.limit.percent == 96)
    }

    @Test("every provider has its own on-disk cache file")
    func cacheFilesAreDistinct() {
        let paths = UsageProvider.allCases.map { AppPaths.lastUsageFile(for: $0).lastPathComponent }
        #expect(Set(paths).count == paths.count)
        #expect(paths.contains("last-usage-grok.json"))
    }

    @Test("a Grok cache cannot be read back as another provider's")
    func cacheCannotCollide() throws {
        let directory = try temporaryGrokDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("grok.json")
        LastUsageCache.save(providerSnapshot(.grok, percent: 42), provider: .grok, url: url)
        #expect(LastUsageCache.load(provider: .grok, url: url)?.bottleneck?.percent == 42)
        #expect(LastUsageCache.load(provider: .cursor, url: url) == nil)
    }

    @Test("product shares survive a cache round-trip")
    func sharesPersist() throws {
        let directory = try temporaryGrokDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("grok.json")
        let parsed = GrokUsageParser.parse(
            credits: try Fixture.json("grok-credits"), subscriptions: nil, now: .fixedNow
        )
        LastUsageCache.save(parsed.snapshot, provider: .grok, url: url)
        let restored = try #require(LastUsageCache.load(provider: .grok, url: url))
        #expect(restored.productShares.map(\.label) == ["Automations", "Chat", "Imagine"])
        // The raw payload is never persisted, for any provider.
        #expect(restored.raw == nil)
    }

    @Test("a snapshot written before product shares existed still decodes")
    func decodesWithoutShares() throws {
        let legacy = Data("""
        {"provider":"grok","fetchedAt":"2026-08-08T17:30:00Z","limits":[],"schemaWarnings":[]}
        """.utf8)
        let snapshot = try JSONDecoder.store.decode(UsageSnapshot.self, from: legacy)
        #expect(snapshot.productShares.isEmpty)
    }

    private func providerSnapshot(_ provider: UsageProvider, percent: Double) -> UsageSnapshot {
        UsageSnapshot(
            fetchedAt: .fixedNow,
            limits: [
                LimitWindow(
                    id: "grok_allowance", kind: "grok_credit_usage", group: .weekly,
                    title: "Plan usage · weekly", shortTitle: "Weekly",
                    percent: percent, resetsAt: nil, severity: Severity.from(percent: percent),
                    provider: provider
                ),
            ],
            spend: nil,
            provider: provider
        )
    }
}

@Suite("Grok gRPC-Web wire format")
struct GrokWireFormatTests {
    @Test("a real credits message decodes into the shape the parser expects")
    func decodesCreditsMessage() throws {
        let config = Proto.message([
            .float(1, 41.5),                                   // credit_usage_percent
            .message(2, Proto.message([.varint(1, 5000)])),     // on_demand_cap  { val }
            .message(3, Proto.message([.varint(1, 1250)])),     // on_demand_used { val }
            .message(5, Proto.timestamp(1_790_246_400)),        // billing_period_end
            .message(7, Proto.message([                         // product_usage[0]
                .varint(1, 8), .float(2, 30),
            ])),
            .message(7, Proto.message([                         // product_usage[1]
                .varint(1, 4), .float(2, 11.5),
            ])),
            .message(8, Proto.message([                         // current_period
                .varint(1, 2),                                  // WEEKLY
                .message(2, Proto.timestamp(1_789_641_600)),
                .message(3, Proto.timestamp(1_790_246_400)),
            ])),
            .message(12, Proto.message([.varint(1, 1499)])),    // prepaid_balance
        ])
        let response = Proto.message([.message(1, config)])

        let json = try #require(GrokCreditsMessage.decode(response))
        let parsed = GrokUsageParser.parse(credits: json, subscriptions: nil, now: .fixedNow)

        let allowance = try #require(parsed.snapshot.limits.first)
        #expect(allowance.percent == 41.5)
        #expect(allowance.group == .weekly)
        #expect(allowance.resetsAt == Date(timeIntervalSince1970: 1_790_246_400))
        #expect(allowance.windowDuration == 7 * 86_400)

        // Enum 8 = GROK_TASKS, 4 = GROK_CHAT — resolved from the number, with no wire name.
        #expect(parsed.snapshot.productShares.map(\.label) == ["Automations", "Chat"])
        #expect(parsed.snapshot.spend?.used?.formatted == "$12.50")
        #expect(parsed.snapshot.spend?.limit?.formatted == "$50.00")
        #expect(parsed.snapshot.credits?.balance == "$14.99")
    }

    @Test("a zero-valued Cent decodes as zero, not as absent")
    func zeroCent() throws {
        // proto3 omits zero-valued scalars, so a $0.00 balance arrives as an empty submessage.
        // Reading that as "no balance" would hide the Extra Usage Credits row entirely.
        let config = Proto.message([.float(1, 10), .message(12, Data())])
        let json = try #require(GrokCreditsMessage.decode(Proto.message([.message(1, config)])))
        let parsed = GrokUsageParser.parse(credits: json, subscriptions: nil, now: .fixedNow)
        #expect(parsed.snapshot.credits?.balance == "$0.00")
    }

    @Test("unknown fields are skipped rather than derailing the decode")
    func unknownFields() throws {
        let config = Proto.message([
            .float(1, 55),
            .varint(999, 1234),                       // a field this build has never seen
            .message(998, Proto.message([.varint(1, 7)])),
            .message(8, Proto.message([.varint(1, 2)])),
        ])
        let json = try #require(GrokCreditsMessage.decode(Proto.message([.message(1, config)])))
        let parsed = GrokUsageParser.parse(credits: json, subscriptions: nil, now: .fixedNow)
        #expect(parsed.snapshot.limits.first?.percent == 55)
    }

    @Test("truncated bytes decode to nil rather than trapping")
    func truncatedMessage() {
        let full = Proto.message([.message(1, Proto.message([.float(1, 20)]))])
        for length in 1..<full.count {
            // Never a crash, whatever the prefix. Nil or a partial config are both fine.
            _ = GrokCreditsMessage.decode(full.prefix(length))
        }
        #expect(GrokCreditsMessage.decode(Data([0xFF, 0xFF, 0xFF])) == nil)
    }

    @Test("gRPC-Web frames split messages from trailers")
    func framing() {
        let body = GrokGRPCWebFrames.frame(Data([1, 2, 3]))
            + trailerFrame("grpc-status: 0\r\ngrpc-message: \r\n")
        let frames = GrokGRPCWebFrames.parse(body)
        #expect(frames.message == Data([1, 2, 3]))
        #expect(frames.trailers["grpc-status"] == "0")
    }

    @Test("a request frame carries its own length")
    func requestFraming() {
        #expect(GrokGRPCWebFrames.frame(Data()) == Data([0, 0, 0, 0, 0]))
        #expect(GrokGRPCWebFrames.frame(Data([9])) == Data([0, 0, 0, 0, 1, 9]))
    }

    @Test("gRPC status codes map to the app's own error vocabulary")
    func statusMapping() {
        #expect(GrokRPCStatus.error(code: 0, message: nil) == nil)
        // The status that matters most: an expired session must send the user to reconnect,
        // and it arrives on an HTTP 200.
        #expect(GrokRPCStatus.error(code: 16, message: "No%20credentials%20presented.")
            == .unauthorized)
        #expect(GrokRPCStatus.error(code: 7, message: nil) == .forbidden)
        #expect(GrokRPCStatus.error(code: 8, message: nil) == .rateLimited(retryAfter: nil))
        if case .unrecognizedSchema = GrokRPCStatus.error(code: 12, message: nil) {} else {
            Issue.record("UNIMPLEMENTED should read as a schema problem, not an auth one")
        }
    }
}

@Suite("Grok session and networking")
struct GrokUsageServiceTests {
    @Test("no stored session throws missingGrokSession without any network call")
    func missingSession() async throws {
        let transport = StubGrokTransport(responses: [:])
        let service = GrokUsageService(
            cookieStore: StubGrokCookieStore(cookie: nil), transport: transport
        )
        #expect(!service.hasStoredSession())
        do {
            _ = try await service.fetchUsage()
            Issue.record("Expected missingGrokSession")
        } catch let error as UsageAPIError {
            #expect(error == .missingGrokSession)
        }
        #expect(await transport.capturedRequests().isEmpty)
    }

    @Test("a rejected cookie maps to unauthorized despite the HTTP 200")
    func rejectedCookie() async throws {
        // Exactly what grok.com returns for an unauthenticated call: HTTP 200, empty body,
        // and the real outcome in grpc-status. Reading the HTTP status alone would call this
        // a success.
        let transport = StubGrokTransport(responses: [
            GrokUsageService.creditsURL: GrokHTTPResponse(
                data: Data(), statusCode: 200,
                headers: [
                    "grpc-status": "16",
                    "grpc-message": "No%20credentials%20presented.",
                ]
            ),
            GrokUsageService.subscriptionsURL: GrokHTTPResponse(data: Data(), statusCode: 401),
        ])
        let service = GrokUsageService(
            cookieStore: StubGrokCookieStore(cookie: "sso=invented-value"), transport: transport
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
            #expect(request.value(forHTTPHeaderField: "Cookie") == "sso=invented-value")
            #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
            // Never in the URL, where it could reach a log or a Referer.
            #expect(request.url?.absoluteString.contains("invented-value") == false)
        }
    }

    @Test("the credits call is a gRPC-Web POST and subscriptions is a plain JSON GET")
    func protocolsPerEndpoint() async throws {
        let transport = StubGrokTransport(responses: [
            GrokUsageService.creditsURL: successResponse(percent: 62),
            GrokUsageService.subscriptionsURL: GrokHTTPResponse(
                data: try Fixture.data("grok-subscriptions"), statusCode: 200
            ),
        ])
        _ = try await GrokUsageService(
            cookieStore: StubGrokCookieStore(cookie: "sso=x"), transport: transport
        ).fetchUsage()

        let requests = await transport.capturedRequests()
        let credits = try #require(requests.first { $0.url == GrokUsageService.creditsURL })
        #expect(credits.httpMethod == "POST")
        #expect(credits.value(forHTTPHeaderField: "Content-Type") == "application/grpc-web+proto")
        // Five bytes: an empty request message in one gRPC-Web frame.
        #expect(credits.httpBody == Data([0, 0, 0, 0, 0]))

        let subscriptions = try #require(
            requests.first { $0.url == GrokUsageService.subscriptionsURL }
        )
        #expect(subscriptions.httpMethod == "GET")
        #expect(subscriptions.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("a successful fetch combines credits and subscriptions into one snapshot")
    func successfulFetch() async throws {
        let transport = StubGrokTransport(responses: [
            GrokUsageService.creditsURL: successResponse(percent: 100),
            GrokUsageService.subscriptionsURL: GrokHTTPResponse(
                data: try Fixture.data("grok-subscriptions"), statusCode: 200
            ),
        ])
        let result = try await GrokUsageService(
            cookieStore: StubGrokCookieStore(cookie: "sso=x"), transport: transport
        ).fetchUsage()
        #expect(result.planLabel == "SuperGrok")
        #expect(result.snapshot.provider == .grok)
        #expect(result.snapshot.limits.first?.percent == 100)
        #expect(result.snapshot.productShares.map(\.label) == ["Automations", "Chat"])
    }

    @Test("a failed subscriptions call costs the plan label, not the usage numbers")
    func subscriptionsAreOptional() async throws {
        let transport = StubGrokTransport(responses: [
            GrokUsageService.creditsURL: successResponse(percent: 47),
            GrokUsageService.subscriptionsURL: GrokHTTPResponse(data: Data(), statusCode: 500),
        ])
        let result = try await GrokUsageService(
            cookieStore: StubGrokCookieStore(cookie: "sso=x"), transport: transport
        ).fetchUsage()
        #expect(result.planLabel == nil)
        #expect(result.snapshot.limits.first?.percent == 47)
    }

    @Test("a success-status response with no usable message surfaces as a schema error")
    func emptySuccess() async throws {
        let transport = StubGrokTransport(responses: [
            GrokUsageService.creditsURL: GrokHTTPResponse(
                data: GrokGRPCWebFrames.frame(Proto.message([.message(1, Data())]))
                    + trailerFrame("grpc-status: 0\r\n"),
                statusCode: 200
            ),
        ])
        do {
            _ = try await GrokUsageService(
                cookieStore: StubGrokCookieStore(cookie: "sso=x"), transport: transport
            ).fetchUsage()
            Issue.record("Expected unrecognizedSchema")
        } catch let error as UsageAPIError {
            guard case .unrecognizedSchema = error else {
                Issue.record("Expected unrecognizedSchema, got \(error)")
                return
            }
        }
    }

    @Test("a gRPC status in the body's trailer frame is honoured too")
    func trailerFrameStatus() async throws {
        let transport = StubGrokTransport(responses: [
            GrokUsageService.creditsURL: GrokHTTPResponse(
                data: trailerFrame("grpc-status: 7\r\ngrpc-message: nope\r\n"),
                statusCode: 200
            ),
        ])
        do {
            _ = try await GrokUsageService(
                cookieStore: StubGrokCookieStore(cookie: "sso=x"), transport: transport
            ).fetchUsage()
            Issue.record("Expected forbidden")
        } catch let error as UsageAPIError {
            #expect(error == .forbidden)
        }
    }

    private func successResponse(percent: Double) -> GrokHTTPResponse {
        let config = Proto.message([
            .float(1, percent),
            .message(7, Proto.message([.varint(1, 8), .float(2, percent * 0.9)])),
            .message(7, Proto.message([.varint(1, 4), .float(2, percent * 0.1)])),
            .message(8, Proto.message([
                .varint(1, 2),
                .message(3, Proto.timestamp(1_790_246_400)),
            ])),
        ])
        return GrokHTTPResponse(
            data: GrokGRPCWebFrames.frame(Proto.message([.message(1, config)]))
                + trailerFrame("grpc-status: 0\r\n"),
            statusCode: 200
        )
    }
}

// MARK: - Test helpers

/// A minimal protobuf *encoder*, so the decoder is exercised against real wire bytes rather
/// than against a hand-written approximation of them.
enum Proto {
    enum Field {
        case varint(Int, Int64)
        case float(Int, Double)
        case message(Int, Data)
    }

    static func message(_ fields: [Field]) -> Data {
        var out = Data()
        for field in fields {
            switch field {
            case .varint(let number, let value):
                out.append(tag(number, 0))
                out.append(varint(UInt64(bitPattern: value)))
            case .float(let number, let value):
                out.append(tag(number, 5))
                withUnsafeBytes(of: Float(value).bitPattern.littleEndian) {
                    out.append(contentsOf: $0)
                }
            case .message(let number, let payload):
                out.append(tag(number, 2))
                out.append(varint(UInt64(payload.count)))
                out.append(payload)
            }
        }
        return out
    }

    static func timestamp(_ seconds: Int64) -> Data {
        message([.varint(1, seconds)])
    }

    private static func tag(_ number: Int, _ wireType: UInt8) -> Data {
        varint(UInt64(number) << 3 | UInt64(wireType))
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }
}

private func trailerFrame(_ text: String) -> Data {
    let payload = Data(text.utf8)
    var out = Data([0x80])
    let length = UInt32(payload.count)
    out.append(UInt8(truncatingIfNeeded: length >> 24))
    out.append(UInt8(truncatingIfNeeded: length >> 16))
    out.append(UInt8(truncatingIfNeeded: length >> 8))
    out.append(UInt8(truncatingIfNeeded: length))
    out.append(payload)
    return out
}

private actor StubGrokTransport: GrokHTTPTransport {
    private let responses: [URL: GrokHTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [URL: GrokHTTPResponse]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> GrokHTTPResponse {
        requests.append(request)
        guard let url = request.url, let response = responses[url] else {
            return GrokHTTPResponse(data: Data(), statusCode: 404)
        }
        return response
    }

    func capturedRequests() -> [URLRequest] { requests }
}

private struct StubGrokCookieStore: GrokSessionCookieStoreProtocol {
    let cookie: String?
    func load() -> String? { cookie }
    func save(cookie: String) -> Bool { true }
    func clear() -> Bool { true }
}

private func temporaryGrokDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("claude-usage-grok-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
