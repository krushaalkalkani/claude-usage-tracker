import Foundation

public struct GrokParseResult: Sendable, Equatable {
    public let snapshot: UsageSnapshot
    public let planLabel: String?

    public init(snapshot: UsageSnapshot, planLabel: String?) {
        self.snapshot = snapshot
        self.planLabel = planLabel
    }
}

/// Normalizes grok.com's `GetGrokCreditsConfig` and `GetSubscriptions` responses into the
/// app's existing usage model. Like every other provider parser here, it reads a total
/// `JSONValue` tree with optional accessors: a field xAI stops sending becomes a schema
/// warning, never a crash.
///
/// ## Where this schema comes from
///
/// Grok's web app is a gRPC-Web client whose generated descriptors ship in its own JS bundle.
/// `GrokBuildBilling.GetGrokCreditsConfig` returns a `GrokCreditsConfig`:
///
/// ```proto
/// float             credit_usage_percent = 1;  // 0…100 — the "100% used" headline
/// prod_charger.Cent on_demand_cap        = 2;  // int64 cents, JSON-encoded as a string
/// prod_charger.Cent on_demand_used       = 3;
/// Timestamp         billing_period_start = 4;
/// Timestamp         billing_period_end   = 5;
/// repeated ProductUsage product_usage    = 7;  // the Automations/Chat/Imagine split
/// UsagePeriod       current_period       = 8;  // {type, start, end} — drives "Resets …"
/// prod_charger.Cent prepaid_balance      = 12; // "Extra Usage Credits $X.XX"
/// ```
///
/// The service's proto also declares `GET /rest/grok/credits` for the same method, but that
/// route is not mounted on grok.com's public edge, so `GrokUsageService` calls the RPC and
/// `GrokCreditsMessage` re-emits the protobuf as JSON before it reaches this parser.
///
/// Every accessor below therefore tolerates both encodings — the one protobuf's JSON mapping
/// produces and the one the REST route would, should it ever appear: enums arrive as either
/// their wire name (`"PRODUCT_GROK_TASKS"`) or their number, `int64` cents as either a JSON
/// string or a number, and timestamps as either an RFC 3339 string or a `{seconds, nanos}`
/// object. That is what keeps this parser independent of how the bytes arrived.
public enum GrokUsageParser {
    /// - Parameters:
    ///   - credits: a decoded `GetGrokCreditsConfigResponse`.
    ///   - subscriptions: `GET /rest/subscriptions` body, for the plan label only.
    public static func parse(
        credits: JSONValue?,
        subscriptions: JSONValue?,
        now: Date,
        keepRaw: Bool = true
    ) -> GrokParseResult {
        var warnings: [String] = []
        var limits: [LimitWindow] = []
        var shares: [ProductUsageShare] = []
        var spend: SpendInfo?
        var balance: UsageCredits?

        if let config = credits?["config"] {
            if let window = parseAllowance(config, warnings: &warnings) {
                limits.append(window)
            }
            shares = parseProductShares(config["productUsage"])
            spend = parseOnDemandSpend(config)
            balance = parsePrepaidBalance(config["prepaidBalance"])
        } else if credits != nil {
            warnings.append("the Grok credits response has no config object")
        } else {
            warnings.append("the Grok credits response is missing")
        }

        if limits.isEmpty {
            warnings.append("no Grok usage windows found in the response")
        }

        let planLabel = parsePlanLabel(subscriptions)

        var rawObject: [String: JSONValue] = [:]
        if keepRaw {
            if let credits { rawObject["credits"] = credits }
            if let subscriptions { rawObject["subscriptions"] = subscriptions }
        }

        return GrokParseResult(
            snapshot: UsageSnapshot(
                fetchedAt: now,
                limits: limits,
                spend: spend,
                schemaWarnings: warnings,
                raw: (keepRaw && !rawObject.isEmpty) ? .object(rawObject) : nil,
                provider: .grok,
                credits: balance,
                productShares: shares
            ),
            planLabel: planLabel
        )
    }

    // MARK: - The pooled allowance

    /// The single meter the usage panel leads with. Its period is whatever `current_period`
    /// says, so a plan billed monthly is never mislabelled "weekly" just because most are.
    private static func parseAllowance(
        _ config: JSONValue, warnings: inout [String]
    ) -> LimitWindow? {
        guard let rawPercent = config["creditUsagePercent"]?.doubleValue, rawPercent.isFinite
        else {
            warnings.append("the Grok credits response is missing creditUsagePercent")
            return nil
        }
        let safePercent = clampPercent(rawPercent)

        let period = config["currentPeriod"]
        let periodType = usagePeriodType(period?["type"])
        let start = timestamp(period?["start"])
        // `billing_period_end` is the subscription's renewal date and is not the same thing as
        // the usage window's end on a weekly plan, so it is only a fallback.
        let end = timestamp(period?["end"]) ?? timestamp(config["billingPeriodEnd"])

        let duration: TimeInterval?
        if let start, let end, end > start {
            duration = end.timeIntervalSince(start)
        } else {
            duration = periodType.defaultDuration
        }

        return LimitWindow(
            id: "grok_allowance",
            kind: "grok_credit_usage",
            group: periodType.group,
            title: periodType.title,
            shortTitle: periodType.shortTitle,
            percent: safePercent,
            resetsAt: end,
            severity: Severity.from(percent: safePercent),
            isActive: true,
            provider: .grok,
            rawPercent: safePercent == rawPercent ? nil : rawPercent,
            windowDuration: duration
        )
    }

    // MARK: - Product breakdown

    /// The "Automations 97% · Chat 2% · Imagine 1%" split. Shares of the one meter above, so
    /// they are deliberately not limit windows — see `ProductUsageShare`.
    private static func parseProductShares(_ node: JSONValue?) -> [ProductUsageShare] {
        guard let entries = node?.arrayValue else { return [] }
        return entries.compactMap { entry -> ProductUsageShare? in
            guard let rawPercent = entry["usagePercent"]?.doubleValue, rawPercent.isFinite,
                  rawPercent > 0
            else { return nil }
            let product = GrokProduct.from(entry["product"])
            return ProductUsageShare(
                id: product.id, label: product.label, percent: clampPercent(rawPercent)
            )
        }
        .sorted { $0.percent > $1.percent }
    }

    // MARK: - On-demand spend and prepaid balance

    /// Grok's "on demand" overage is the same idea as Claude's extra usage: a dollar cap the
    /// account can spend past its included allowance, so it reuses `SpendInfo` rather than
    /// inventing a parallel concept.
    private static func parseOnDemandSpend(_ config: JSONValue) -> SpendInfo? {
        let capCents = cents(config["onDemandCap"])
        let usedCents = cents(config["onDemandUsed"])
        guard capCents != nil || usedCents != nil else { return nil }

        let cap = capCents.map { Money(amountMinor: $0) }
        let used = usedCents.map { Money(amountMinor: $0) }
        let enabled = (capCents ?? 0) > 0
        let percent: Double? = {
            guard let capCents, capCents > 0, let usedCents else { return nil }
            return clampPercent(Double(usedCents) / Double(capCents) * 100)
        }()

        // An account that has never turned on-demand on, and never spent a cent, has nothing
        // worth a section of its own.
        guard enabled || (usedCents ?? 0) > 0 else { return nil }

        return SpendInfo(
            enabled: enabled,
            used: used,
            limit: cap,
            percent: percent,
            severity: percent.map { Severity.from(percent: $0) } ?? .normal,
            disabledReason: enabled ? nil : "user_disabled",
            userDisabled: !enabled,
            limitReached: percent.map { $0 >= 100 },
            everEnabled: (usedCents ?? 0) > 0 ? true : nil,
            balance: nil,
            disclaimer: nil
        )
    }

    /// "Extra Usage Credits — $0.00". Formatted here because `prod_charger.Cent` is US cents
    /// by definition, so this is not the app guessing at a provider-defined unit.
    private static func parsePrepaidBalance(_ node: JSONValue?) -> UsageCredits? {
        guard let minor = cents(node) else { return nil }
        let money = Money(amountMinor: minor)
        return UsageCredits(hasCredits: minor > 0, unlimited: nil, balance: money.formatted)
    }

    // MARK: - Plan label

    /// The tier of the first active subscription, mapped to the same words grok.com itself
    /// shows. An unrecognized tier is dropped rather than rendered as a raw enum constant.
    private static func parsePlanLabel(_ subscriptions: JSONValue?) -> String? {
        guard let entries = subscriptions?["subscriptions"]?.arrayValue else { return nil }
        let ranked = entries.compactMap { entry -> (rank: Int, label: String)? in
            guard let label = planLabel(for: entry["tier"]) else { return nil }
            let status = enumName(entry["status"])
            // Lapsed and cancelled rows stay in the list; an active one always wins.
            let isActive = status == nil || status?.contains("ACTIVE") == true
            return (isActive ? 0 : 1, label)
        }
        return ranked.min { $0.rank < $1.rank }?.label
    }

    private static func planLabel(for node: JSONValue?) -> String? {
        guard let name = enumName(node) else { return nil }
        switch name {
        case let n where n.hasSuffix("SUPER_GROK_PRO"): return "SuperGrok Heavy"
        case let n where n.hasSuffix("SUPER_GROK_PLUS"): return "SuperGrok Plus"
        case let n where n.hasSuffix("SUPER_GROK_LITE"): return "SuperGrok Lite"
        case let n where n.hasSuffix("GROK_PRO"): return "SuperGrok"
        case let n where n.hasSuffix("X_PREMIUM_PLUS"): return "X Premium+"
        case let n where n.hasSuffix("X_PREMIUM"): return "X Premium"
        case let n where n.hasSuffix("X_BASIC"): return "X Basic"
        default: return nil
        }
    }

    // MARK: - Shared decoding

    /// Period type, tolerating both the wire name and the raw enum number.
    private static func usagePeriodType(_ node: JSONValue?) -> GrokUsagePeriod {
        if let name = enumName(node) {
            if name.hasSuffix("WEEKLY") { return .weekly }
            if name.hasSuffix("MONTHLY") { return .monthly }
            return .unspecified
        }
        switch node?.intValue {
        case 1: return .monthly
        case 2: return .weekly
        default: return .unspecified
        }
    }

    /// A protobuf enum as its wire name, when it arrived as one. Numbers return `nil` so the
    /// caller can fall back to matching on the number instead of on a stringified digit.
    static func enumName(_ node: JSONValue?) -> String? {
        guard let raw = node?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces).uppercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A `prod_charger.Cent`. int64 is JSON-encoded as a string by protobuf, so `{"val":"250"}`
    /// and `{"val":250}` are both valid and both mean 250 cents.
    private static func cents(_ node: JSONValue?) -> Int? {
        guard let node else { return nil }
        // A bare number is accepted too, in case the field is ever flattened.
        let value = node["val"] ?? node
        guard let amount = value.doubleValue, amount.isFinite,
              abs(amount) < 1_000_000_000
        else { return nil }
        return Int(amount.rounded())
    }

    /// A `google.protobuf.Timestamp`: RFC 3339 over the REST route, `{seconds, nanos}` over
    /// the RPC one.
    private static func timestamp(_ node: JSONValue?) -> Date? {
        guard let node else { return nil }
        if let date = node.dateValue { return date.truncatingSubsecond }
        guard let seconds = node["seconds"]?.doubleValue, seconds.isFinite,
              seconds > 0, seconds < 32_503_680_000
        else { return nil }
        return Date(timeIntervalSince1970: seconds).truncatingSubsecond
    }

    private static func clampPercent(_ p: Double) -> Double {
        guard p.isFinite else { return 0 }
        return min(max(p, 0), 1000)
    }
}

/// Which billing period the pooled allowance runs on.
enum GrokUsagePeriod {
    case weekly
    case monthly
    case unspecified

    var group: LimitGroup {
        switch self {
        case .weekly: return .weekly
        case .monthly, .unspecified: return .other
        }
    }

    var title: String {
        switch self {
        case .weekly: return "Plan usage · weekly"
        case .monthly: return "Plan usage · monthly"
        case .unspecified: return "Plan usage"
        }
    }

    var shortTitle: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .unspecified: return "Plan usage"
        }
    }

    /// Only used when the response gave no usable start/end pair to measure.
    var defaultDuration: TimeInterval? {
        switch self {
        case .weekly: return 7 * 86_400
        case .monthly: return 30 * 86_400
        case .unspecified: return nil
        }
    }
}

/// `billing_product.Product`, with the product names grok.com's own settings panel uses.
enum GrokProduct {
    case chat
    case imagine
    case build
    case voice
    case plugins
    case api
    case appBuilder
    case tasks
    case other

    /// Accepts the wire name (`"PRODUCT_GROK_TASKS"`) or the enum number.
    static func from(_ node: JSONValue?) -> GrokProduct {
        if let name = GrokUsageParser.enumName(node) {
            // Suffix matching so an unprefixed `"GROK_TASKS"` reads the same as the full
            // `"PRODUCT_GROK_TASKS"`. Checked longest-first: "GROK_BUILD" would otherwise
            // never be reached past a bare "BUILD" test, and API is a suffix of nothing else.
            if name.hasSuffix("GROK_APP_BUILDER") { return .appBuilder }
            if name.hasSuffix("GROK_PLUGINS") { return .plugins }
            if name.hasSuffix("GROK_IMAGINE") { return .imagine }
            if name.hasSuffix("GROK_TASKS") { return .tasks }
            if name.hasSuffix("GROK_BUILD") { return .build }
            if name.hasSuffix("GROK_VOICE") { return .voice }
            if name.hasSuffix("GROK_CHAT") { return .chat }
            if name.hasSuffix("_API") || name == "API" { return .api }
            return .other
        }
        switch node?.intValue {
        case 1: return .api
        case 2: return .build
        case 3: return .plugins
        case 4: return .chat
        case 5: return .imagine
        case 6: return .voice
        case 7: return .appBuilder
        case 8: return .tasks
        default: return .other
        }
    }

    var id: String {
        switch self {
        case .chat: return "grok_chat"
        case .imagine: return "grok_imagine"
        case .build: return "grok_build"
        case .voice: return "grok_voice"
        case .plugins: return "grok_plugins"
        case .api: return "grok_api"
        case .appBuilder: return "grok_app_builder"
        case .tasks: return "grok_tasks"
        case .other: return "grok_other"
        }
    }

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .imagine: return "Imagine"
        case .build: return "Build"
        case .voice: return "Voice"
        case .plugins: return "Plugins"
        case .api: return "API"
        case .appBuilder: return "App Builder"
        case .tasks: return "Automations"
        case .other: return "Other"
        }
    }
}
