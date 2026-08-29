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
    ///   - currentPeriodUsage: `POST /api/dashboard/get-current-period-usage` body — the two
    ///     included-usage meters, "Cursor Models" (the `auto` bucket) and "Other Models" (the
    ///     `api` bucket), which the dashboard shows and tracks separately even though they draw
    ///     from the same monthly pool.
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
            limits.append(contentsOf: parseIncludedUsage(currentPeriodUsage, warnings: &warnings))
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

    /// The dashboard shows these as two separate meters - "Cursor Models" (the `auto` bucket:
    /// Cursor's own Grok and Composer models) and "Other Models" (the `api` bucket: everything
    /// else, billed against the same included pool) - not the single blended total this parser
    /// used to collapse them into.
    private static func parseIncludedUsage(
        _ root: JSONValue, warnings: inout [String]
    ) -> [LimitWindow] {
        guard let planUsage = root["planUsage"] else {
            warnings.append("get-current-period-usage missing planUsage")
            return []
        }
        let resetsAt = epochMillisDate(root["billingCycleEnd"])
        // The payload carries both ends of the billing cycle, so the window's real length is
        // known rather than guessed. Without it these windows fell into the "unknown length"
        // path: no pace bar, no window-start cutoff for the burn rate, and a hero eyebrow
        // that invented a period out of the internal `kind` string.
        let duration = billingCycleLength(
            start: epochMillisDate(root["billingCycleStart"]), end: resetsAt
        )

        var windows: [LimitWindow] = []
        if let window = includedUsageWindow(
            planUsage["autoPercentUsed"]?.doubleValue,
            id: "cursor_models", kind: "cursor_models_included",
            title: "Cursor Models", resetsAt: resetsAt, duration: duration
        ) {
            windows.append(window)
        } else {
            warnings.append("get-current-period-usage planUsage missing autoPercentUsed")
        }
        if let window = includedUsageWindow(
            planUsage["apiPercentUsed"]?.doubleValue,
            id: "other_models", kind: "cursor_other_models_included",
            title: "Other Models", resetsAt: resetsAt, duration: duration
        ) {
            windows.append(window)
        } else {
            warnings.append("get-current-period-usage planUsage missing apiPercentUsed")
        }
        return windows
    }

    /// Length of the billing cycle, rejecting anything that is not plausibly a monthly-ish
    /// period — a start after its end, or a span so long it can only be a bad timestamp.
    private static func billingCycleLength(start: Date?, end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        let span = end.timeIntervalSince(start)
        guard span >= 86_400, span <= 400 * 86_400 else { return nil }
        return span
    }

    private static func includedUsageWindow(
        _ rawPercent: Double?, id: String, kind: String, title: String,
        resetsAt: Date?, duration: TimeInterval?
    ) -> LimitWindow? {
        guard let rawPercent, rawPercent.isFinite else { return nil }
        let safePercent = clampPercent(rawPercent)
        return LimitWindow(
            id: id,
            kind: kind,
            group: .other,
            title: title,
            shortTitle: title,
            percent: safePercent,
            resetsAt: resetsAt,
            severity: Severity.from(percent: safePercent),
            isActive: false,
            provider: .cursor,
            rawPercent: safePercent == rawPercent ? nil : rawPercent,
            windowDuration: duration
        )
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
            // Named like Claude's "Cowork · 7-day": without this the hero card falls through to
            // the generic `.weekly` label and reads "Weekly · 7-day", never naming Grok Bot at
            // all - which matters here because Cursor has more than one weekly-ish meter.
            surface: "Grok Bot",
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
