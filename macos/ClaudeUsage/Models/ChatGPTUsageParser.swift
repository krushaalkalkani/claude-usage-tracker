import Foundation

public struct ChatGPTParseResult: Sendable, Equatable {
    public let snapshot: UsageSnapshot
    public let planLabel: String?

    public init(snapshot: UsageSnapshot, planLabel: String?) {
        self.snapshot = snapshot
        self.planLabel = planLabel
    }
}

/// Normalizes both supported ChatGPT/Codex data shapes into the app's existing usage model:
/// the public Codex app-server result and the isolated `/wham/usage` fallback payload.
public enum ChatGPTUsageParser {
    private enum WindowRole: String { case primary, secondary }

    public static func parseAppServer(
        _ result: JSONValue,
        accountPlan: String?,
        now: Date,
        keepRaw: Bool = true
    ) -> ChatGPTParseResult {
        var warnings: [String] = []
        let buckets = appServerBuckets(result, warnings: &warnings)
        var limits: [LimitWindow] = []

        for (index, bucket) in buckets.enumerated() {
            let isMain = bucket.key == "codex" || (index == 0 && !buckets.contains { $0.key == "codex" })
            let label = isMain ? nil : sanitizedLabel(
                bucket.value["limitName"]?.stringValue ?? bucket.key
            )
            if let primary = parseWindow(
                bucket.value["primary"], role: .primary, bucketKey: bucket.key,
                label: label, isMain: isMain, durationUnit: .minutes,
                warningLabel: isMain ? "primary" : "additional primary",
                warnings: &warnings
            ) {
                limits.append(primary)
            }
            if let secondary = parseWindow(
                bucket.value["secondary"], role: .secondary, bucketKey: bucket.key,
                label: label, isMain: isMain, durationUnit: .minutes,
                warningLabel: isMain ? "secondary" : "additional secondary",
                warnings: &warnings
            ) {
                limits.append(secondary)
            }
        }

        if limits.isEmpty { warnings.append("ChatGPT response contained no readable usage windows") }
        limits = deduplicatedAndSorted(limits)

        let metadataNode = buckets.first(where: { $0.key == "codex" })?.value
            ?? buckets.first?.value
        let plan = sanitizedPlan(
            metadataNode?["planType"]?.stringValue ?? accountPlan
        )
        let credits = parseCredits(metadataNode?["credits"])
        let spendControl = parseSpendControl(metadataNode?["individualLimit"])

        return ChatGPTParseResult(
            snapshot: UsageSnapshot(
                fetchedAt: now,
                limits: limits,
                spend: nil,
                schemaWarnings: warnings,
                raw: keepRaw ? result : nil,
                provider: .chatgpt,
                credits: credits,
                spendControl: spendControl
            ),
            planLabel: plan
        )
    }

    public static func parseDirect(
        _ root: JSONValue,
        now: Date,
        keepRaw: Bool = true
    ) -> ChatGPTParseResult {
        var warnings: [String] = []
        var limits: [LimitWindow] = []

        if let rateLimit = root["rate_limit"] {
            if let primary = parseWindow(
                rateLimit["primary_window"], role: .primary, bucketKey: "codex",
                label: nil, isMain: true, durationUnit: .seconds,
                warningLabel: "primary", warnings: &warnings
            ) { limits.append(primary) }
            if let secondary = parseWindow(
                rateLimit["secondary_window"], role: .secondary, bucketKey: "codex",
                label: nil, isMain: true, durationUnit: .seconds,
                warningLabel: "secondary", warnings: &warnings
            ) { limits.append(secondary) }
        } else {
            warnings.append("ChatGPT rate_limit object missing")
        }

        if let additional = root["additional_rate_limits"]?.arrayValue {
            for (index, entry) in additional.enumerated() {
                guard let rateLimit = entry["rate_limit"] else {
                    warnings.append("ChatGPT additional limit #\(index + 1) had no rate_limit object")
                    continue
                }
                let label = sanitizedLabel(entry["limit_name"]?.stringValue)
                    ?? "Additional limit \(index + 1)"
                let key = entry["metered_feature"]?.stringValue ?? label
                if let primary = parseWindow(
                    rateLimit["primary_window"], role: .primary, bucketKey: key,
                    label: label, isMain: false, durationUnit: .seconds,
                    warningLabel: "additional primary #\(index + 1)", warnings: &warnings
                ) { limits.append(primary) }
                if let secondary = parseWindow(
                    rateLimit["secondary_window"], role: .secondary, bucketKey: key,
                    label: label, isMain: false, durationUnit: .seconds,
                    warningLabel: "additional secondary #\(index + 1)", warnings: &warnings
                ) { limits.append(secondary) }
            }
        } else if root["additional_rate_limits"] != nil {
            warnings.append("ChatGPT additional_rate_limits was not an array")
        }

        if limits.isEmpty { warnings.append("ChatGPT response contained no readable usage windows") }
        limits = deduplicatedAndSorted(limits)

        let spendNode = root["spend_control"]?["individual_limit"]
            ?? root["spend_control"]?["individualLimit"]

        return ChatGPTParseResult(
            snapshot: UsageSnapshot(
                fetchedAt: now,
                limits: limits,
                spend: nil,
                schemaWarnings: warnings,
                raw: keepRaw ? root : nil,
                provider: .chatgpt,
                credits: parseCredits(root["credits"]),
                spendControl: parseSpendControl(spendNode)
            ),
            planLabel: sanitizedPlan(root["plan_type"]?.stringValue)
        )
    }

    // MARK: - Windows

    private enum DurationUnit { case seconds, minutes }

    private static func parseWindow(
        _ node: JSONValue?,
        role: WindowRole,
        bucketKey: String,
        label: String?,
        isMain: Bool,
        durationUnit: DurationUnit,
        warningLabel: String,
        warnings: inout [String]
    ) -> LimitWindow? {
        guard let node else { return nil }
        let rawPercent = node["usedPercent"]?.doubleValue
            ?? node["used_percent"]?.doubleValue
        guard let rawPercent, rawPercent.isFinite else {
            warnings.append("ChatGPT \(warningLabel) window had no valid used percent")
            return nil
        }

        let safePercent = min(max(rawPercent, 0), 100)
        if safePercent != rawPercent {
            warnings.append("ChatGPT \(warningLabel) used percent was outside 0...100 and was clamped")
        }

        let rawDuration = node["windowDurationMins"]?.doubleValue
            ?? node["limit_window_seconds"]?.doubleValue
        let duration: TimeInterval? = rawDuration.flatMap { value in
            guard value.isFinite, value > 0 else {
                warnings.append("ChatGPT \(warningLabel) window duration was invalid")
                return nil
            }
            return durationUnit == .minutes ? value * 60 : value
        }

        let group = inferGroup(role: role, duration: duration)
        let period = durationLabel(duration, fallbackGroup: group)
        let safeLabel = label.flatMap(sanitizedLabel)
        let title: String
        let shortTitle: String
        let kind: String
        let id: String

        if isMain {
            shortTitle = group == .weekly ? "Weekly" : group == .session ? "Session" : "Codex"
            title = "\(period) limit"
            kind = group == .session ? "session" : group == .weekly ? "weekly_all" : "codex_\(role.rawValue)"
            if group == .session { id = "session" }
            else if group == .weekly { id = "weekly_all" }
            else { id = "codex_\(role.rawValue)" }
        } else {
            let name = safeLabel ?? "Additional limit"
            shortTitle = name
            title = "\(name) · \(period)"
            kind = "chatgpt_additional"
            // The source key is useful for stable deduplication but may be opaque. Persist a
            // deterministic fingerprint rather than copying the raw value into history.
            id = "additional:\(stableFingerprint(bucketKey))|\(role.rawValue)"
        }

        return LimitWindow(
            id: id,
            kind: kind,
            group: group,
            title: title,
            shortTitle: shortTitle,
            percent: safePercent,
            resetsAt: epochDate(
                node["resetsAt"]?.doubleValue ?? node["reset_at"]?.doubleValue,
                warningLabel: warningLabel,
                warnings: &warnings
            ),
            severity: Severity.from(percent: safePercent),
            isActive: isMain,
            modelName: isMain ? nil : safeLabel,
            provider: .chatgpt,
            rawPercent: safePercent == rawPercent ? nil : rawPercent,
            windowDuration: duration
        )
    }

    private static func inferGroup(role: WindowRole, duration: TimeInterval?) -> LimitGroup {
        if let duration {
            if duration >= 24 * 3600 { return .weekly }
            if duration <= 12 * 3600 { return .session }
            return .other
        }
        return role == .primary ? .session : .weekly
    }

    private static func durationLabel(
        _ duration: TimeInterval?, fallbackGroup: LimitGroup
    ) -> String {
        guard let duration else {
            switch fallbackGroup {
            case .session: return "5-hour"
            case .weekly: return "7-day"
            case .other: return "Codex"
            }
        }
        let minutes = Int((duration / 60).rounded())
        if minutes % (24 * 60) == 0 {
            let days = minutes / (24 * 60)
            return "\(days)-day"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)-hour"
        }
        return "\(minutes)-minute"
    }

    private static func epochDate(
        _ seconds: Double?, warningLabel: String, warnings: inout [String]
    ) -> Date? {
        guard let seconds else { return nil }
        guard seconds.isFinite, seconds > 0, seconds < 32_503_680_000 else {
            warnings.append("ChatGPT \(warningLabel) reset timestamp was invalid")
            return nil
        }
        return Date(timeIntervalSince1970: seconds).truncatingSubsecond
    }

    // MARK: - Metadata

    private static func parseCredits(_ node: JSONValue?) -> UsageCredits? {
        guard let node else { return nil }
        let balance = decimalString(node["balance"])
        let credits = UsageCredits(
            hasCredits: node["hasCredits"]?.boolValue ?? node["has_credits"]?.boolValue,
            unlimited: node["unlimited"]?.boolValue,
            balance: balance
        )
        return credits.isPresentable ? credits : nil
    }

    private static func parseSpendControl(_ node: JSONValue?) -> UsageSpendControl? {
        guard let node,
              let used = decimalString(node["used"]),
              let limit = decimalString(node["limit"])
        else { return nil }
        let reset = node["resetsAt"]?.doubleValue ?? node["reset_at"]?.doubleValue
        var ignored: [String] = []
        return UsageSpendControl(
            used: used,
            limit: limit,
            remainingPercent: node["remainingPercent"]?.doubleValue
                ?? node["remaining_percent"]?.doubleValue,
            resetsAt: epochDate(reset, warningLabel: "spend control", warnings: &ignored)
        )
    }

    private static func decimalString(_ node: JSONValue?) -> String? {
        if let string = node?.stringValue {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= 40, Decimal(string: trimmed) != nil else { return nil }
            return trimmed
        }
        guard let number = node?.doubleValue, number.isFinite else { return nil }
        return String(format: "%.2f", number)
    }

    private static func sanitizedPlan(_ raw: String?) -> String? {
        guard let value = sanitizedLabel(raw) else { return nil }
        switch value.lowercased() {
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "business", "self_serve_business_usage_based": return "Business"
        case "enterprise", "enterprise_cbp_usage_based": return "Enterprise"
        case "edu", "education": return "Education"
        case "free": return "Free"
        default: return nil
        }
    }

    private static func sanitizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let oneLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !oneLine.isEmpty else { return nil }
        // Limit names should be product/model labels. Reject values that look like identity,
        // URLs, paths, or tokens rather than showing or persisting them as metadata.
        guard !oneLine.contains("@"), !oneLine.contains("://"), !oneLine.contains("/"),
              oneLine.filter({ $0 == "." }).count < 2
        else { return nil }
        return String(oneLine.prefix(64))
    }

    /// Stable FNV-1a fingerprint. This is not used for security; it gives provider-local
    /// buckets stable identities without persisting the potentially opaque source string.
    private static func stableFingerprint(_ raw: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func appServerBuckets(
        _ result: JSONValue, warnings: inout [String]
    ) -> [(key: String, value: JSONValue)] {
        if let byID = result["rateLimitsByLimitId"]?.objectValue, !byID.isEmpty {
            return byID.keys.sorted { a, b in
                if a == "codex" { return true }
                if b == "codex" { return false }
                return a < b
            }.compactMap { key in byID[key].map { (key, $0) } }
        }
        if let single = result["rateLimits"] {
            let key = single["limitId"]?.stringValue ?? "codex"
            return [(key, single)]
        }
        warnings.append("Codex CLI returned no rate-limit buckets")
        return []
    }

    private static func deduplicatedAndSorted(_ limits: [LimitWindow]) -> [LimitWindow] {
        var seen = Set<String>()
        return limits.filter { seen.insert($0.id).inserted }.sorted { a, b in
            func rank(_ window: LimitWindow) -> Int {
                if window.group == .session && !window.isModelScoped { return 0 }
                if window.group == .weekly && !window.isModelScoped { return 1 }
                if window.isModelScoped { return 2 }
                return 3
            }
            let left = rank(a), right = rank(b)
            if left != right { return left < right }
            if a.percent != b.percent { return a.percent > b.percent }
            return a.id < b.id
        }
    }
}
