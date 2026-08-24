import Darwin
import Foundation

public struct ChatGPTUsageResult: Sendable, Equatable {
    public let snapshot: UsageSnapshot
    public let planLabel: String?
    public let source: ProviderDataSource
    public let cliDetected: Bool

    public init(
        snapshot: UsageSnapshot,
        planLabel: String?,
        source: ProviderDataSource,
        cliDetected: Bool
    ) {
        self.snapshot = snapshot
        self.planLabel = planLabel
        self.source = source
        self.cliDetected = cliDetected
    }
}

public protocol ChatGPTUsageServiceProtocol: Sendable {
    func fetchUsage() async throws -> ChatGPTUsageResult
    func isCLIDetected() -> Bool
}

/// CLI-first orchestration. The direct endpoint is deliberately hidden behind
/// `ChatGPTDirectUsageClientProtocol` so an undocumented endpoint change cannot spread into
/// views, history, analytics, or notification code.
public final class ChatGPTUsageService: ChatGPTUsageServiceProtocol, @unchecked Sendable {
    private let locator: CodexCLILocator
    private let direct: ChatGPTDirectUsageClientProtocol
    private let now: @Sendable () -> Date

    public init(
        locator: CodexCLILocator = CodexCLILocator(),
        direct: ChatGPTDirectUsageClientProtocol = ChatGPTDirectUsageClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locator = locator
        self.direct = direct
        self.now = now
    }

    public func isCLIDetected() -> Bool { locator.locate() != nil }

    public func fetchUsage() async throws -> ChatGPTUsageResult {
        let executable = locator.locate()
        if let executable {
            do {
                let parsed = try await CodexAppServerClient(executableURL: executable)
                    .fetch(now: now())
                guard !parsed.snapshot.limits.isEmpty else {
                    throw CodexAppServerError.unrecognizedSchema
                }
                return ChatGPTUsageResult(
                    snapshot: parsed.snapshot,
                    planLabel: parsed.planLabel,
                    source: .codexCLI,
                    cliDetected: true
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CodexAppServerError {
                if Task.isCancelled { throw CancellationError() }
                guard error.allowsDirectFallback else { throw error.usageError }
                do {
                    try Task.checkCancellation()
                    let parsed = try await direct.fetch(now: now())
                    return ChatGPTUsageResult(
                        snapshot: parsed.snapshot,
                        planLabel: parsed.planLabel,
                        source: .localCodexOAuth,
                        cliDetected: true
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let fallback as UsageAPIError {
                    // An installed but old CLI is still the most actionable diagnosis when
                    // its read method is absent and no valid read-only fallback is available.
                    if error == .unsupported, fallback == .missingToken {
                        throw UsageAPIError.unsupportedCLI
                    }
                    throw fallback
                }
            }
        }

        do {
            let parsed = try await direct.fetch(now: now())
            return ChatGPTUsageResult(
                snapshot: parsed.snapshot,
                planLabel: parsed.planLabel,
                source: .localCodexOAuth,
                cliDetected: false
            )
        } catch let error as UsageAPIError {
            if error == .missingToken { throw UsageAPIError.cliNotFound }
            throw error
        }
    }
}

// MARK: - CLI discovery

public struct CodexCLILocator: Sendable {
    private let environment: [String: String]
    private let homeDirectory: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    public func locate() -> URL? {
        var candidates: [URL] = []
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex")
            }
        }
        candidates += [
            homeDirectory.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        ]

        var seen = Set<String>()
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath()
            guard seen.insert(resolved.path).inserted,
                  FileManager.default.isExecutableFile(atPath: resolved.path)
            else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }
            return resolved
        }
        return nil
    }
}

// MARK: - Codex app-server JSON-RPC

public enum CodexAppServerError: Error, Sendable, Equatable {
    case launchFailed
    case timedOut
    case connectionClosed
    case unsupported
    case authenticationRequired
    case unrecognizedSchema
    case rpcFailure

    var allowsDirectFallback: Bool {
        switch self {
        case .launchFailed, .connectionClosed, .unsupported, .unrecognizedSchema: return true
        case .timedOut, .authenticationRequired, .rpcFailure: return false
        }
    }

    var usageError: UsageAPIError {
        switch self {
        case .launchFailed, .connectionClosed, .rpcFailure: return .cliUnavailable
        case .timedOut: return .cliTimedOut
        case .unsupported: return .unsupportedCLI
        case .authenticationRequired: return .codexAuthenticationRequired
        case .unrecognizedSchema:
            return .unrecognizedSchema("Codex CLI returned no readable usage windows.")
        }
    }
}

public final class CodexAppServerClient: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let initializationTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let terminationGrace: TimeInterval

    public init(
        executableURL: URL,
        arguments: [String] = ["-s", "read-only", "-a", "never", "app-server", "--stdio"],
        initializationTimeout: TimeInterval = 8,
        requestTimeout: TimeInterval = 5,
        terminationGrace: TimeInterval = 0.25
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.initializationTimeout = initializationTimeout
        self.requestTimeout = requestTimeout
        self.terminationGrace = terminationGrace
    }

    public func fetch(now: Date) async throws -> ChatGPTParseResult {
        let lifecycle = ProcessLifecycle(grace: terminationGrace)
        do {
            let result = try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) { [self] in
                    try lifecycle.run(
                        executableURL: executableURL,
                        arguments: arguments,
                        initializationTimeout: initializationTimeout,
                        requestTimeout: requestTimeout,
                        now: now
                    )
                }.value
            } onCancel: {
                lifecycle.requestStop()
            }
            try Task.checkCancellation()
            return result
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

private final class ProcessLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private let grace: TimeInterval

    init(grace: TimeInterval) { self.grace = grace }

    func run(
        executableURL: URL,
        arguments: [String],
        initializationTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        now: Date
    ) throws -> ChatGPTParseResult {
        if Task.isCancelled { throw CancellationError() }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        // Never retain or display app-server diagnostics; they may embed upstream details.
        process.standardError = FileHandle.nullDevice

        lock.lock()
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        lock.unlock()

        do {
            try process.run()
        } catch {
            clearProcess()
            throw CodexAppServerError.launchFailed
        }
        defer { stopAndWait() }

        let reader = BoundedLineReader(fileDescriptor: outputPipe.fileHandleForReading.fileDescriptor)
        try send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "claude_usage_tracker",
                    "title": "Claude Usage Tracker",
                    "version": "2.1.0",
                ],
                "capabilities": [
                    "optOutNotificationMethods": [
                        "thread/started", "item/started", "item/completed",
                        "item/agentMessage/delta",
                    ],
                ],
            ],
        ])
        _ = try response(id: 1, reader: reader, timeout: initializationTimeout)
        try send(["method": "initialized", "params": [:]])

        try send([
            "id": 2,
            "method": "account/read",
            "params": ["refreshToken": false],
        ])
        let accountResponse = try response(id: 2, reader: reader, timeout: requestTimeout)
        guard let account = accountResponse["result"]?["account"],
              account["type"]?.stringValue == "chatgpt"
        else { throw CodexAppServerError.authenticationRequired }
        // Email is intentionally never read from the response.
        let plan = account["planType"]?.stringValue

        try send(["id": 3, "method": "account/rateLimits/read"])
        let rateResponse = try response(id: 3, reader: reader, timeout: requestTimeout)
        guard let result = rateResponse["result"] else {
            throw CodexAppServerError.unrecognizedSchema
        }
        return ChatGPTUsageParser.parseAppServer(result, accountPlan: plan, now: now)
    }

    private func send(_ object: [String: Any]) throws {
        if Task.isCancelled { throw CancellationError() }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexAppServerError.rpcFailure
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        lock.lock()
        let input = self.input
        lock.unlock()
        guard let input else { throw CodexAppServerError.connectionClosed }
        do {
            try input.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.connectionClosed
        }
    }

    private func response(
        id: Int,
        reader: BoundedLineReader,
        timeout: TimeInterval
    ) throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if Task.isCancelled { throw CancellationError() }
            let line = try reader.nextLine(deadline: deadline)
            guard let message = try? JSONValue.parse(line), message["id"]?.intValue == id else {
                continue
            }
            if let error = message["error"] {
                let code = error["code"]?.intValue
                if code == -32601 { throw CodexAppServerError.unsupported }
                throw CodexAppServerError.rpcFailure
            }
            return message
        }
    }

    func requestStop() {
        lock.lock()
        let process = self.process
        let input = self.input
        self.input = nil
        lock.unlock()

        try? input?.close()
        guard let process, process.isRunning else { return }
        process.terminate()
        let grace = self.grace
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func stopAndWait() {
        requestStop()
        lock.lock()
        let process = self.process
        lock.unlock()
        guard let process else { return }

        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        clearProcess()
    }

    private func clearProcess() {
        lock.lock()
        process = nil
        input = nil
        lock.unlock()
    }
}

private final class BoundedLineReader {
    private let fileDescriptor: Int32
    private var buffer = Data()

    init(fileDescriptor: Int32) { self.fileDescriptor = fileDescriptor }

    func nextLine(deadline: Date) throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                return Data(line)
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexAppServerError.timedOut }
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min(max(remaining * 1000, 1), Double(Int32.max)))
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result == 0 { throw CodexAppServerError.timedOut }
            if result < 0 {
                if errno == EINTR { continue }
                throw CodexAppServerError.connectionClosed
            }

            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(fileDescriptor, raw.baseAddress, raw.count)
            }
            guard count > 0 else { throw CodexAppServerError.connectionClosed }
            buffer.append(contentsOf: bytes.prefix(count))
            // A single JSON-RPC response is tiny. Bound memory if a broken executable emits
            // unframed data forever.
            guard buffer.count <= 1_048_576 else { throw CodexAppServerError.unrecognizedSchema }
        }
    }
}

// MARK: - Read-only auth.json fallback

public struct CodexOAuthCredentials: Sendable {
    public let accessToken: String
    public let accountID: String?
}

public struct CodexOAuthCredentialsStore: Sendable {
    private let environment: [String: String]
    private let homeDirectory: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    public func load() throws -> CodexOAuthCredentials {
        let authURL: URL
        if let explicit = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            authURL = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("auth.json")
        } else {
            authURL = homeDirectory.appendingPathComponent(".codex/auth.json")
        }

        guard authURL.isFileURL, isRegularFileWithoutSymlink(authURL),
              let attributes = try? FileManager.default.attributesOfItem(atPath: authURL.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
              let data = try? Data(contentsOf: authURL),
              let root = try? JSONValue.parse(data)
        else { throw UsageAPIError.missingToken }

        let tokens = root["tokens"]
        let access = tokens?["access_token"]?.stringValue
            ?? tokens?["accessToken"]?.stringValue
            ?? root["access_token"]?.stringValue
            ?? root["accessToken"]?.stringValue
        guard let access, !access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageAPIError.missingToken
        }
        let accountID = tokens?["account_id"]?.stringValue
            ?? tokens?["accountId"]?.stringValue
            ?? root["account_id"]?.stringValue
            ?? root["accountId"]?.stringValue
        return CodexOAuthCredentials(accessToken: access, accountID: accountID)
    }

    private func isRegularFileWithoutSymlink(_ url: URL) -> Bool {
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }
}

public struct ChatGPTHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

public protocol ChatGPTHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ChatGPTHTTPResponse
}

public final class URLSessionChatGPTTransport: ChatGPTHTTPTransport, @unchecked Sendable {
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

    public func send(_ request: URLRequest) async throws -> ChatGPTHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UsageAPIError.network("Malformed response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return ChatGPTHTTPResponse(data: data, statusCode: http.statusCode, headers: headers)
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

public protocol ChatGPTDirectUsageClientProtocol: Sendable {
    func fetch(now: Date) async throws -> ChatGPTParseResult
}

public final class ChatGPTDirectUsageClient: ChatGPTDirectUsageClientProtocol, @unchecked Sendable {
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let credentials: CodexOAuthCredentialsStore
    private let transport: ChatGPTHTTPTransport
    private let endpoint: URL

    public init(
        credentials: CodexOAuthCredentialsStore = CodexOAuthCredentialsStore(),
        transport: ChatGPTHTTPTransport = URLSessionChatGPTTransport(),
        endpoint: URL = usageURL
    ) {
        self.credentials = credentials
        self.transport = transport
        self.endpoint = endpoint
    }

    public func fetch(now: Date) async throws -> ChatGPTParseResult {
        let credential = try credentials.load()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credential.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "ClaudeUsageTracker/2.1 (macOS; ChatGPT Codex allowance)",
            forHTTPHeaderField: "User-Agent"
        )

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

        guard let root = try? JSONValue.parse(response.data) else {
            throw UsageAPIError.invalidJSON
        }
        let parsed = ChatGPTUsageParser.parseDirect(root, now: now)
        guard !parsed.snapshot.limits.isEmpty else {
            throw UsageAPIError.unrecognizedSchema(
                parsed.snapshot.schemaWarnings.first ?? "No ChatGPT usage windows in the response."
            )
        }
        return parsed
    }
}
