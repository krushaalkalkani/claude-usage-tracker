import Foundation

/// Credit metadata exactly as a provider returned it. A balance is kept as a decimal string
/// because its unit is provider-defined; the app never guesses a currency.
public struct UsageCredits: Sendable, Codable, Equatable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: String?

    public init(hasCredits: Bool?, unlimited: Bool?, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }

    public var isPresentable: Bool {
        unlimited == true || hasCredits != nil || balance != nil
    }
}

/// Optional spend-control metadata. Values remain provider-formatted decimal strings so a
/// subscription credit balance is never mislabeled as dollars.
public struct UsageSpendControl: Sendable, Codable, Equatable {
    public let used: String
    public let limit: String
    public let remainingPercent: Double?
    public let resetsAt: Date?

    public init(used: String, limit: String, remainingPercent: Double?, resetsAt: Date?) {
        self.used = used
        self.limit = limit
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }
}

/// A parsed, normalized view of one `/api/oauth/usage` response.
public struct UsageSnapshot: Sendable, Codable, Equatable {
    public let provider: UsageProvider
    /// When this snapshot was received.
    public let fetchedAt: Date
    /// Every quota window we could make sense of, in display order.
    public let limits: [LimitWindow]
    public let spend: SpendInfo?
    public let credits: UsageCredits?
    public let spendControl: UsageSpendControl?
    /// Notes about fields we expected but did not find. Surfaced only in debug mode; never
    /// blocks rendering.
    public let schemaWarnings: [String]
    /// The untouched payload, kept for the debug export. Never persisted to history.
    public let raw: JSONValue?

    public init(
        fetchedAt: Date,
        limits: [LimitWindow],
        spend: SpendInfo?,
        schemaWarnings: [String] = [],
        raw: JSONValue? = nil,
        provider: UsageProvider = .claude,
        credits: UsageCredits? = nil,
        spendControl: UsageSpendControl? = nil
    ) {
        self.provider = provider
        self.fetchedAt = fetchedAt
        self.limits = limits
        self.spend = spend
        self.credits = credits
        self.spendControl = spendControl
        self.schemaWarnings = schemaWarnings
        self.raw = raw
    }

    public var sessionLimit: LimitWindow? {
        limits.first { $0.group == .session }
    }

    /// The account-wide weekly limit (not a model-scoped one).
    public var weeklyLimit: LimitWindow? {
        limits.first { $0.group == .weekly && !$0.isModelScoped && $0.surface == nil }
    }

    public var modelLimits: [LimitWindow] {
        limits.filter(\.isModelScoped).sorted { $0.percent > $1.percent }
    }

    /// Scoped limits that are not model-scoped (e.g. a surface like Cowork).
    public var surfaceLimits: [LimitWindow] {
        limits.filter { $0.surface != nil && !$0.isModelScoped }
    }

    public var hasAnyData: Bool {
        !limits.isEmpty || spend != nil || credits != nil || spendControl != nil
    }

    /// Severity of the quota windows alone.
    ///
    /// Spend is deliberately excluded. An over-cap extra-usage balance is a persistent
    /// billing state, not quota urgency — letting it in meant a panel showing 78% of the
    /// session still free was painted red, which trains you to ignore the color entirely.
    public var limitSeverity: Severity {
        limits.map(\.severity).max() ?? .normal
    }

    /// Everything, spend included. For places that really do mean "is anything wrong".
    public var worstSeverity: Severity {
        var worst = limitSeverity
        if let s = spend?.severity, s > worst { worst = s }
        return worst
    }

    /// The single limit a user most needs to know about: highest utilisation, breaking ties
    /// in favour of the one the API marked active.
    public var bottleneck: LimitWindow? {
        limits.max { a, b in
            if abs(a.percent - b.percent) < 1 {
                if a.isActive != b.isActive { return b.isActive }
            }
            return a.percent < b.percent
        }
    }

    // `raw` is excluded from Codable so that persisting a snapshot never writes the full
    // payload (which carries workspace/organization identifiers) to disk.
    private enum CodingKeys: String, CodingKey {
        case provider, fetchedAt, limits, spend, credits, spendControl, schemaWarnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(UsageProvider.self, forKey: .provider) ?? .claude
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        limits = try c.decodeIfPresent([LimitWindow].self, forKey: .limits) ?? []
        spend = try c.decodeIfPresent(SpendInfo.self, forKey: .spend)
        credits = try c.decodeIfPresent(UsageCredits.self, forKey: .credits)
        spendControl = try c.decodeIfPresent(UsageSpendControl.self, forKey: .spendControl)
        schemaWarnings = try c.decodeIfPresent([String].self, forKey: .schemaWarnings) ?? []
        raw = nil
    }
}

// MARK: - Parsing

public enum UsageParser {
    /// Well-known keys that carry a limit-shaped object at the top level. Everything else at
    /// the root is either metadata or an internal codename we deliberately do not label.
    private static let legacyKeys: [(key: String, kind: String, group: LimitGroup, title: String, short: String)] = [
        ("five_hour", "session", .session, "5-hour limit", "Session"),
        ("seven_day", "weekly_all", .weekly, "7-day limit", "Weekly"),
        ("seven_day_opus", "weekly_scoped", .weekly, "Opus · 7-day", "Opus"),
        ("seven_day_sonnet", "weekly_scoped", .weekly, "Sonnet · 7-day", "Sonnet"),
        ("seven_day_haiku", "weekly_scoped", .weekly, "Haiku · 7-day", "Haiku"),
        ("seven_day_cowork", "weekly_scoped", .weekly, "Cowork · 7-day", "Cowork"),
        ("seven_day_oauth_apps", "weekly_scoped", .weekly, "OAuth apps · 7-day", "OAuth apps"),
    ]

    /// Legacy keys that name a model, so we can mark them model-scoped.
    private static let legacyModelNames: [String: String] = [
        "seven_day_opus": "Opus",
        "seven_day_sonnet": "Sonnet",
        "seven_day_haiku": "Haiku",
    ]

    private static let legacySurfaceNames: [String: String] = [
        "seven_day_cowork": "Cowork",
        "seven_day_oauth_apps": "OAuth apps",
    ]

    public static func parse(_ root: JSONValue, now: Date, keepRaw: Bool = true) -> UsageSnapshot {
        var warnings: [String] = []
        var limits: [LimitWindow] = []
        var seenIDs = Set<String>()

        // 1. The modern shape. `limits[]` is authoritative when present.
        if let entries = root["limits"]?.arrayValue {
            for entry in entries {
                guard let window = parseLimitEntry(entry) else { continue }
                if seenIDs.insert(window.id).inserted {
                    limits.append(window)
                }
            }
            if limits.isEmpty && !entries.isEmpty {
                warnings.append("limits[] present but no entry could be read")
            }
        } else {
            warnings.append("limits[] missing — falling back to legacy top-level keys")
        }

        // 2. Legacy top-level keys fill gaps only. If `limits[]` already described a window,
        //    we do not duplicate it.
        for spec in legacyKeys {
            guard let node = root[spec.key] else { continue }
            guard let percent = node["utilization"]?.doubleValue else { continue }
            let id = legacyID(for: spec)
            guard !seenIDs.contains(id) else { continue }
            seenIDs.insert(id)
            limits.append(
                LimitWindow(
                    id: id,
                    kind: spec.kind,
                    group: spec.group,
                    title: spec.title,
                    shortTitle: spec.short,
                    percent: clampPercent(percent),
                    resetsAt: node["resets_at"]?.dateValue?.truncatingSubsecond,
                    severity: Severity.from(percent: percent),
                    isActive: false,
                    modelName: legacyModelNames[spec.key],
                    modelID: nil,
                    surface: legacySurfaceNames[spec.key],
                    usedDollars: node["used_dollars"]?.doubleValue,
                    limitDollars: node["limit_dollars"]?.doubleValue,
                    remainingDollars: node["remaining_dollars"]?.doubleValue
                )
            )
        }

        if limits.isEmpty {
            warnings.append("no usage limits found in response")
        }

        limits.sort(by: displayOrder)

        let spend = parseSpend(root, warnings: &warnings)

        return UsageSnapshot(
            fetchedAt: now,
            limits: limits,
            spend: spend,
            schemaWarnings: warnings,
            raw: keepRaw ? root : nil
        )
    }

    // MARK: limits[]

    private static func parseLimitEntry(_ entry: JSONValue) -> LimitWindow? {
        // `percent` is the only field we cannot do without.
        guard let percent = entry["percent"]?.doubleValue ?? entry["utilization"]?.doubleValue
        else { return nil }

        let kind = entry["kind"]?.stringValue ?? "unknown"
        let groupRaw = entry["group"]?.stringValue
        let group = LimitGroup(rawValue: groupRaw ?? "") ?? inferGroup(kind: kind)

        let scope = entry["scope"]
        let modelName = scope?["model"]?["display_name"]?.stringValue
        let modelID = scope?["model"]?["id"]?.stringValue
        let surface = scope?["surface"]?.stringValue
            ?? scope?["surface"]?["display_name"]?.stringValue

        let severity = entry["severity"]?.stringValue
            .flatMap(Severity.init(rawValue:))
            ?? Severity.from(percent: percent)

        let (title, short) = titles(kind: kind, group: group, model: modelName, surface: surface)

        return LimitWindow(
            id: identity(kind: kind, group: group, model: modelName, modelID: modelID, surface: surface),
            kind: kind,
            group: group,
            title: title,
            shortTitle: short,
            percent: clampPercent(percent),
            resetsAt: entry["resets_at"]?.dateValue?.truncatingSubsecond,
            severity: severity,
            isActive: entry["is_active"]?.boolValue ?? false,
            modelName: modelName,
            modelID: modelID,
            surface: surface,
            usedDollars: entry["used_dollars"]?.doubleValue,
            limitDollars: entry["limit_dollars"]?.doubleValue,
            remainingDollars: entry["remaining_dollars"]?.doubleValue
        )
    }

    private static func inferGroup(kind: String) -> LimitGroup {
        if kind.contains("session") { return .session }
        if kind.contains("weekly") || kind.contains("seven_day") { return .weekly }
        return .other
    }

    /// Human titles. An unrecognized `kind` keeps its raw string rather than disappearing.
    private static func titles(
        kind: String, group: LimitGroup, model: String?, surface: String?
    ) -> (String, String) {
        let period: String
        switch group {
        case .session: period = "5-hour"
        case .weekly: period = "7-day"
        case .other: period = kind.replacingOccurrences(of: "_", with: " ")
        }
        if let model {
            return ("\(model) · \(period)", model)
        }
        if let surface {
            return ("\(surface) · \(period)", surface)
        }
        switch group {
        case .session: return ("5-hour limit", "Session")
        case .weekly: return ("7-day limit", "Weekly")
        case .other: return (kind.replacingOccurrences(of: "_", with: " ").capitalizedFirst, kind)
        }
    }

    /// A stable id. It must survive across polls (history + notification dedup depend on it)
    /// but distinguish every window the API reports.
    private static func identity(
        kind: String, group: LimitGroup, model: String?, modelID: String?, surface: String?
    ) -> String {
        var parts = [kind]
        if let modelID { parts.append("m:\(modelID)") }
        else if let model { parts.append("m:\(model.lowercased())") }
        if let surface { parts.append("s:\(surface.lowercased())") }
        return parts.joined(separator: "|")
    }

    private static func legacyID(
        for spec: (key: String, kind: String, group: LimitGroup, title: String, short: String)
    ) -> String {
        identity(
            kind: spec.kind,
            group: spec.group,
            model: legacyModelNames[spec.key],
            modelID: nil,
            surface: legacySurfaceNames[spec.key]
        )
    }

    /// Session first, then account-wide weekly, then scoped windows by utilisation.
    private static func displayOrder(_ a: LimitWindow, _ b: LimitWindow) -> Bool {
        func rank(_ w: LimitWindow) -> Int {
            if w.group == .session { return 0 }
            if w.group == .weekly && !w.isModelScoped && w.surface == nil { return 1 }
            if w.isModelScoped { return 2 }
            return 3
        }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb }
        if a.percent != b.percent { return a.percent > b.percent }
        return a.id < b.id
    }

    private static func clampPercent(_ p: Double) -> Double {
        guard p.isFinite else { return 0 }
        // Utilisation can legitimately exceed 100 during an overage; clamp only the low end
        // and a nonsensical high end.
        return min(max(p, 0), 1000)
    }

    // MARK: spend

    private static func parseSpend(_ root: JSONValue, warnings: inout [String]) -> SpendInfo? {
        let spendNode = root["spend"]
        let extraNode = root["extra_usage"]
        guard spendNode != nil || extraNode != nil else { return nil }

        // Prefer the modern `spend` object: it carries an explicit exponent per amount.
        var used = spendNode?["used"].flatMap(money(from:))
        var limit = spendNode?["limit"].flatMap(money(from:))

        // Fall back to `extra_usage`, whose amounts are minor units described by
        // `decimal_places`. This is the field v1 rendered 100x too large.
        if used == nil || limit == nil {
            let exponent = extraNode?["decimal_places"]?.intValue ?? 2
            let currency = extraNode?["currency"]?.stringValue ?? "USD"
            if used == nil, let u = extraNode?["used_credits"]?.doubleValue {
                used = Money(amountMinor: Int(u.rounded()), currency: currency, exponent: exponent)
            }
            if limit == nil, let l = extraNode?["monthly_limit"]?.doubleValue {
                limit = Money(amountMinor: Int(l.rounded()), currency: currency, exponent: exponent)
            }
        }

        let percent = spendNode?["percent"]?.doubleValue
            ?? extraNode?["utilization"]?.doubleValue
            ?? percentOf(used: used, limit: limit)

        let enabled = spendNode?["enabled"]?.boolValue
            ?? extraNode?["is_enabled"]?.boolValue
            ?? false

        let severity = spendNode?["severity"]?.stringValue.flatMap(Severity.init(rawValue:))
            ?? percent.map { Severity.from(percent: $0) }
            ?? .normal

        let info = SpendInfo(
            enabled: enabled,
            used: used,
            limit: limit,
            percent: percent,
            severity: severity,
            disabledReason: spendNode?["disabled_reason"]?.stringValue
                ?? extraNode?["disabled_reason"]?.stringValue,
            userDisabled: extraNode?["user_disabled"]?.boolValue,
            limitReached: extraNode?["spend_limit_reached"]?.boolValue,
            everEnabled: extraNode?["credits_ever_enabled"]?.boolValue,
            balance: spendNode?["balance"].flatMap(money(from:)),
            disclaimer: spendNode?["disclaimer"]?.stringValue
        )

        if used != nil && limit == nil {
            warnings.append("spend used present without a limit")
        }
        return info.isPresentable ? info : nil
    }

    private static func money(from node: JSONValue) -> Money? {
        guard let minor = node["amount_minor"]?.intValue else { return nil }
        return Money(
            amountMinor: minor,
            currency: node["currency"]?.stringValue ?? "USD",
            exponent: node["exponent"]?.intValue ?? 2
        )
    }

    private static func percentOf(used: Money?, limit: Money?) -> Double? {
        guard let used, let limit, limit.amount > 0 else { return nil }
        return used.amount / limit.amount * 100
    }
}

// MARK: - Profile parsing

public enum ProfileParser {
    public static func parse(_ root: JSONValue) -> AccountProfile {
        let org = root["organization"]
        let account = root["account"]

        let plan: String?
        if let type = org?["organization_type"]?.stringValue {
            plan = prettyPlan(type)
        } else if account?["has_claude_max"]?.boolValue == true {
            plan = "Max"
        } else if account?["has_claude_pro"]?.boolValue == true {
            plan = "Pro"
        } else {
            plan = nil
        }

        return AccountProfile(
            planLabel: plan,
            rateLimitTier: org?["rate_limit_tier"]?.stringValue,
            subscriptionStatus: org?["subscription_status"]?.stringValue,
            extraUsageAvailable: org?["has_extra_usage_enabled"]?.boolValue
        )
    }

    private static func prettyPlan(_ raw: String) -> String {
        switch raw {
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default: return raw.replacingOccurrences(of: "claude_", with: "").capitalizedFirst
        }
    }
}
