import Foundation

public struct CursorParseResult: Sendable, Equatable {
    public let snapshot: UsageSnapshot
    public let planLabel: String?

    public init(snapshot: UsageSnapshot, planLabel: String?) {
        self.snapshot = snapshot
        self.planLabel = planLabel
    }
}

/// Normalizes Cursor's three undocumented `cursor.com/api/dashboard/*` responses into the
/// app's existing usage model. Like `UsageParser` and `ChatGPTUsageParser`, this decodes into
/// a total `JSONValue` tree and reads fields with optional accessors: a field the dashboard
/// stops sending becomes a schema warning, never a crash.
///
/// Cursor exposes no single "usage" document the way Claude and ChatGPT do — the three calls
/// below are separate, so a caller may have any subset of them (a failed call for one window
/// should not blank out a window we did get data for).
public enum CursorUsageParser {
    /// - Parameters:
    ///   - planInfo: `POST /api/dashboard/get-plan-info` body, for the plan label only.
    ///   - currentPeriodUsage: `POST /api/dashboard/get-current-period-usage` body — the
    ///     included-usage ("Cursor Models") meter.
    ///   - sandUsageStatus: `POST /api/dashboard/get-sand-usage-status` body — the weekly
    ///     "Grok Bot" meter. `sand` is Cursor's internal codename; the label shown to the user
    ///     is the product-facing "Grok Bot", not the codename.
    ///
    ///     `get-credit-grants-balance` (the "$X.XX remaining" credits line) is deliberately not
    ///     parsed here: it returned an empty object during reverse-engineering and its real
    ///     shape is unknown. Treat it as a known gap rather than guessing.
    public static func parse(
        planInfo: JSONValue?,
        currentPeriodUsage: JSONValue?,
        sandUsageStatus: JSONValue?,
        now: Date,
        keepRaw: Bool = true
    ) -> CursorParseResult {
        var warnings: [String] = []
        var limits: [LimitWindow] = []

        if let currentPeriodUsage {
            if let window = parseIncludedUsage(currentPeriodUsage, warnings: &warnings) {
                limits.append(window)
            }
        } else {
            warnings.append("get-current-period-usage response missing")
        }

        if let sandUsageStatus {
            if let window = parseGrokBot(sandUsageStatus, warnings: &warnings) {
                limits.append(window)
            }
        } else {
            warnings.append("get-sand-usage-status response missing")
        }

        if limits.isEmpty {
            warnings.append("no Cursor usage windows found in the response")
        }

        let planLabel = sanitizedPlanLabel(planInfo?["planInfo"]?["planName"]?.stringValue)

        var rawObject: [String: JSONValue] = [:]
        if keepRaw {
            if let planInfo { rawObject["planInfo"] = planInfo }
            if let currentPeriodUsage { rawObject["currentPeriodUsage"] = currentPeriodUsage }
            if let sandUsageStatus { rawObject["sandUsageStatus"] = sandUsageStatus }
        }

        return CursorParseResult(
            snapshot: UsageSnapshot(
                fetchedAt: now,
                limits: limits,
                spend: nil,
                schemaWarnings: warnings,
                raw: (keepRaw && !rawObject.isEmpty) ? .object(rawObject) : nil,
                provider: .cursor
            ),
            planLabel: planLabel
        )
    }

    // MARK: - Included usage ("Cursor Models" / "Other Models")

    private static func parseIncludedUsage(
        _ root: JSONValue, warnings: inout [String]
    ) -> LimitWindow? {
        guard let planUsage = root["planUsage"] else {
            warnings.append("get-current-period-usage missing planUsage")
            return nil
        }
        guard let rawPercent = planUsage["totalPercentUsed"]?.doubleValue
            ?? fallbackPercent(remaining: planUsage["remaining"]?.doubleValue,
                                limit: planUsage["limit"]?.doubleValue)
        else {
            warnings.append("get-current-period-usage planUsage missing totalPercentUsed")
            return nil
        }
        guard rawPercent.isFinite else {
            warnings.append("get-current-period-usage totalPercentUsed was not a number")
            return nil
        }

        let safePercent = clampPercent(rawPercent)
        let resetsAt = epochMillisDate(root["billingCycleEnd"])

        return LimitWindow(
            id: "included_usage",
            kind: "cursor_included_usage",
            group: .other,
            title: "Included usage",
            shortTitle: "Included usage",
            percent: safePercent,
            resetsAt: resetsAt,
            severity: Severity.from(percent: safePercent),
            isActive: false,
            provider: .cursor,
            rawPercent: safePercent == rawPercent ? nil : rawPercent
        )
    }

    private static func fallbackPercent(remaining: Double?, limit: Double?) -> Double? {
        guard let remaining, let limit, limit > 0 else { return nil }
        return max(0, (1 - remaining / limit) * 100)
    }

    // MARK: - Grok Bot (internal codename "sand")

    private static func parseGrokBot(
        _ root: JSONValue, warnings: inout [String]
    ) -> LimitWindow? {
        guard let rawPercent = root["usagePercent"]?.doubleValue, rawPercent.isFinite else {
            warnings.append("get-sand-usage-status missing usagePercent")
            return nil
        }

        let safePercent = clampPercent(rawPercent)
        let resetsAt = root["nextResetTimestampUtc"]?.dateValue?.truncatingSubsecond

        return LimitWindow(
            id: "grok_bot",
            kind: "cursor_grok_bot",
            group: .weekly,
            title: "Grok Bot · weekly",
            shortTitle: "Grok Bot",
            percent: safePercent,
            resetsAt: resetsAt,
            severity: Severity.from(percent: safePercent),
            isActive: false,
            provider: .cursor,
            rawPercent: safePercent == rawPercent ? nil : rawPercent
        )
    }

    // MARK: - Shared

    private static func clampPercent(_ p: Double) -> Double {
        guard p.isFinite else { return 0 }
        return min(max(p, 0), 1000)
    }

    /// `billingCycleEnd` (and similar fields) are epoch **milliseconds**, sent as a JSON
    /// string rather than a number.
    private static func epochMillisDate(_ node: JSONValue?) -> Date? {
        guard let ms = node?.doubleValue, ms.isFinite, ms > 0, ms < 32_503_680_000_000 else {
            return nil
        }
        return Date(timeIntervalSince1970: ms / 1000).truncatingSubsecond
    }

    private static func sanitizedPlanLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let oneLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !oneLine.isEmpty, oneLine.count <= 64 else { return nil }
        return oneLine
    }
}
