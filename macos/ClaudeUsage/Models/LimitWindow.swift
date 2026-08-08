import Foundation

/// How urgent a value is. The server sends its own `severity` on some payloads; when it does
/// we prefer it, because the server knows about plan-specific thresholds we do not.
public enum Severity: String, Sendable, Codable, CaseIterable, Comparable {
    case normal
    case warning
    case critical

    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }

    private var rank: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    /// Local fallback when the payload carries no severity.
    public static func from(percent: Double, warningAt: Double = 75, criticalAt: Double = 90) -> Severity {
        if percent >= criticalAt { return .critical }
        if percent >= warningAt { return .warning }
        return .normal
    }
}

/// What kind of quota window this is. Unknown kinds are preserved verbatim so a new limit
/// type the API introduces still renders instead of vanishing.
public enum LimitGroup: String, Sendable, Codable {
    case session
    case weekly
    case other
}

/// One normalized quota window, whatever shape the API delivered it in.
public struct LimitWindow: Sendable, Codable, Identifiable, Equatable {
    /// Stable identity used for history keys and notification dedup.
    public let id: String
    /// Raw `kind` from the API (`session`, `weekly_all`, `weekly_scoped`, …) or a synthesized
    /// one for legacy top-level keys.
    public let kind: String
    public let group: LimitGroup
    /// Human title, e.g. "5-hour limit", "7-day limit", "Fable · weekly".
    public let title: String
    /// Short label for compact contexts, e.g. "Session", "Weekly", "Fable".
    public let shortTitle: String
    public let percent: Double
    public let resetsAt: Date?
    public let severity: Severity
    /// The API's `is_active` — the limit currently in force for the session.
    public let isActive: Bool
    /// Populated only for model-scoped limits.
    public let modelName: String?
    public let modelID: String?
    /// Populated only for surface-scoped limits (e.g. Cowork).
    public let surface: String?
    /// Dollar figures, when the plan exposes them. Usually nil on subscription plans.
    public let usedDollars: Double?
    public let limitDollars: Double?
    public let remainingDollars: Double?

    public init(
        id: String,
        kind: String,
        group: LimitGroup,
        title: String,
        shortTitle: String,
        percent: Double,
        resetsAt: Date?,
        severity: Severity,
        isActive: Bool = false,
        modelName: String? = nil,
        modelID: String? = nil,
        surface: String? = nil,
        usedDollars: Double? = nil,
        limitDollars: Double? = nil,
        remainingDollars: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.group = group
        self.title = title
        self.shortTitle = shortTitle
        self.percent = percent
        self.resetsAt = resetsAt
        self.severity = severity
        self.isActive = isActive
        self.modelName = modelName
        self.modelID = modelID
        self.surface = surface
        self.usedDollars = usedDollars
        self.limitDollars = limitDollars
        self.remainingDollars = remainingDollars
    }

    public var remainingPercent: Double { max(0, 100 - percent) }

    /// True when this window is scoped to a specific model — the "model limits" section.
    public var isModelScoped: Bool { modelName != nil }

    public func timeUntilReset(now: Date) -> TimeInterval? {
        guard let resetsAt else { return nil }
        return max(0, resetsAt.timeIntervalSince(now))
    }
}

/// A money amount that always respects the exponent the API sent.
///
/// This exists because the v1 dashboard divided nothing at all and rendered
/// `used_credits: 3303` as "$3303.00" when it means **$33.03**. Minor units are never
/// converted by a bare `/ 100` anywhere in this codebase.
public struct Money: Sendable, Codable, Equatable {
    public let amountMinor: Int
    public let currency: String
    public let exponent: Int

    public init(amountMinor: Int, currency: String = "USD", exponent: Int = 2) {
        self.amountMinor = amountMinor
        self.currency = currency
        self.exponent = max(0, min(exponent, 6))
    }

    public var amount: Double {
        Double(amountMinor) / pow(10.0, Double(exponent))
    }

    public var formatted: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.minimumFractionDigits = exponent
        f.maximumFractionDigits = exponent
        return f.string(from: NSNumber(value: amount)) ?? "\(amount) \(currency)"
    }
}

/// Extra-usage / spend state, merged from the modern `spend` object and the older
/// `extra_usage` object. Only fields the API actually returned are populated.
public struct SpendInfo: Sendable, Codable, Equatable {
    public let enabled: Bool
    public let used: Money?
    public let limit: Money?
    public let percent: Double?
    public let severity: Severity
    public let disabledReason: String?
    public let userDisabled: Bool?
    public let limitReached: Bool?
    public let everEnabled: Bool?
    public let balance: Money?
    public let disclaimer: String?

    public init(
        enabled: Bool,
        used: Money?,
        limit: Money?,
        percent: Double?,
        severity: Severity,
        disabledReason: String?,
        userDisabled: Bool?,
        limitReached: Bool?,
        everEnabled: Bool?,
        balance: Money?,
        disclaimer: String?
    ) {
        self.enabled = enabled
        self.used = used
        self.limit = limit
        self.percent = percent
        self.severity = severity
        self.disabledReason = disabledReason
        self.userDisabled = userDisabled
        self.limitReached = limitReached
        self.everEnabled = everEnabled
        self.balance = balance
        self.disclaimer = disclaimer
    }

    /// Amount over the cap, when both figures are present and the cap is exceeded.
    public var overage: Money? {
        guard let used, let limit, used.amountMinor > limit.amountMinor,
              used.exponent == limit.exponent, used.currency == limit.currency
        else { return nil }
        return Money(
            amountMinor: used.amountMinor - limit.amountMinor,
            currency: used.currency,
            exponent: used.exponent
        )
    }

    /// Whether this is worth showing at all. An account that has never touched extra usage
    /// gets no section rather than an empty one.
    public var isPresentable: Bool {
        enabled || (everEnabled ?? false) || used != nil || limit != nil
    }

    /// A short human explanation of `disabled_reason`, without inventing meanings for codes
    /// we do not recognize.
    public var disabledExplanation: String? {
        guard !enabled, let reason = disabledReason else { return nil }
        switch reason {
        case "org_level_disabled_until": return "Disabled by organization"
        case "user_disabled": return "Turned off"
        case "spend_limit_reached": return "Monthly cap reached"
        default: return reason.replacingOccurrences(of: "_", with: " ").capitalizedFirst
        }
    }
}

/// Plan / account metadata from `/api/oauth/profile`. Deliberately excludes email, names,
/// and every UUID — none of it is needed to show usage.
public struct AccountProfile: Sendable, Codable, Equatable {
    public let planLabel: String?
    public let rateLimitTier: String?
    public let subscriptionStatus: String?
    public let extraUsageAvailable: Bool?

    public init(
        planLabel: String?,
        rateLimitTier: String?,
        subscriptionStatus: String?,
        extraUsageAvailable: Bool?
    ) {
        self.planLabel = planLabel
        self.rateLimitTier = rateLimitTier
        self.subscriptionStatus = subscriptionStatus
        self.extraUsageAvailable = extraUsageAvailable
    }
}

extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}
