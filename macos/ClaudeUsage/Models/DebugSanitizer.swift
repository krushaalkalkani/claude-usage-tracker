import Foundation

/// Central redaction used by copied debug reports. It is intentionally conservative: losing
/// a diagnostic field is preferable to exposing credentials, identity, or session content.
public enum DebugSanitizer {
    public static func scrub(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let dictionary):
            var output: [String: JSONValue] = [:]
            var hiddenKeyIndex = 0
            for key in dictionary.keys.sorted() {
                guard let child = dictionary[key] else { continue }
                let outputKey: String
                if looksLikeIdentifier(key) {
                    hiddenKeyIndex += 1
                    outputKey = "<redacted-key-\(hiddenKeyIndex)>"
                } else {
                    outputKey = key
                }
                output[outputKey] = shouldRedact(key) ? .string("<redacted>") : scrub(child)
            }
            return .object(output)
        case .array(let items):
            return .array(items.map(scrub))
        case .string(let string):
            return looksLikeSensitiveValue(string) ? .string("<redacted>") : value
        default:
            return value
        }
    }

    public static func encoded(_ value: JSONValue?) -> String {
        guard let value else { return "(not retained)" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(scrub(value)),
              let text = String(data: data, encoding: .utf8)
        else { return "(could not encode)" }
        return text
    }

    private static func shouldRedact(_ key: String) -> Bool {
        let lower = key.lowercased()
        let exact: Set<String> = [
            "id", "account", "accountid", "account_id", "user", "user_id",
            "authorization", "cookie", "prompt", "response", "session",
        ]
        if exact.contains(lower) { return true }
        return lower.contains("token")
            || lower.contains("secret")
            || lower.contains("password")
            || lower.contains("email")
            || lower.contains("uuid")
            || lower.contains("organization")
            || lower.contains("workspace")
            || lower.contains("conversation")
            || lower.contains("message")
            || lower.contains("prompt")
            || lower.hasSuffix("_account_id")
            || lower.hasSuffix("_user_id")
    }

    private static func looksLikeIdentifier(_ key: String) -> Bool {
        let lower = key.lowercased()
        if lower.contains("@") || lower.hasPrefix("acct_") || lower.hasPrefix("account_")
            || lower.hasPrefix("org_") || lower.hasPrefix("user_") {
            return true
        }
        let compact = lower.filter { $0.isLetter || $0.isNumber }
        // UUIDs and long opaque map keys should not survive as JSON object keys.
        return (key.filter { $0 == "-" }.count == 4 && compact.count == 32)
            || (compact.count >= 40 && compact.count == key.count)
    }

    private static func looksLikeSensitiveValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if trimmed.contains("@") || trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")
            || lower.hasPrefix("acct_") || lower.hasPrefix("account_")
            || lower.hasPrefix("org_") || lower.hasPrefix("user_") {
            return true
        }
        if UUID(uuidString: trimmed) != nil { return true }
        let dotParts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if dotParts.count == 3, trimmed.count >= 40 { return true }
        let compact = trimmed.filter { $0.isLetter || $0.isNumber }
        return compact.count >= 40 && compact.count == trimmed.count
    }
}
