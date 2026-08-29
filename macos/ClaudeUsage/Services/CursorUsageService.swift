import Foundation

public struct CursorUsageResult: Sendable, Equatable {
    public let snapshot: UsageSnapshot
    public let planLabel: String?

    public init(snapshot: UsageSnapshot, planLabel: String?) {
        self.snapshot = snapshot
        self.planLabel = planLabel
    }
}

public protocol CursorUsageServiceProtocol: Sendable {
    func fetchUsage() async throws -> CursorUsageResult
    /// Whether a session cookie is already sitting in Keychain, without making a network call.
    func hasStoredSession() -> Bool
}

/// Cookie-authenticated orchestration for Cursor's undocumented, internal
/// `cursor.com/api/dashboard/*` endpoints.
///
/// Unlike Claude and ChatGPT, Cursor has no local CLI credential to read and no bearer token —
/// its dashboard authenticates same-origin calls purely with the browser session cookie. This
/// type never starts a login itself; it only ever reads the cookie a prior `CursorLoginSheet`
/// session already stored in Keychain (via `CursorSessionCookieStoreProtocol`) and sends it as
/// a `Cookie:` header on an ephemeral, cache-free `URLSession` — the same isolation the
/// ChatGPT direct-fallback transport uses. A 401/403 here means the stored cookie was
/// rejected; a missing cookie means the one-time login has never been completed.
public final class CursorUsageService: CursorUsageServiceProtocol, @unchecked Sendable {
    public static let planInfoURL = URL(string: "https://cursor.com/api/dashboard/get-plan-info")!
    public static let currentPeriodUsageURL =
        URL(string: "https://cursor.com/api/dashboard/get-current-period-usage")!
    public static let sandUsageStatusURL =
        URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!

    private let cookieStore: CursorSessionCookieStoreProtocol
    private let transport: CursorHTTPTransport
    private let now: @Sendable () -> Date

    public init(
        cookieStore: CursorSessionCookieStoreProtocol = CursorSessionCookieStore(),
        transport: CursorHTTPTransport = URLSessionCursorTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cookieStore = cookieStore
        self.transport = transport
        self.now = now
    }

    public func hasStoredSession() -> Bool {
        cookieStore.load() != nil
    }

    public func fetchUsage() async throws -> CursorUsageResult {
        guard let cookie = cookieStore.load() else {
            throw UsageAPIError.missingCursorSession
        }

        async let planInfo = get(Self.planInfoURL, cookie: cookie)
        async let currentPeriod = get(Self.currentPeriodUsageURL, cookie: cookie)
        async let sandStatus = get(Self.sandUsageStatusURL, cookie: cookie)

        // If any one of the three comes back unauthorized the cookie is dead; that is the
        // most useful diagnosis even if another call happened to succeed first.
        let (planInfoJSON, currentPeriodJSON, sandStatusJSON) =
            try await (planInfo, currentPeriod, sandStatus)

        let parsed = CursorUsageParser.parse(
            planInfo: planInfoJSON,
            currentPeriodUsage: currentPeriodJSON,
            sandUsageStatus: sandStatusJSON,
            now: now()
        )
        guard !parsed.snapshot.limits.isEmpty else {
            throw UsageAPIError.unrecognizedSchema(
                parsed.snapshot.schemaWarnings.first ?? "No Cursor usage windows in the response."
            )
        }
        return CursorUsageResult(snapshot: parsed.snapshot, planLabel: parsed.planLabel)
    }

    private func get(_ url: URL, cookie: String) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(
            "ClaudeUsageTracker/2.1 (macOS; Cursor dashboard)", forHTTPHeaderField: "User-Agent"
        )
        // Cursor's dashboard API rejects state-changing (POST) requests with no same-origin
        // proof - `{"error":"Invalid origin for state-changing request"}` - the standard
        // Next.js Server Actions CSRF guard. `URLSession` never sends these on its own the way
        // a browser would, so they have to be set explicitly to match the dashboard's own origin.
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard/spending", forHTTPHeaderField: "Referer")

        let response = try await transport.send(request)
        switch response.statusCode {
        case 200...299: break
        case 401: throw UsageAPIError.unauthorized
        case 403: throw UsageAPIError.forbidden
        case 429:
            let retry = response.headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }
                .flatMap { TimeInterval($0.value) }
            throw UsageAPIError.rateLimited(retryAfter: retry)
        case 500...599: throw UsageAPIError.server(status: response.statusCode)
        default: throw UsageAPIError.http(status: response.statusCode)
        }

        guard let json = try? JSONValue.parse(response.data) else {
            throw UsageAPIError.invalidJSON
        }
        return json
    }
}

// MARK: - Transport

public struct CursorHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

public protocol CursorHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> CursorHTTPResponse
}

/// No cache, no shared cookie storage: the request carries the session cookie explicitly as a
/// header, so `URLSession` is never allowed to also store or replay cookies of its own.
public final class URLSessionCursorTransport: CursorHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> CursorHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UsageAPIError.network("Malformed response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return CursorHTTPResponse(data: data, statusCode: http.statusCode, headers: headers)
        } catch let error as UsageAPIError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed:
                throw UsageAPIError.offline
            case .timedOut: throw UsageAPIError.timedOut
            case .cancelled: throw CancellationError()
            default: throw UsageAPIError.network(error.localizedDescription)
            }
        }
    }
}
