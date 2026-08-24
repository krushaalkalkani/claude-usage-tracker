import Foundation

public enum MenuBarDisplayMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case iconOnly = "icon"
    case percentOnly = "percent"
    case iconAndPercent = "both"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .percentOnly: return "Percentage only"
        case .iconAndPercent: return "Icon + percentage"
        }
    }
}

/// Which limit the menu bar number represents.
public enum PrimaryMetric: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Whichever limit is closest to its ceiling. The default, and the one that makes
    /// "5h = 25 %, 7d = 91 %" read correctly at a glance.
    case auto
    case session
    case weekly
    case highestModel = "model"
    case spend

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "Most constrained"
        case .session: return "Session (5-hour)"
        case .weekly: return "Weekly (7-day)"
        case .highestModel: return "Highest model limit"
        case .spend: return "Extra usage spend"
        }
    }
}

public enum RefreshInterval: Int, Sendable, Codable, CaseIterable, Identifiable {
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .thirtySeconds: return "30 seconds"
        case .oneMinute: return "1 minute"
        case .twoMinutes: return "2 minutes"
        case .fiveMinutes: return "5 minutes"
        }
    }
}

public enum HistoryRetention: Int, Sendable, Codable, CaseIterable, Identifiable {
    case day = 1
    case week = 7
    case month = 30

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .day: return "24 hours"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }

    public var duration: TimeInterval { TimeInterval(rawValue) * 86_400 }
}

public enum SparklineRange: String, Sendable, Codable, CaseIterable, Identifiable {
    case hour = "1h"
    case fiveHours = "5h"
    case day = "24h"
    case week = "7d"

    public var id: String { rawValue }

    public var duration: TimeInterval {
        switch self {
        case .hour: return 3_600
        case .fiveHours: return 18_000
        case .day: return 86_400
        case .week: return 604_800
        }
    }
}

/// Every user-tunable value. Plain `Codable` struct so the whole thing can be diffed, reset,
/// and unit-tested without touching `UserDefaults`.
public struct AppSettings: Sendable, Codable, Equatable {
    // General
    public var refreshInterval: RefreshInterval = .twoMinutes
    public var launchAtLogin: Bool = false
    public var dashboardURL: String = "https://claude-usage-tracker-xi.vercel.app"
    /// Persisted provider tab. Missing in older settings blobs, which therefore remain Claude.
    public var selectedProvider: UsageProvider = .claude

    // Menu bar
    public var displayMode: MenuBarDisplayMode = .iconOnly
    /// Raw value of `MenuBarIcon.Style`. Stored as a string so Core need not know about the
    /// app target's drawing code.
    public var menuBarIconStyle: String = "twinBars"
    /// Drop out of the menu bar while nothing is close to a limit.
    public var hideWhenHealthy: Bool = false
    /// …below this percentage. Above it the icon always returns.
    public var hideBelowPercent: Double = 50
    public var primaryMetric: PrimaryMetric = .auto
    /// Tint the icon orange/red at warning/critical. Off = always a monochrome template icon.
    public var tintIconOnAlert: Bool = true
    /// Append a one-character tag (W/M/$) when the shown number is not the session limit.
    public var showMetricTag: Bool = true

    // Thresholds (also drive local severity when the API sends none)
    public var warningThreshold: Double = 75
    public var criticalThreshold: Double = 90

    // Notifications
    public var notificationsEnabled: Bool = true
    public var usageThresholds: [Int] = [50, 75, 90, 95, 100]
    public var notifyOnReset: Bool = true
    public var notifyOnProjectedOverrun: Bool = true
    public var notifyOnSurge: Bool = true
    public var notifyOnAPIError: Bool = true
    public var notifyClaudeCodeAttention: Bool = true
    public var notifyClaudeCodeCompletion: Bool = true
    public var notifyClaudeCodeError: Bool = true
    /// A turn shorter than this never produces a "finished" notification.
    public var longTaskSeconds: Double = 60
    public var quietHoursEnabled: Bool = false
    /// Minutes from midnight, local time.
    public var quietHoursStart: Int = 22 * 60
    public var quietHoursEnd: Int = 8 * 60
    public var criticalBypassesQuietHours: Bool = true

    // History
    public var historyRetention: HistoryRetention = .week
    public var sparklineRange: SparklineRange = .fiveHours

    /// Show the per-project breakdown of where this window's quota went.
    public var showAttribution: Bool = true

    /// Show the "can I start a 30m task?" check under the hero.
    public var showRunwayCheck: Bool = true

    // Activity
    public var activityEnabled: Bool = true
    /// A busy session silent for longer than this is reported as unknown, not as working.
    public var activityStaleSeconds: Double = 600

    // Debug
    public var debugMode: Bool = false

    public init() {}

    /// Decodes field by field, falling back to the property's default when a key is absent.
    ///
    /// Swift's synthesized `init(from:)` ignores default values and throws on a missing key,
    /// which would mean that shipping a *new* setting silently discards every existing one.
    /// Reading each key with `decodeIfPresent` makes stored settings forward- and
    /// backward-compatible.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }

        refreshInterval = value(.refreshInterval, d.refreshInterval)
        launchAtLogin = value(.launchAtLogin, d.launchAtLogin)
        dashboardURL = value(.dashboardURL, d.dashboardURL)
        selectedProvider = value(.selectedProvider, d.selectedProvider)
        displayMode = value(.displayMode, d.displayMode)
        primaryMetric = value(.primaryMetric, d.primaryMetric)
        tintIconOnAlert = value(.tintIconOnAlert, d.tintIconOnAlert)
        showMetricTag = value(.showMetricTag, d.showMetricTag)
        warningThreshold = value(.warningThreshold, d.warningThreshold)
        criticalThreshold = value(.criticalThreshold, d.criticalThreshold)
        notificationsEnabled = value(.notificationsEnabled, d.notificationsEnabled)
        usageThresholds = value(.usageThresholds, d.usageThresholds)
        notifyOnReset = value(.notifyOnReset, d.notifyOnReset)
        notifyOnProjectedOverrun = value(.notifyOnProjectedOverrun, d.notifyOnProjectedOverrun)
        notifyOnSurge = value(.notifyOnSurge, d.notifyOnSurge)
        notifyOnAPIError = value(.notifyOnAPIError, d.notifyOnAPIError)
        notifyClaudeCodeAttention = value(.notifyClaudeCodeAttention, d.notifyClaudeCodeAttention)
        notifyClaudeCodeCompletion = value(.notifyClaudeCodeCompletion, d.notifyClaudeCodeCompletion)
        notifyClaudeCodeError = value(.notifyClaudeCodeError, d.notifyClaudeCodeError)
        longTaskSeconds = value(.longTaskSeconds, d.longTaskSeconds)
        quietHoursEnabled = value(.quietHoursEnabled, d.quietHoursEnabled)
        quietHoursStart = value(.quietHoursStart, d.quietHoursStart)
        quietHoursEnd = value(.quietHoursEnd, d.quietHoursEnd)
        criticalBypassesQuietHours = value(.criticalBypassesQuietHours, d.criticalBypassesQuietHours)
        historyRetention = value(.historyRetention, d.historyRetention)
        sparklineRange = value(.sparklineRange, d.sparklineRange)
        activityEnabled = value(.activityEnabled, d.activityEnabled)
        activityStaleSeconds = value(.activityStaleSeconds, d.activityStaleSeconds)
        debugMode = value(.debugMode, d.debugMode)
    }

    /// Thresholds, normalized: sorted, de-duplicated, and clamped to a sane range.
    public var normalizedThresholds: [Int] {
        Array(Set(usageThresholds.filter { $0 > 0 && $0 <= 200 })).sorted()
    }

    public func isWithinQuietHours(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if quietHoursStart == quietHoursEnd { return false }
        if quietHoursStart < quietHoursEnd {
            return minutes >= quietHoursStart && minutes < quietHoursEnd
        }
        // Window wraps midnight.
        return minutes >= quietHoursStart || minutes < quietHoursEnd
    }
}
