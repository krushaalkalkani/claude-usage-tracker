import Foundation
import Security

/// Where a token came from. Shown in Settings so it is always obvious which credential the
/// app is using — but the value itself is never displayed.
public enum TokenSource: String, Sendable, Equatable {
    case appKeychain
    case claudeCodeKeychain
    case legacyFile

    public var label: String {
        switch self {
        case .appKeychain: return "Keychain (this app)"
        case .claudeCodeKeychain: return "Claude Code credentials"
        case .legacyFile: return "~/.claude-usage-token"
        }
    }
}

public struct ResolvedToken: Sendable {
    public let value: String
    public let source: TokenSource
    /// Only known for Claude Code credentials, and only when non-zero there.
    public let expiresAt: Date?

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

/// Resolves and stores the OAuth token.
///
/// Order of preference:
///  1. A token the user pasted into this app, held in the login keychain.
///  2. Claude Code's own credentials — the same OAuth grant, already on this machine.
///  3. The legacy `~/.claude-usage-token` file, for compatibility with v1.
///
/// The value is never logged, never written to history, and never included in a debug export.
public final class TokenStore: @unchecked Sendable {
    public static let service = "com.krushal.claude-usage-tracker"
    public static let account = "oauth-token"
    private static let claudeCodeService = "Claude Code-credentials"

    private let legacyFileURL: URL
    private let lock = NSLock()
    /// Cached so a 30-second refresh does not re-prompt or re-read the keychain each time.
    private var cached: ResolvedToken?
    private var cachedAt: Date?
    private let cacheTTL: TimeInterval = 300

    public init(legacyFileURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude-usage-token")) {
        self.legacyFileURL = legacyFileURL
    }

    // MARK: Resolution

    /// - Parameter excluding: sources the server has already rejected this run. Resolution
    ///   walks past them to the next candidate.
    ///
    ///   This matters because "a credential exists" and "a credential works" are different
    ///   things: Claude Code rotates its stored access token, and the copy on disk can be
    ///   refused by the server while still advertising a future `expiresAt`. Without the
    ///   skip list the app locks onto that dead credential and re-sends it forever.
    public func resolve(
        forceRefresh: Bool = false,
        excluding: Set<TokenSource> = []
    ) -> ResolvedToken? {
        lock.lock()
        defer { lock.unlock() }

        // The cache holds a single resolution, so it can only answer the unfiltered question.
        if excluding.isEmpty, !forceRefresh, let cached, let cachedAt,
           Date().timeIntervalSince(cachedAt) < cacheTTL, !cached.isExpired {
            return cached
        }

        var resolved: ResolvedToken?
        for read in [readAppKeychain, readClaudeCodeKeychain, readLegacyFile] {
            if let candidate = read(), !excluding.contains(candidate.source) {
                resolved = candidate
                break
            }
        }

        if excluding.isEmpty {
            cached = resolved
            cachedAt = Date()
        }
        return resolved
    }

    public func invalidateCache() {
        lock.lock()
        cached = nil
        cachedAt = nil
        lock.unlock()
    }

    /// Which sources currently hold something usable — for the Settings screen. Returns
    /// sources only, never values.
    public func availableSources() -> [TokenSource] {
        var out: [TokenSource] = []
        if readAppKeychain() != nil { out.append(.appKeychain) }
        if readClaudeCodeKeychain() != nil { out.append(.claudeCodeKeychain) }
        if readLegacyFile() != nil { out.append(.legacyFile) }
        return out
    }

    // MARK: Writing

    @discardableResult
    public func save(token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        attributes[kSecAttrLabel as String] = "Claude Usage Tracker OAuth token"

        let status = SecItemAdd(attributes as CFDictionary, nil)
        invalidateCache()
        return status == errSecSuccess
    }

    @discardableResult
    public func deleteStoredToken() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        invalidateCache()
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: Sources

    private func readAppKeychain() -> ResolvedToken? {
        guard let value = keychainString(service: Self.service, account: Self.account) else {
            return nil
        }
        return ResolvedToken(value: value, source: .appKeychain, expiresAt: nil)
    }

    /// Reads Claude Code's stored OAuth grant. macOS prompts for keychain access the first
    /// time; that prompt is the user's consent point and is documented in the README.
    private func readClaudeCodeKeychain() -> ResolvedToken? {
        guard let raw = keychainString(service: Self.claudeCodeService, account: nil),
              let data = raw.data(using: .utf8),
              let json = try? JSONValue.parse(data),
              let oauth = json["claudeAiOauth"],
              let token = oauth["accessToken"]?.stringValue,
              !token.isEmpty
        else { return nil }

        // `expiresAt` is epoch milliseconds. It is 0 (i.e. unset) on some installs, which
        // means "unknown" — treating that as expired would break the app for those users.
        var expiry: Date?
        if let ms = oauth["expiresAt"]?.doubleValue, ms > 0 {
            expiry = Date(timeIntervalSince1970: ms / 1000)
        }
        return ResolvedToken(value: token, source: .claudeCodeKeychain, expiresAt: expiry)
    }

    private func readLegacyFile() -> ResolvedToken? {
        guard let contents = try? String(contentsOf: legacyFileURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ResolvedToken(value: trimmed, source: .legacyFile, expiresAt: nil)
    }

    private func keychainString(service: String, account: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
