import Foundation

public struct GrokUsageResult: Sendable, Equatable {
    public let snapshot: UsageSnapshot
    public let planLabel: String?

    public init(snapshot: UsageSnapshot, planLabel: String?) {
        self.snapshot = snapshot
        self.planLabel = planLabel
    }
}

public protocol GrokUsageServiceProtocol: Sendable {
    func fetchUsage() async throws -> GrokUsageResult
    /// Whether a session cookie is already sitting in Keychain, without making a network call.
    func hasStoredSession() -> Bool
}

/// Cookie-authenticated orchestration for grok.com's billing RPC.
///
/// Like Cursor, Grok has no local CLI credential to read and no read-only API token for
/// consumer usage — its settings panel authenticates same-origin calls with the browser
/// session cookie. This type never starts a login itself; it only ever reads the cookie a
/// prior `GrokLoginSheet` session already stored in Keychain (via
/// `GrokSessionCookieStoreProtocol`) and sends it as a `Cookie:` header on an ephemeral,
/// cache-free `URLSession`. A rejected cookie means the session expired; a missing cookie
/// means the one-time login has never been completed.
///
/// The two calls do not speak the same protocol, which is a property of grok.com rather than
/// a choice made here: subscriptions is an ordinary JSON route, while the billing service is
/// reachable **only** over gRPC-Web. Its proto does declare `GET /rest/grok/credits`, but that
/// route is not mounted on the public edge — it answers `{"code":5,"message":"Not Found"}`
/// while the RPC path below answers for real. See `GrokWireFormat.swift`.
public final class GrokUsageService: GrokUsageServiceProtocol, @unchecked Sendable {
    /// `grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`, over gRPC-Web.
    public static let creditsURL = URL(
        string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"
    )!
    /// Plan label only, and ordinary JSON. Its failure is tolerated — usage is the point.
    public static let subscriptionsURL = URL(string: "https://grok.com/rest/subscriptions")!

    private let cookieStore: GrokSessionCookieStoreProtocol
    private let transport: GrokHTTPTransport
    private let now: @Sendable () -> Date

    public init(
        cookieStore: GrokSessionCookieStoreProtocol = GrokSessionCookieStore(),
        transport: GrokHTTPTransport = URLSessionGrokTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cookieStore = cookieStore
        self.transport = transport
        self.now = now
    }

    public func hasStoredSession() -> Bool {
        cookieStore.load() != nil
    }

    public func fetchUsage() async throws -> GrokUsageResult {
        guard let cookie = cookieStore.load() else {
            throw UsageAPIError.missingGrokSession
        }

        async let credits = fetchCredits(cookie: cookie)
        // The plan name is decoration; losing it must not cost the user their usage numbers,
        // so unlike the credits call this one is allowed to come back empty.
        async let subscriptions = optional(Self.subscriptionsURL, cookie: cookie)

        let creditsJSON = try await credits
        let subscriptionsJSON = await subscriptions

        let parsed = GrokUsageParser.parse(
            credits: creditsJSON,
            subscriptions: subscriptionsJSON,
            now: now()
        )
        guard !parsed.snapshot.limits.isEmpty else {
            throw UsageAPIError.unrecognizedSchema(
                parsed.snapshot.schemaWarnings.first ?? "No Grok usage windows in the response."
            )
        }
        return GrokUsageResult(snapshot: parsed.snapshot, planLabel: parsed.planLabel)
    }

    /// One gRPC-Web unary call. `GetGrokCreditsConfigRequest` has one optional field the app
    /// does not set, so the request message is empty and its frame is five zero bytes.
    private func fetchCredits(cookie: String) async throws -> JSONValue {
        var request = baseRequest(Self.creditsURL, cookie: cookie)
        request.httpMethod = "POST"
        request.httpBody = GrokGRPCWebFrames.frame(Data())
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")

        let response = try await transport.send(request)
        // gRPC signals failure in `grpc-status`, not in the HTTP status: a denied request
        // still arrives as HTTP 200. Checking the HTTP status first would read every auth
        // failure as a success and then fail confusingly at the decode step instead.
        if let error = Self.rpcError(headers: response.headers, body: response.data) {
            throw error
        }
        switch response.statusCode {
        case 200...299: break
        case 401: throw UsageAPIError.unauthorized
        case 403: throw UsageAPIError.forbidden
        case 429: throw UsageAPIError.rateLimited(retryAfter: retryAfter(response.headers))
        case 500...599: throw UsageAPIError.server(status: response.statusCode)
        default: throw UsageAPIError.http(status: response.statusCode)
        }

        let frames = GrokGRPCWebFrames.parse(response.data)
        guard let json = GrokCreditsMessage.decode(frames.message) else {
            throw UsageAPIError.unrecognizedSchema(
                "The Grok billing response could not be decoded."
            )
        }
        return json
    }

    /// The gRPC status, wherever it landed: in the response headers for a trailers-only
    /// response (what an auth failure produces), or in the body's trailer frame otherwise.
    private static func rpcError(headers: [String: String], body: Data) -> UsageAPIError? {
        let trailers = GrokGRPCWebFrames.parse(body).trailers
        let lowered = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a }
        )
        guard let raw = trailers["grpc-status"] ?? lowered["grpc-status"],
              let code = Int(raw.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return GrokRPCStatus.error(
            code: code, message: trailers["grpc-message"] ?? lowered["grpc-message"]
        )
    }

    private func optional(_ url: URL, cookie: String) async -> JSONValue? {
        try? await get(url, cookie: cookie)
    }

    private func get(_ url: URL, cookie: String) async throws -> JSONValue {
        var request = baseRequest(url, cookie: cookie)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.send(request)
        switch response.statusCode {
        case 200...299: break
        case 401: throw UsageAPIError.unauthorized
        case 403: throw UsageAPIError.forbidden
        case 429: throw UsageAPIError.rateLimited(retryAfter: retryAfter(response.headers))
        case 500...599: throw UsageAPIError.server(status: response.statusCode)
        default: throw UsageAPIError.http(status: response.statusCode)
        }

        guard let json = try? JSONValue.parse(response.data) else {
            throw UsageAPIError.invalidJSON
        }
        return json
    }

    private func baseRequest(_ url: URL, cookie: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(
            "ClaudeUsageTracker/2.1 (macOS; Grok settings)", forHTTPHeaderField: "User-Agent"
        )
        // Same-origin proof. `URLSession` never sends these on its own the way a browser
        // would, and grok.com's edge treats an origin-less call to these paths as suspicious.
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        return request
    }

    private func retryAfter(_ headers: [String: String]) -> TimeInterval? {
        headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }
            .flatMap { TimeInterval($0.value) }
    }
}

// MARK: - Transport

public struct GrokHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

public protocol GrokHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GrokHTTPResponse
}

/// No cache, no shared cookie storage: the request carries the session cookie explicitly as a
/// header, so `URLSession` is never allowed to also store or replay cookies of its own.
public final class URLSessionGrokTransport: GrokHTTPTransport, @unchecked Sendable {
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

    public func send(_ request: URLRequest) async throws -> GrokHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UsageAPIError.network("Malformed response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return GrokHTTPResponse(data: data, statusCode: http.statusCode, headers: headers)
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
