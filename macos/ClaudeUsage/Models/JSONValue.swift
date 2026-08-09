import Foundation

/// A total representation of any JSON document.
///
/// The usage endpoint is an internal Anthropic API that can change shape without notice, so
/// nothing in this app decodes it into a rigid `Codable` struct. We decode into `JSONValue`
/// — which cannot fail on an unexpected shape — and then *read* fields with optional
/// accessors. A removed field becomes `nil`; an added field is preserved untouched.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Decoding

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer() {
            if c.decodeNil() {
                self = .null
                return
            }
            // Bool must be tried before Double: JSONDecoder will happily turn `true` into 1.
            if let b = try? c.decode(Bool.self) {
                self = .bool(b)
                return
            }
            if let d = try? c.decode(Double.self) {
                self = .number(d)
                return
            }
            if let s = try? c.decode(String.self) {
                self = .string(s)
                return
            }
            if let a = try? c.decode([JSONValue].self) {
                self = .array(a)
                return
            }
            if let o = try? c.decode([String: JSONValue].self) {
                self = .object(o)
                return
            }
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unrepresentable JSON value")
        )
    }

    /// Parses raw response bytes. Throws only when the bytes are not valid JSON at all.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - Accessors

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        // An explicit JSON `null` reads the same as an absent key. Callers never care which.
        guard let v = o[key], v != .null else { return nil }
        return v
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }

    public var stringValue: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        // Some fields have flipped between string and number across API revisions.
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var intValue: Int? {
        guard let d = doubleValue, d.isFinite else { return nil }
        return Int(d.rounded())
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let a) = self else { return nil }
        return a
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let o) = self else { return nil }
        return o
    }

    /// Parses an ISO 8601 timestamp, with or without fractional seconds.
    public var dateValue: Date? {
        guard let s = stringValue else { return nil }
        return ISO8601.parse(s)
    }

    public var isNull: Bool { self == .null }
}

// MARK: - Encoding (debug export only)

extension JSONValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - ISO 8601

public enum ISO8601 {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()

    public static func parse(_ s: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }

    public static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return plain.string(from: date)
    }
}

extension Date {
    /// Drops sub-second precision.
    ///
    /// The usage endpoint stamps `resets_at` with fractional seconds that differ on *every*
    /// response for the same window — `20:00:00.196578`, then `20:00:00.275325`. Anything
    /// that compares or keys on the raw value therefore sees a brand-new window on every
    /// poll. Truncating at the parse boundary keeps that jitter out of reset detection,
    /// notification dedup keys, and persisted state.
    public var truncatingSubsecond: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}
