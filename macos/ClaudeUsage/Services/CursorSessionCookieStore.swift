import Foundation
import Security

/// Reads and writes the Cursor `cursor.com` session cookie, obtained via a one-time embedded
/// `WKWebView` login the user completes themselves (see `CursorLoginSheet` in the app target).
///
/// This mirrors `TokenStore`'s Keychain pattern, but is kept as its own type because a Cursor
/// session is a full `Cookie:` header value rather than a bearer token, and because it has a
/// different, single source — there is no CLI or multi-source resolution chain to walk here.
/// The value is never logged, never written to `last-usage-cursor.json`, and never included in
/// a debug export.
public protocol CursorSessionCookieStoreProtocol: Sendable {
    /// The stored `Cookie:` header value, or `nil` if nothing has been saved yet.
    func load() -> String?
    @discardableResult
    func save(cookie: String) -> Bool
    @discardableResult
    func clear() -> Bool
}

public final class CursorSessionCookieStore: CursorSessionCookieStoreProtocol, @unchecked Sendable {
    // Same keychain service as `TokenStore`, distinguished by account — one login-keychain
    // item per app, not one item per credential type.
    public static let service = TokenStore.service
    public static let account = "cursor-session-cookie"

    public init() {}

    public func load() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        query.removeValue(forKey: kSecReturnData as String)
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
        attributes[kSecAttrLabel as String] = "Claude Usage Tracker Cursor session"

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
