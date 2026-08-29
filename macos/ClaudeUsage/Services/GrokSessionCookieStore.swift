import Foundation
import Security

/// Reads and writes the `grok.com` session cookie, obtained via a one-time embedded
/// `WKWebView` login the user completes themselves (see `GrokLoginSheet` in the app target).
///
/// A near-twin of `CursorSessionCookieStore`, and kept separate on purpose: the two are
/// independent credentials for independent accounts, and a shared type would mean one
/// provider's "Remove stored session" could plausibly reach the other's item. Same keychain
/// service as `TokenStore`, distinguished by account.
///
/// The value is never logged, never written to `last-usage-grok.json`, and never included in
/// a debug export.
public protocol GrokSessionCookieStoreProtocol: Sendable {
    /// The stored `Cookie:` header value, or `nil` if nothing has been saved yet.
    func load() -> String?
    @discardableResult
    func save(cookie: String) -> Bool
    @discardableResult
    func clear() -> Bool
}

public final class GrokSessionCookieStore: GrokSessionCookieStoreProtocol, @unchecked Sendable {
    public static let service = TokenStore.service
    public static let account = "grok-session-cookie"

    public init() {}

    public func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    public func save(cookie: String) -> Bool {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
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
        attributes[kSecAttrLabel as String] = "Claude Usage Tracker Grok session"

        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
