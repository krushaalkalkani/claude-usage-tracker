import Foundation

/// Everything that can go wrong talking to the usage endpoint, as a closed set so the UI can
/// render a specific message for each rather than a generic failure.
public enum UsageAPIError: Error, Equatable, Sendable {
    case missingToken
    case unauthorized
    case forbidden
    /// `retryAfter` comes from the `Retry-After` header when present.
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case http(status: Int)
    case offline
    case timedOut
    case network(String)
    case invalidJSON
    /// The JSON parsed, but nothing recognizable as usage data was in it.
    case unrecognizedSchema(String)
    case cliNotFound
    case codexAuthenticationRequired
    case cliTimedOut
    case cliUnavailable
    case unsupportedCLI

    public var isTransient: Bool {
        switch self {
        case .rateLimited, .server, .offline, .timedOut, .network, .cliTimedOut, .cliUnavailable:
            return true
        default: return false
        }
    }

    public var title: String {
        title(for: .claude)
    }

    public func title(for provider: UsageProvider) -> String {
        switch self {
        case .missingToken:
            return provider == .chatgpt ? "Codex login required" : "Not connected"
        case .unauthorized:
            return provider == .chatgpt ? "Codex login needs refresh" : "Authentication expired"
        case .forbidden: return "Access denied"
        case .rateLimited: return "Rate limited"
        case .server:
            return provider == .chatgpt ? "ChatGPT usage is unavailable" : "Anthropic is having trouble"
        case .http: return "Unexpected response"
        case .offline: return "Offline"
        case .timedOut: return "Request timed out"
        case .network: return "Network error"
        case .invalidJSON: return "Unreadable response"
        case .unrecognizedSchema: return "Usage format not recognized"
        case .cliNotFound: return "Codex CLI not found"
        case .codexAuthenticationRequired: return "Codex login required"
        case .cliTimedOut: return "Codex CLI timed out"
        case .cliUnavailable: return "Codex CLI unavailable"
        case .unsupportedCLI: return "Codex CLI update needed"
        }
    }

    public var detail: String {
        detail(for: .claude)
    }

    public func detail(for provider: UsageProvider) -> String {
        switch self {
        case .missingToken:
            return provider == .chatgpt
                ? "Open Codex or run codex login, then refresh."
                : "Add an OAuth token in Settings, or sign in to Claude Code."
        case .unauthorized:
            return provider == .chatgpt
                ? "Open Codex or run codex login to refresh its credentials."
                : "The token was rejected. Reconnect in Settings."
        case .forbidden:
            return provider == .chatgpt
                ? "Open Codex or run codex login to refresh its credentials."
                : "This token is not allowed to read usage."
        case .rateLimited(let after):
            if let after { return "Retrying in \(Int(after.rounded()))s." }
            return "Backing off before the next attempt."
        case .server(let status):
            return "Server returned \(status). Retrying with backoff."
        case .http(let status):
            return "HTTP \(status)."
        case .offline:
            return "No network connection."
        case .timedOut:
            return "The request took too long."
        case .network(let message):
            return message
        case .invalidJSON:
            return "The response was not valid JSON."
        case .unrecognizedSchema(let note):
            return note
        case .cliNotFound:
            return "Install the Codex CLI and sign in. No interactive login was started."
        case .codexAuthenticationRequired:
            return "Open Codex or run codex login, then refresh."
        case .cliTimedOut:
            return "The read-only Codex app-server did not respond in time."
        case .cliUnavailable:
            return "The read-only Codex app-server could not return usage."
        case .unsupportedCLI:
            return "This Codex version does not expose account rate limits. Update Codex and refresh."
        }
    }
}

public protocol UsageAPIClientProtocol: Sendable {
    func fetchUsage(token: String) async throws -> UsageSnapshot
    func fetchProfile(token: String) async throws -> AccountProfile
}

/// The only component that talks to the network.
///
/// Isolated on purpose: if Anthropic changes or removes this internal endpoint, this file and
/// `UsageParser` are the only places that need to change.
public final class UsageAPIClient: UsageAPIClientProtocol, @unchecked Sendable {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    /// The beta header the OAuth surface requires.
    public static let betaHeader = "oauth-2025-04-20"

    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        // Ephemeral: no on-disk cache, no cookie jar. A usage response should never be
        // written to disk by URLSession behind our back.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [:]
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: config)
        self.now = now
    }

    public func fetchUsage(token: String) async throws -> UsageSnapshot {
        let json = try await get(Self.usageURL, token: token)
        let snapshot = UsageParser.parse(json, now: now())
        guard snapshot.hasAnyData else {
            throw UsageAPIError.unrecognizedSchema(
                snapshot.schemaWarnings.first ?? "No usage limits in the response."
            )
        }
        return snapshot
    }

    public func fetchProfile(token: String) async throws -> AccountProfile {
        let json = try await get(Self.profileURL, token: token)
        return ProfileParser.parse(json)
    }

    private func get(_ url: URL, token: String) async throws -> JSONValue {
        guard !token.isEmpty else { throw UsageAPIError.missingToken }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClaudeUsageTracker/2.0 (macOS menu bar)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed:
                throw UsageAPIError.offline
            case .timedOut:
                throw UsageAPIError.timedOut
            case .cancelled:
                throw CancellationError()
            default:
                // `localizedDescription` of a URLError never contains the request headers.
                throw UsageAPIError.network(error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError.network("Malformed response")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401:
            throw UsageAPIError.unauthorized
        case 403:
            throw UsageAPIError.forbidden
        case 429:
            throw UsageAPIError.rateLimited(retryAfter: retryAfter(from: http))
        case 500...599:
            throw UsageAPIError.server(status: http.statusCode)
        default:
            throw UsageAPIError.http(status: http.statusCode)
        }

        do {
            return try JSONValue.parse(data)
        } catch {
            throw UsageAPIError.invalidJSON
        }
    }

    private func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) {
            return max(0, seconds)
        }
        // The header may also be an HTTP date.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = f.date(from: raw) {
            return max(0, date.timeIntervalSince(now()))
        }
        return nil
    }
}

/// Exponential backoff with jitter, used after a failed poll.
public struct BackoffPolicy: Sendable {
    public let base: TimeInterval
    public let maximum: TimeInterval
    public let jitterFraction: Double

    public init(base: TimeInterval = 30, maximum: TimeInterval = 300, jitterFraction: Double = 0.2) {
        self.base = base
        self.maximum = maximum
        self.jitterFraction = jitterFraction
    }

    /// Delay before attempt number `failureCount` (1 = first retry).
    /// `randomUnit` is injectable so tests are deterministic.
    public func delay(
        failureCount: Int,
        retryAfter: TimeInterval? = nil,
        randomUnit: Double = Double.random(in: 0...1)
    ) -> TimeInterval {
        // A server-specified Retry-After always wins.
        if let retryAfter { return min(max(retryAfter, 1), maximum) }
        guard failureCount > 0 else { return base }
        let exponential = base * pow(2, Double(min(failureCount - 1, 8)))
        let capped = min(exponential, maximum)
        let jitter = capped * jitterFraction * (randomUnit * 2 - 1)
        return max(1, capped + jitter)
    }
}
