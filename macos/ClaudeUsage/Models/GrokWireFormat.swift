import Foundation

/// The bare minimum of protobuf and gRPC-Web needed to read one message from grok.com.
///
/// ## Why this exists
///
/// Every other provider in this app answers with JSON. Grok's billing service does not: the
/// `GrokBuildBilling` proto carries `google.api.http` annotations mapping each RPC to a
/// `/rest/grok/*` route, but those routes are **not mounted on the public edge** — they answer
/// `{"code":5,"message":"Not Found"}` — while the RPC path answers for real. The web app talks
/// to it over gRPC-Web, and so must this.
///
/// Rather than take a protobuf dependency for a single message, this decodes the handful of
/// fields the app reads and re-emits them as `JSONValue` in exactly the shape protobuf's own
/// JSON mapping would produce. `GrokUsageParser` is then encoding-agnostic: it never learns
/// that this provider speaks a different wire format, and if xAI ever does expose the REST
/// route the parser keeps working unchanged.
///
/// Field numbers come from the service's own descriptors, shipped in grok.com's JS bundle.
enum ProtobufReader {
    /// One field as it appeared on the wire. Field numbers repeat for `repeated` fields.
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }

    /// Splits a message into its fields. Returns `nil` on malformed input rather than
    /// throwing, so a schema surprise degrades to "no usage found" like every other parser
    /// here rather than to a crash.
    static func fields(_ data: Data) -> [(number: Int, value: Value)]? {
        var out: [(number: Int, value: Value)] = []
        var index = data.startIndex

        while index < data.endIndex {
            guard let (key, afterKey) = varint(data, from: index) else { return nil }
            let number = Int(key >> 3)
            let wireType = Int(key & 0x07)
            guard number > 0 else { return nil }
            index = afterKey

            switch wireType {
            case 0:
                guard let (value, next) = varint(data, from: index) else { return nil }
                out.append((number, .varint(value)))
                index = next
            case 1:
                guard let (value, next) = fixedWidth(data, from: index, bytes: 8) else { return nil }
                out.append((number, .fixed64(value)))
                index = next
            case 2:
                guard let (length, afterLength) = varint(data, from: index),
                      length <= UInt64(data.endIndex - afterLength)
                else { return nil }
                let end = afterLength + Int(length)
                out.append((number, .bytes(data[afterLength..<end])))
                index = end
            case 5:
                guard let (value, next) = fixedWidth(data, from: index, bytes: 4) else { return nil }
                out.append((number, .fixed32(UInt32(truncatingIfNeeded: value))))
                index = next
            default:
                // Groups (3, 4) are deprecated and appear in none of these messages.
                return nil
            }
        }
        return out
    }

    private static func varint(_ data: Data, from start: Data.Index) -> (UInt64, Data.Index)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < data.endIndex {
            let byte = data[index]
            index += 1
            // A varint is at most 10 bytes; anything longer is corrupt.
            guard shift <= 63 else { return nil }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, index) }
            shift += 7
        }
        return nil
    }

    private static func fixedWidth(
        _ data: Data, from start: Data.Index, bytes count: Int
    ) -> (UInt64, Data.Index)? {
        guard data.endIndex - start >= count else { return nil }
        var result: UInt64 = 0
        for offset in 0..<count {
            result |= UInt64(data[start + offset]) << (8 * UInt64(offset))
        }
        return (result, start + count)
    }
}

extension Array where Element == (number: Int, value: ProtobufReader.Value) {
    func first(_ number: Int) -> ProtobufReader.Value? {
        first { $0.number == number }?.value
    }

    func all(_ number: Int) -> [ProtobufReader.Value] {
        filter { $0.number == number }.map(\.value)
    }
}

extension ProtobufReader.Value {
    var messageFields: [(number: Int, value: ProtobufReader.Value)]? {
        guard case .bytes(let data) = self else { return nil }
        return ProtobufReader.fields(data)
    }

    /// `float`, which protobuf encodes as a little-endian 32-bit IEEE 754 value.
    var floatValue: Double? {
        guard case .fixed32(let bits) = self else { return nil }
        let value = Float(bitPattern: bits)
        return value.isFinite ? Double(value) : nil
    }

    /// `int64` / `int32` / `bool` / `enum` — all plain varints in this schema.
    var intValue: Int64? {
        guard case .varint(let bits) = self else { return nil }
        return Int64(bitPattern: bits)
    }
}

/// Decodes `grok_api_v2.GetGrokCreditsConfigResponse` into the JSON shape protobuf's own
/// JSON mapping defines, so `GrokUsageParser` can read it without knowing the difference.
///
/// Only the fields the app actually renders are decoded; anything else is skipped, which is
/// also why a new field appearing upstream cannot break this.
public enum GrokCreditsMessage {
    /// ```proto
    /// message GetGrokCreditsConfigResponse { GrokCreditsConfig config = 1; }
    /// message GrokCreditsConfig {
    ///   float             credit_usage_percent   = 1;
    ///   prod_charger.Cent on_demand_cap          = 2;   // Cent { int64 val = 1; }
    ///   prod_charger.Cent on_demand_used         = 3;
    ///   Timestamp         billing_period_start   = 4;
    ///   Timestamp         billing_period_end     = 5;
    ///   repeated ProductUsage product_usage      = 7;
    ///   UsagePeriod       current_period         = 8;
    ///   prod_charger.Cent prepaid_balance        = 12;
    /// }
    /// ```
    public static func decode(_ data: Data) -> JSONValue? {
        guard let response = ProtobufReader.fields(data),
              let config = response.first(1)?.messageFields
        else { return nil }

        var object: [String: JSONValue] = [:]
        if let percent = config.first(1)?.floatValue {
            object["creditUsagePercent"] = .number(percent)
        }
        if let cents = cent(config.first(2)) { object["onDemandCap"] = cents }
        if let cents = cent(config.first(3)) { object["onDemandUsed"] = cents }
        if let cents = cent(config.first(12)) { object["prepaidBalance"] = cents }
        if let time = timestamp(config.first(4)) { object["billingPeriodStart"] = time }
        if let time = timestamp(config.first(5)) { object["billingPeriodEnd"] = time }
        if let period = usagePeriod(config.first(8)) { object["currentPeriod"] = period }

        let products = config.all(7).compactMap(productUsage)
        if !products.isEmpty { object["productUsage"] = .array(products) }

        // An empty config is still a valid response — the parser turns it into a schema
        // warning, which is more useful than a decode failure.
        return .object(["config": .object(object)])
    }

    /// `message Cent { int64 val = 1; }`
    private static func cent(_ value: ProtobufReader.Value?) -> JSONValue? {
        guard let fields = value?.messageFields else { return nil }
        // A zero `val` is omitted by proto3, and zero cents is a meaningful answer, so an
        // empty Cent message decodes as 0 rather than as absent.
        return .object(["val": .number(Double(fields.first(1)?.intValue ?? 0))])
    }

    /// `google.protobuf.Timestamp { int64 seconds = 1; int32 nanos = 2; }`
    private static func timestamp(_ value: ProtobufReader.Value?) -> JSONValue? {
        guard let fields = value?.messageFields else { return nil }
        guard let seconds = fields.first(1)?.intValue else { return nil }
        var object: [String: JSONValue] = ["seconds": .number(Double(seconds))]
        if let nanos = fields.first(2)?.intValue { object["nanos"] = .number(Double(nanos)) }
        return .object(object)
    }

    /// `message UsagePeriod { UsagePeriodType type = 1; Timestamp start = 2; Timestamp end = 3; }`
    private static func usagePeriod(_ value: ProtobufReader.Value?) -> JSONValue? {
        guard let fields = value?.messageFields else { return nil }
        var object: [String: JSONValue] = [:]
        // proto3 omits the zero value, and 0 is UNSPECIFIED — which is what the parser
        // already falls back to, so an absent type needs no special case.
        if let type = fields.first(1)?.intValue { object["type"] = .number(Double(type)) }
        if let start = timestamp(fields.first(2)) { object["start"] = start }
        if let end = timestamp(fields.first(3)) { object["end"] = end }
        return object.isEmpty ? nil : .object(object)
    }

    /// `message ProductUsage { billing_product.Product product = 1; float usage_percent = 2; }`
    private static func productUsage(_ value: ProtobufReader.Value) -> JSONValue? {
        guard let fields = value.messageFields else { return nil }
        guard let percent = fields.first(2)?.floatValue else { return nil }
        return .object([
            "product": .number(Double(fields.first(1)?.intValue ?? 0)),
            "usagePercent": .number(percent),
        ])
    }
}

/// A gRPC-Web response body: a sequence of length-prefixed frames, the last of which carries
/// the trailers.
///
/// gRPC reports failure in `grpc-status`, not in the HTTP status — a hard-denied request still
/// comes back `HTTP 200`. Over HTTP/2 that status may arrive either in the response headers
/// (for a trailers-only response, which is what an auth failure produces) or in a trailer
/// frame inside the body. `URLSession` does not surface HTTP/2 trailers at all, which is
/// precisely why gRPC-**Web** puts them in the body instead.
public struct GrokGRPCWebFrames {
    /// The concatenated message payloads.
    public let message: Data
    /// Trailer keys, lowercased.
    public let trailers: [String: String]

    public init(message: Data, trailers: [String: String]) {
        self.message = message
        self.trailers = trailers
    }

    public static func parse(_ body: Data) -> GrokGRPCWebFrames {
        var message = Data()
        var trailers: [String: String] = [:]
        var index = body.startIndex

        while body.endIndex - index >= 5 {
            let flags = body[index]
            var length = 0
            for offset in 1...4 {
                length = (length << 8) | Int(body[index + offset])
            }
            let start = index + 5
            guard length >= 0, body.endIndex - start >= length else { break }
            let payload = body[start..<(start + length)]

            if flags & 0x80 != 0 {
                // Split with a scalar-aware API, not `split(whereSeparator:)` comparing to
                // "\r" and "\n". gRPC-Web delimits trailers with CRLF, and Swift treats CRLF
                // as a *single* Character — so a per-Character comparison against "\r" or
                // "\n" matches neither, and the whole block collapses into one value whose
                // status then fails to parse as an Int, silently discarding real errors.
                for line in (String(data: payload, encoding: .utf8) ?? "")
                    .components(separatedBy: .newlines) {
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: separator)...]
                        .trimmingCharacters(in: .whitespaces)
                    trailers[key] = value
                }
            } else {
                message.append(contentsOf: payload)
            }
            index = start + length
        }
        return GrokGRPCWebFrames(message: message, trailers: trailers)
    }

    /// A gRPC-Web request frame: one data frame wrapping `payload`.
    public static func frame(_ payload: Data) -> Data {
        var out = Data([0])
        let length = UInt32(payload.count)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload)
        return out
    }
}

/// The subset of gRPC status codes this app can act on differently.
public enum GrokRPCStatus {
    /// Maps a `grpc-status` code to the app's error vocabulary. `nil` means success.
    ///
    /// - Parameter message: `grpc-message`, which is percent-encoded on the wire.
    public static func error(code: Int, message: String?) -> UsageAPIError? {
        let detail = message
            .flatMap { $0.removingPercentEncoding ?? $0 }?
            .trimmingCharacters(in: .whitespaces)
        switch code {
        case 0: return nil
        case 16: return .unauthorized                       // UNAUTHENTICATED
        case 7: return .forbidden                           // PERMISSION_DENIED
        case 8: return .rateLimited(retryAfter: nil)        // RESOURCE_EXHAUSTED
        case 4: return .timedOut                            // DEADLINE_EXCEEDED
        case 14: return .server(status: 503)                // UNAVAILABLE
        case 13: return .server(status: 500)                // INTERNAL
        case 12, 5:
            // UNIMPLEMENTED / NOT_FOUND: the method moved or was withdrawn. That is a schema
            // problem to report, not a credential problem to send the user re-authenticating.
            return .unrecognizedSchema(
                detail?.isEmpty == false
                    ? "Grok billing RPC unavailable: \(detail!)"
                    : "Grok billing RPC is no longer available at this address."
            )
        default:
            return .network(
                detail?.isEmpty == false ? "gRPC \(code): \(detail!)" : "gRPC status \(code)"
            )
        }
    }
}
