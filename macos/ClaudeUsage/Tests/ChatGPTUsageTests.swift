import Darwin
import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite("ChatGPT usage parsing")
struct ChatGPTUsageParserTests {
    @Test("normal session and weekly windows use the supplied duration and epoch reset")
    func normalWindows() throws {
        let parsed = ChatGPTUsageParser.parseDirect(
            try Fixture.json("chatgpt-normal"), now: .fixedNow
        )

        #expect(parsed.snapshot.provider == .chatgpt)
        #expect(parsed.planLabel == "Pro")
        #expect(parsed.snapshot.sessionLimit?.percent == 24)
        #expect(parsed.snapshot.sessionLimit?.windowDuration == 18_000)
        #expect(parsed.snapshot.weeklyLimit?.percent == 41)
        #expect(parsed.snapshot.weeklyLimit?.windowDuration == 604_800)
        #expect(parsed.snapshot.sessionLimit?.resetsAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(parsed.snapshot.credits?.balance == "12.50")
    }

    @Test("additional model-specific windows remain named extra limits")
    func additionalLimits() throws {
        let parsed = ChatGPTUsageParser.parseDirect(
            try Fixture.json("chatgpt-additional"), now: .fixedNow
        )

        #expect(parsed.snapshot.limits.count == 4)
        #expect(parsed.snapshot.modelLimits.count == 2)
        #expect(parsed.snapshot.modelLimits.contains { $0.modelName == "GPT-Example-Codex" && $0.percent == 67 })
        #expect(parsed.snapshot.modelLimits.contains { $0.modelName == "Fast Agent" && $0.percent == 8 })
        #expect(parsed.snapshot.modelLimits.allSatisfy { $0.provider == .chatgpt })
    }

    @Test("missing primary stays unknown rather than becoming zero")
    func missingPrimary() throws {
        let parsed = ChatGPTUsageParser.parseDirect(
            try Fixture.json("chatgpt-missing-primary"), now: .fixedNow
        )
        #expect(parsed.snapshot.sessionLimit == nil)
        #expect(parsed.snapshot.weeklyLimit?.percent == 52)
        #expect(!parsed.snapshot.limits.contains { $0.percent == 0 })
    }

    @Test("an empty ChatGPT payload has no synthetic usage")
    func emptyPayload() throws {
        let parsed = ChatGPTUsageParser.parseDirect(
            try Fixture.json("chatgpt-empty"), now: .fixedNow
        )
        #expect(parsed.snapshot.limits.isEmpty)
        #expect(parsed.snapshot.bottleneck == nil)
        #expect(parsed.snapshot.schemaWarnings.contains { $0.contains("no readable") })
    }

    @Test("malformed entries are skipped beside valid entries and percentages clamp")
    func malformedAndClamped() throws {
        let parsed = ChatGPTUsageParser.parseDirect(
            try Fixture.json("chatgpt-malformed"), now: .fixedNow
        )

        #expect(parsed.snapshot.limits.count == 2)
        #expect(parsed.snapshot.sessionLimit?.percent == 100)
        #expect(parsed.snapshot.sessionLimit?.rawPercent == 133.5)
        #expect(parsed.snapshot.sessionLimit?.resetsAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(parsed.snapshot.modelLimits.first?.percent == 73)
        #expect(parsed.snapshot.schemaWarnings.contains { $0.contains("clamped") })
        #expect(parsed.snapshot.schemaWarnings.contains { $0.contains("no valid used percent") })
        #expect(parsed.snapshot.schemaWarnings.contains { $0.contains("no rate_limit object") })
    }

    @Test("app-server primary classification follows duration instead of position")
    func appServerDurationClassification() throws {
        let json = try JSONValue.parse(Data(#"""
        {
          "rateLimits": {
            "limitId": "codex",
            "planType": "pro",
            "primary": {
              "usedPercent": 58,
              "resetsAt": 1790400000,
              "windowDurationMins": 10080
            },
            "secondary": null
          }
        }
        """#.utf8))
        let parsed = ChatGPTUsageParser.parseAppServer(
            json, accountPlan: "pro", now: .fixedNow
        )

        #expect(parsed.snapshot.sessionLimit == nil)
        #expect(parsed.snapshot.weeklyLimit?.percent == 58)
        #expect(parsed.snapshot.weeklyLimit?.windowDuration == 604_800)
    }
}

@Suite("ChatGPT authentication and process safety", .serialized)
struct ChatGPTServiceTests {
    @Test("authentication-required app-server state is reported without starting login")
    func authenticationRequired() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-codex-auth")
        try writeExecutable(
            #"""
            #!/bin/sh
            IFS= read -r initialize
            printf '%s\n' '{"id":1,"result":{"serverInfo":{"name":"invented"}}}'
            IFS= read -r initialized
            IFS= read -r account_read
            printf '%s\n' '{"id":2,"result":{"account":null}}'
            """#,
            to: script
        )

        let client = CodexAppServerClient(
            executableURL: script, arguments: [],
            initializationTimeout: 1, requestTimeout: 1, terminationGrace: 0.05
        )
        do {
            _ = try await client.fetch(now: .fixedNow)
            Issue.record("Expected authentication-required state")
        } catch let error as CodexAppServerError {
            #expect(error == .authenticationRequired)
            #expect(error.usageError == .codexAuthenticationRequired)
        }
    }

    @Test("CLI timeout closes stdin and leaves no child process")
    func timeoutCleansUpProcess() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-codex-timeout")
        let pidFile = directory.appendingPathComponent("pid")
        try writeExecutable(
            #"""
            #!/bin/sh
            printf '%s' "$$" > "$1"
            IFS= read -r initialize
            printf '%s\n' '{"id":1,"result":{"serverInfo":{"name":"invented"}}}'
            IFS= read -r initialized
            IFS= read -r account_read
            IFS= read -r never_sent
            """#,
            to: script
        )

        let client = CodexAppServerClient(
            executableURL: script, arguments: [pidFile.path],
            initializationTimeout: 5, requestTimeout: 0.12, terminationGrace: 0.05
        )
        do {
            _ = try await client.fetch(now: .fixedNow)
            Issue.record("Expected a bounded timeout")
        } catch let error as CodexAppServerError {
            #expect(error == .timedOut)
        }

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        #expect(pid > 1)
        errno = 0
        let result = Darwin.kill(pid, 0)
        #expect(result == -1)
        #expect(errno == ESRCH)
    }

    @Test("cancelling a CLI refresh terminates the process and does not continue")
    func cancellationCleansUpProcess() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-codex-cancel")
        let pidFile = directory.appendingPathComponent("pid")
        try writeExecutable(
            #"""
            #!/bin/sh
            printf '%s' "$$" > "$1"
            IFS= read -r initialize
            printf '%s\n' '{"id":1,"result":{"serverInfo":{"name":"invented"}}}'
            IFS= read -r initialized
            IFS= read -r account_read
            IFS= read -r never_sent
            """#,
            to: script
        )
        let client = CodexAppServerClient(
            executableURL: script, arguments: [pidFile.path],
            initializationTimeout: 5, requestTimeout: 5, terminationGrace: 0.05
        )
        let task = Task { try await client.fetch(now: .fixedNow) }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: pidFile.path))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        errno = 0
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("direct fallback maps unauthorized without exposing credentials")
    func directUnauthorized() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        try Data(#"{"tokens":{"access_token":"invented-access-token","account_id":"invented-account"}}"#.utf8)
            .write(to: auth)
        let transport = StubChatGPTTransport(
            response: ChatGPTHTTPResponse(data: Data(), statusCode: 401)
        )
        let client = ChatGPTDirectUsageClient(
            credentials: CodexOAuthCredentialsStore(
                environment: ["CODEX_HOME": directory.path], homeDirectory: directory
            ),
            transport: transport
        )

        do {
            _ = try await client.fetch(now: .fixedNow)
            Issue.record("Expected unauthorized fallback response")
        } catch let error as UsageAPIError {
            #expect(error == .unauthorized)
            #expect(error.detail(for: .chatgpt).contains("codex login"))
        }
        let request = await transport.request()
        #expect(request?.httpMethod == "GET")
        #expect(request?.url == ChatGPTDirectUsageClient.usageURL)
        #expect(request?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "invented-account")
        #expect(request?.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }
}

@Suite("Provider isolation and migration")
struct ProviderIsolationTests {
    @Test("menu-bar tags distinguish Anthropic from OpenAI")
    func menuBarProviderTags() {
        #expect(UsageProvider.claude.compactTag == "A")
        #expect(UsageProvider.chatgpt.compactTag == "O")
    }

    @Test("menu bar follows the selected provider instead of the tighter other provider")
    func menuBarFollowsSelectedProvider() throws {
        var claude = ProviderUsageState(provider: .claude)
        claude.snapshot = providerSnapshot(.claude, percent: 100)
        claude.lastSuccessAt = .fixedNow
        var chatGPT = ProviderUsageState(provider: .chatgpt)
        chatGPT.snapshot = providerSnapshot(.chatgpt, percent: 36)
        chatGPT.lastSuccessAt = .fixedNow
        let states: [UsageProvider: ProviderUsageState] = [
            .claude: claude,
            .chatgpt: chatGPT,
        ]

        let claudeMetric = try #require(MenuBarMetricPolicy.selected(
            provider: .claude,
            states: states,
            primaryMetric: .auto,
            now: .fixedNow,
            refreshInterval: 120
        ))
        #expect(claudeMetric.provider == .claude)
        #expect(claudeMetric.percent == 100)

        let chatGPTMetric = try #require(MenuBarMetricPolicy.selected(
            provider: .chatgpt,
            states: states,
            primaryMetric: .auto,
            now: .fixedNow,
            refreshInterval: 120
        ))
        #expect(chatGPTMetric.provider == .chatgpt)
        #expect(chatGPTMetric.percent == 36)
    }

    @Test("Claude and ChatGPT errors remain independent")
    func independentErrors() {
        var states = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases.map {
                ($0, ProviderUsageState(provider: $0))
            }
        )
        states[.claude]?.lastError = .offline
        states[.chatgpt]?.lastError = .codexAuthenticationRequired
        #expect(states[.claude]?.lastError == .offline)
        #expect(states[.chatgpt]?.lastError == .codexAuthenticationRequired)
    }

    @Test("provider caches cannot collide and stale cached values are not current")
    func providerCachesAndStaleness() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let claudeURL = directory.appendingPathComponent("claude.json")
        let chatGPTURL = directory.appendingPathComponent("chatgpt.json")
        let claude = providerSnapshot(.claude, percent: 35)
        let chatGPT = providerSnapshot(.chatgpt, percent: 82)
        LastUsageCache.save(claude, provider: .claude, url: claudeURL)
        LastUsageCache.save(chatGPT, provider: .chatgpt, url: chatGPTURL)

        #expect(LastUsageCache.load(provider: .claude, url: claudeURL)?.bottleneck?.percent == 35)
        #expect(LastUsageCache.load(provider: .chatgpt, url: chatGPTURL)?.bottleneck?.percent == 82)
        #expect(LastUsageCache.load(provider: .chatgpt, url: claudeURL) == nil)

        // Simulate the pre-provider cache shape by removing provider fields at both levels.
        let encoded = try JSONEncoder.store.encode(claude)
        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "provider")
        if var limits = legacyObject["limits"] as? [[String: Any]] {
            for index in limits.indices { limits[index].removeValue(forKey: "provider") }
            legacyObject["limits"] = limits
        }
        let legacyURL = directory.appendingPathComponent("legacy-claude.json")
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: legacyURL)
        #expect(LastUsageCache.load(provider: .claude, url: legacyURL)?.provider == .claude)

        var state = ProviderUsageState(provider: .chatgpt)
        state.snapshot = chatGPT
        state.lastSuccessAt = .fixedNow
        state.connectionState = .connected
        #expect(state.hasCurrentData(now: .fixedNow.plus(minutes: 1), refreshInterval: 120))
        state.isShowingCachedData = true
        #expect(!state.hasCurrentData(now: .fixedNow.plus(minutes: 1), refreshInterval: 120))
    }

    @Test("existing history without provider decodes as Claude")
    func legacyHistoryDefaultsToClaude() throws {
        let data = Data(#"[{"t":"2026-08-08T17:30:00Z","limits":{"session":44}}]"#.utf8)
        let decoded = try JSONDecoder.store.decode([UsageSample].self, from: data)
        #expect(decoded.count == 1)
        #expect(decoded.first?.provider == .claude)
        #expect(decoded.first?.limits["session"] == 44)
    }

    @Test("same-time history and notification keys are provider-aware")
    func providerAwareHistoryAndNotifications() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(
            url: directory.appendingPathComponent("history.json"), minimumWriteInterval: 0
        )
        _ = store.append(
            UsageSample(t: .fixedNow, limits: ["session": 60], provider: .claude),
            retention: 86_400, now: .fixedNow
        )
        _ = store.append(
            UsageSample(t: .fixedNow, limits: ["session": 60], provider: .chatgpt),
            retention: 86_400, now: .fixedNow
        )
        #expect(store.load().count == 2)

        let reset = Date.fixedNow.plus(hours: 2)
        var ledger = NotificationLedger()
        let claude = NotificationPolicy.evaluate(
            providerContext(.claude, percent: 80, reset: reset), ledger: &ledger
        )
        let chatGPT = NotificationPolicy.evaluate(
            providerContext(.chatgpt, percent: 80, reset: reset), ledger: &ledger
        )
        #expect(claude.first?.title.contains("Claude") == true)
        #expect(chatGPT.first?.title.contains("ChatGPT") == true)
        #expect(ledger.firedKeys.contains { $0.hasPrefix("claude#session|") })
        #expect(ledger.firedKeys.contains { $0.hasPrefix("chatgpt#session|") })
    }

    @Test("tightest overall selection names the owning provider")
    func tightestOverall() {
        let selection = ProviderUsageSelection.tightest(snapshots: [
            .claude: providerSnapshot(.claude, percent: 81),
            .chatgpt: providerSnapshot(.chatgpt, percent: 93),
        ])
        #expect(selection?.provider == .chatgpt)
        #expect(selection?.limit.percent == 93)

        let claudeOnly = ProviderUsageSelection.tightest(
            snapshots: [
                .claude: providerSnapshot(.claude, percent: 81),
                .chatgpt: providerSnapshot(.chatgpt, percent: 93),
            ],
            availableProviders: [.claude]
        )
        #expect(claudeOnly?.provider == .claude)
    }

    @Test("ChatGPT dashboard and debug sanitization are safe")
    func dashboardAndSanitizer() throws {
        #expect(UsageProvider.chatgpt.dashboardURL.absoluteString == "https://chatgpt.com/codex/settings/usage")
        let raw = try JSONValue.parse(Data(#"""
        {
          "access_token": "invented-secret-token",
          "account_id": "invented-account-id",
          "email": "person@example.invalid",
          "display_name": "another-person@example.invalid",
          "prompt": "invented prompt text",
          "response": "invented response text",
          "session": {"id": "invented-session"},
          "used_percent": 42
        }
        """#.utf8))
        let output = DebugSanitizer.encoded(raw)
        #expect(!output.contains("invented-secret-token"))
        #expect(!output.contains("invented-account-id"))
        #expect(!output.contains("person@example.invalid"))
        #expect(!output.contains("another-person@example.invalid"))
        #expect(!output.contains("invented prompt text"))
        #expect(!output.contains("invented response text"))
        #expect(!output.contains("invented-session"))
        #expect(output.contains("42"))
    }
}

private actor StubChatGPTTransport: ChatGPTHTTPTransport {
    private let responseValue: ChatGPTHTTPResponse
    private var lastRequest: URLRequest?

    init(response: ChatGPTHTTPResponse) { self.responseValue = response }

    func send(_ request: URLRequest) async throws -> ChatGPTHTTPResponse {
        lastRequest = request
        return responseValue
    }

    func request() -> URLRequest? { lastRequest }
}

private func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("claude-usage-chatgpt-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeExecutable(_ contents: String, to url: URL) throws {
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

private func providerSnapshot(_ provider: UsageProvider, percent: Double) -> UsageSnapshot {
    UsageSnapshot(
        fetchedAt: .fixedNow,
        limits: [
            LimitWindow(
                id: "session", kind: "session", group: .session,
                title: "5-hour limit", shortTitle: "Session",
                percent: percent, resetsAt: Date.fixedNow.plus(hours: 2),
                severity: Severity.from(percent: percent), isActive: true,
                provider: provider, windowDuration: 18_000
            ),
        ],
        spend: nil,
        provider: provider
    )
}

private func providerContext(
    _ provider: UsageProvider, percent: Double, reset: Date
) -> PolicyContext {
    var settings = permissiveSettings
    settings.usageThresholds = [75]
    let snapshot = providerSnapshot(provider, percent: percent)
    let adjusted = UsageSnapshot(
        fetchedAt: snapshot.fetchedAt,
        limits: snapshot.limits.map {
            LimitWindow(
                id: $0.id, kind: $0.kind, group: $0.group,
                title: $0.title, shortTitle: $0.shortTitle,
                percent: $0.percent, resetsAt: reset, severity: $0.severity,
                isActive: $0.isActive, provider: provider, windowDuration: $0.windowDuration
            )
        },
        spend: nil,
        provider: provider
    )
    return PolicyContext(
        now: .fixedNow, settings: settings, snapshot: adjusted,
        provider: provider, apiHealthy: true
    )
}
