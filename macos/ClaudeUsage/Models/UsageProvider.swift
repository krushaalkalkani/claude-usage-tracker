import Foundation

/// Stable provider identity used in persisted history, caches, notification keys, and UI
/// selection. Raw values are a storage contract.
public enum UsageProvider: String, Sendable, Codable, CaseIterable, Identifiable, Hashable {
    case claude
    case chatgpt
    case cursor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .cursor: return "Cursor"
        }
    }

    public var headerTitle: String { "\(displayName) Usage" }

    /// One-character status-item label using the provider company, so no two providers can
    /// be mistaken for one another. Anthropic is omitted when it is the only live provider so
    /// the existing Claude-only menu-bar appearance stays unchanged.
    public var compactTag: String {
        switch self {
        case .claude: return "A"
        case .chatgpt: return "O"
        case .cursor: return "C"
        }
    }

    public var dashboardURL: URL {
        switch self {
        case .claude:
            return URL(string: "https://claude-usage-tracker-xi.vercel.app")!
        case .chatgpt:
            return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .cursor:
            return URL(string: "https://cursor.com/dashboard/spending")!
        }
    }

    public var allowanceDescription: String? {
        switch self {
        case .claude: return nil
        case .chatgpt: return "Codex / agentic allowance"
        case .cursor: return "Included usage + Grok Bot"
        }
    }
}

public enum ProviderConnectionState: String, Sendable, Codable, Equatable {
    case unknown
    case connected
    case authenticationRequired
    case unavailable
}

public enum ProviderDataSource: String, Sendable, Codable, Equatable {
    case anthropicOAuth
    case codexCLI
    case localCodexOAuth
    case cursorWebViewSession

    public var label: String {
        switch self {
        case .anthropicOAuth: return "Anthropic OAuth"
        case .codexCLI: return "Codex CLI"
        case .localCodexOAuth: return "Local Codex OAuth"
        case .cursorWebViewSession: return "Cursor session (WebView)"
        }
    }
}

/// Provider-local state. It deliberately has no SwiftUI import so isolation and migration
/// decisions can be tested in `ClaudeUsageCore`.
public struct ProviderUsageState: Sendable, Equatable {
    public let provider: UsageProvider
    public var snapshot: UsageSnapshot?
    public var planLabel: String?
    public var lastSuccessAt: Date?
    public var lastError: UsageAPIError?
    public var isShowingCachedData: Bool
    public var isRefreshing: Bool
    public var projections: [String: UsageProjection]
    public var samples: [UsageSample]
    public var surgingLimitIDs: Set<String>
    public var weeklyAveragePerDay: Double?
    public var connectionState: ProviderConnectionState
    public var dataSource: ProviderDataSource?
    /// A local credential was found without needing a live fetch. Populated by ChatGPT (Codex
    /// CLI on PATH) and reused as-is by Cursor (a session cookie already sitting in Keychain);
    /// the name predates Cursor and is kept for storage/decoding compatibility.
    public var cliDetected: Bool?
    public var consecutiveFailures: Int
    public var nextRetryAt: Date?

    public init(provider: UsageProvider) {
        self.provider = provider
        self.snapshot = nil
        self.planLabel = nil
        self.lastSuccessAt = nil
        self.lastError = nil
        self.isShowingCachedData = false
        self.isRefreshing = false
        self.projections = [:]
        self.samples = []
        self.surgingLimitIDs = []
        self.weeklyAveragePerDay = nil
        self.connectionState = .unknown
        self.dataSource = nil
        self.cliDetected = nil
        self.consecutiveFailures = 0
        self.nextRetryAt = nil
    }

    /// Last-known-good data remains visible after a failure, but it is never considered a
    /// current number for the provider switcher or overall menu-bar selection.
    public func hasCurrentData(now: Date, refreshInterval: TimeInterval) -> Bool {
        guard snapshot?.bottleneck != nil, lastError == nil, !isShowingCachedData,
              let lastSuccessAt
        else { return false }
        return now.timeIntervalSince(lastSuccessAt) <= refreshInterval * 3
    }
}

public struct MenuBarUsageMetric: Sendable, Equatable {
    public let provider: UsageProvider
    public let limit: LimitWindow?
    public let percent: Double
    public let severity: Severity
    public let limitTag: String?

    public init(
        provider: UsageProvider,
        limit: LimitWindow?,
        percent: Double,
        severity: Severity,
        limitTag: String?
    ) {
        self.provider = provider
        self.limit = limit
        self.percent = percent
        self.severity = severity
        self.limitTag = limitTag
    }
}

public enum MenuBarMetricPolicy {
    /// Returns the selected provider's configured metric. The other provider never replaces
    /// it merely because its percentage is tighter.
    public static func selected(
        provider: UsageProvider,
        states: [UsageProvider: ProviderUsageState],
        primaryMetric: PrimaryMetric,
        now: Date,
        refreshInterval: TimeInterval
    ) -> MenuBarUsageMetric? {
        guard let state = states[provider],
              state.hasCurrentData(now: now, refreshInterval: refreshInterval),
              let snapshot = state.snapshot
        else { return nil }

        if primaryMetric == .spend, let percent = snapshot.spend?.percent {
            return MenuBarUsageMetric(
                provider: provider,
                limit: nil,
                percent: percent,
                severity: snapshot.spend?.severity ?? .normal,
                limitTag: "$"
            )
        }

        let limit: LimitWindow?
        switch primaryMetric {
        case .auto: limit = snapshot.bottleneck
        case .session: limit = snapshot.sessionLimit ?? snapshot.bottleneck
        case .weekly: limit = snapshot.weeklyLimit ?? snapshot.bottleneck
        case .highestModel: limit = snapshot.modelLimits.first ?? snapshot.bottleneck
        case .spend: limit = snapshot.bottleneck
        }
        guard let limit else { return nil }

        let tag: String?
        if limit.isModelScoped { tag = "M" }
        else if limit.group == .weekly { tag = "W" }
        else if limit.group == .other { tag = "•" }
        else { tag = nil }
        return MenuBarUsageMetric(
            provider: provider,
            limit: limit,
            percent: limit.percent,
            severity: limit.severity,
            limitTag: tag
        )
    }
}

public struct ProviderLimitSelection: Sendable, Equatable {
    public let provider: UsageProvider
    public let limit: LimitWindow

    public init(provider: UsageProvider, limit: LimitWindow) {
        self.provider = provider
        self.limit = limit
    }
}

public enum ProviderUsageSelection {
    /// Selects the tightest real window across the supplied live provider snapshots.
    public static func tightest(
        snapshots: [UsageProvider: UsageSnapshot],
        availableProviders: Set<UsageProvider>? = nil
    ) -> ProviderLimitSelection? {
        snapshots.compactMap { provider, snapshot -> ProviderLimitSelection? in
            if let availableProviders, !availableProviders.contains(provider) { return nil }
            guard let limit = snapshot.bottleneck else { return nil }
            return ProviderLimitSelection(provider: provider, limit: limit)
        }.max { a, b in
            if abs(a.limit.percent - b.limit.percent) < 1,
               a.limit.isActive != b.limit.isActive {
                return b.limit.isActive
            }
            return a.limit.percent < b.limit.percent
        }
    }
}


extension LimitWindow {
    /// Unique across providers. `id` alone is not: `weekly_all` exists on Claude and ChatGPT
    /// alike, so using it as a `ForEach` identity collapses the two into one row.
    public var rowKey: String { "\(provider.rawValue)#\(id)" }
}
