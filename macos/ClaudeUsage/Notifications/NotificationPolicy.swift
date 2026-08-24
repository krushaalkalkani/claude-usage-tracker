import Foundation

/// The kind of thing we are telling the user about. Each category carries its own cooldown so
/// a noisy category can never drown out a quiet one.
public enum NotificationCategory: String, Sendable, Codable, CaseIterable {
    case usageThreshold
    case quotaReset
    case projectedOverrun
    case usageSurge
    case apiAuth
    case apiUnavailable
    case apiRateLimited
    case claudeAttention
    case claudeCompleted
    case claudeError

    var defaultCooldown: TimeInterval {
        switch self {
        // Attention alerts are the point of the app — a short cooldown, but still a cooldown.
        case .claudeAttention: return 120
        case .claudeCompleted: return 60
        case .claudeError: return 300
        case .usageThreshold, .quotaReset: return 0  // deduped by key instead
        case .projectedOverrun, .usageSurge: return 1_800
        case .apiAuth: return 3_600
        case .apiUnavailable: return 1_800
        case .apiRateLimited: return 900
        }
    }
}

public struct PendingNotification: Sendable, Equatable, Identifiable {
    public let id: String
    public let category: NotificationCategory
    public let title: String
    public let body: String
    public let severity: Severity
    /// Narrows this notification's cooldown to a provider or Claude Code session id so
    /// unrelated sources never silence each other.
    public let cooldownScope: String?

    public init(
        id: String,
        category: NotificationCategory,
        title: String,
        body: String,
        severity: Severity,
        cooldownScope: String? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.body = body
        self.severity = severity
        self.cooldownScope = cooldownScope
    }
}

/// Remembers what has already been said. Persisted so a restart does not re-announce
/// everything the user already saw.
public struct NotificationLedger: Sendable, Codable, Equatable {
    /// Dedup keys that have fired, e.g. `session|2026-08-08T20:00:00Z|90`.
    public var firedKeys: Set<String> = []
    /// Last delivery time per category, for cooldowns.
    public var lastFired: [String: Date] = [:]
    /// Last seen reset instant per limit, used to detect a new window.
    public var lastResetSeen: [String: Date] = [:]
    /// Percent at the previous evaluation, used to detect a reset when no reset time exists.
    public var lastPercent: [String: Double] = [:]
    /// Turn ids already announced as completed, so a re-read of the same session file is quiet.
    public var announcedCompletions: Set<String> = []
    /// Attention states already announced, keyed by session + reason.
    public var announcedAttention: Set<String> = []
    /// Consecutive API failures, so we only complain once the problem looks real.
    /// Kept as the legacy Claude value for backward-compatible decoding and tests.
    public var consecutiveFailures: Int = 0
    /// Provider-specific replacement for `consecutiveFailures`.
    public var consecutiveFailuresByProvider: [String: Int] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case firedKeys, lastFired, lastResetSeen, lastPercent
        case announcedCompletions, announcedAttention
        case consecutiveFailures, consecutiveFailuresByProvider
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firedKeys = try c.decodeIfPresent(Set<String>.self, forKey: .firedKeys) ?? []
        lastFired = try c.decodeIfPresent([String: Date].self, forKey: .lastFired) ?? [:]
        lastResetSeen = try c.decodeIfPresent([String: Date].self, forKey: .lastResetSeen) ?? [:]
        lastPercent = try c.decodeIfPresent([String: Double].self, forKey: .lastPercent) ?? [:]
        announcedCompletions = try c.decodeIfPresent(Set<String>.self, forKey: .announcedCompletions) ?? []
        announcedAttention = try c.decodeIfPresent(Set<String>.self, forKey: .announcedAttention) ?? []
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        consecutiveFailuresByProvider = try c.decodeIfPresent(
            [String: Int].self, forKey: .consecutiveFailuresByProvider
        ) ?? [:]

        // v2 keys had no provider. Migrate them in memory as Claude without deleting or
        // resetting any prior notification bookkeeping.
        firedKeys = Set(firedKeys.map { $0.contains("#") ? $0 : "claude#\($0)" })
        lastResetSeen = Self.migrateProviderKeys(lastResetSeen)
        lastPercent = Self.migrateProviderKeys(lastPercent)

        let providerCooldownCategories: Set<String> = [
            NotificationCategory.usageThreshold.rawValue,
            NotificationCategory.quotaReset.rawValue,
            NotificationCategory.projectedOverrun.rawValue,
            NotificationCategory.usageSurge.rawValue,
            NotificationCategory.apiAuth.rawValue,
            NotificationCategory.apiUnavailable.rawValue,
            NotificationCategory.apiRateLimited.rawValue,
        ]
        var migratedLastFired = lastFired.filter { !providerCooldownCategories.contains($0.key) }
        for (key, value) in lastFired where providerCooldownCategories.contains(key) {
            if migratedLastFired["\(key)#claude"] == nil {
                migratedLastFired["\(key)#claude"] = value
            }
        }
        lastFired = migratedLastFired
        if consecutiveFailuresByProvider[UsageProvider.claude.rawValue] == nil {
            consecutiveFailuresByProvider[UsageProvider.claude.rawValue] = consecutiveFailures
        }
    }

    private static func migrateProviderKeys<Value>(_ source: [String: Value]) -> [String: Value] {
        var migrated = source.filter { $0.key.contains("#") }
        for (key, value) in source where !key.contains("#") {
            let qualified = "claude#\(key)"
            if migrated[qualified] == nil { migrated[qualified] = value }
        }
        return migrated
    }

    mutating func setFailureCount(_ value: Int, for provider: UsageProvider) {
        consecutiveFailuresByProvider[provider.rawValue] = value
        if provider == .claude { consecutiveFailures = value }
    }

    func failureCount(for provider: UsageProvider) -> Int {
        consecutiveFailuresByProvider[provider.rawValue]
            ?? (provider == .claude ? consecutiveFailures : 0)
    }

    mutating func prune(now: Date, keep: TimeInterval = 14 * 86_400) {
        let cutoff = now.addingTimeInterval(-keep)
        lastFired = lastFired.filter { $0.value >= cutoff }
        lastResetSeen = lastResetSeen.filter { $0.value >= cutoff }
        // Threshold keys embed the window's reset instant; drop the ones whose window is past.
        firedKeys = firedKeys.filter { key in
            guard let stamp = key.split(separator: "|").dropFirst().first,
                  let date = ISO8601.parse(String(stamp))
            else { return true }
            return date >= cutoff
        }
        if announcedCompletions.count > 200 { announcedCompletions = [] }
        if announcedAttention.count > 200 { announcedAttention = [] }
    }
}

/// Everything the policy needs to decide. Passing this in rather than reaching for globals is
/// what makes the whole decision surface unit-testable.
public struct PolicyContext: Sendable {
    public let provider: UsageProvider
    public let now: Date
    public let settings: AppSettings
    public let snapshot: UsageSnapshot?
    public let projections: [String: UsageProjection]
    public let surgingLimitIDs: Set<String>
    public let activity: ActivityState?
    public let apiError: UsageAPIError?
    /// True when the most recent fetch succeeded.
    public let apiHealthy: Bool

    public init(
        now: Date,
        settings: AppSettings,
        snapshot: UsageSnapshot?,
        provider: UsageProvider = .claude,
        projections: [String: UsageProjection] = [:],
        surgingLimitIDs: Set<String> = [],
        activity: ActivityState? = nil,
        apiError: UsageAPIError? = nil,
        apiHealthy: Bool = true
    ) {
        self.provider = provider
        self.now = now
        self.settings = settings
        self.snapshot = snapshot
        self.projections = projections
        self.surgingLimitIDs = surgingLimitIDs
        self.activity = activity
        self.apiError = apiError
        self.apiHealthy = apiHealthy
    }
}

/// Decides what, if anything, to tell the user. Pure: same inputs, same outputs, no clock, no
/// filesystem, no notification centre.
public enum NotificationPolicy {

    public static func evaluate(
        _ context: PolicyContext,
        ledger: inout NotificationLedger
    ) -> [PendingNotification] {
        ledger.prune(now: context.now)

        guard context.settings.notificationsEnabled else {
            // Still track state so re-enabling later does not replay history.
            trackWindows(context, ledger: &ledger)
            return []
        }

        var out: [PendingNotification] = []
        out += usageNotifications(context, ledger: &ledger)
        out += apiNotifications(context, ledger: &ledger)
        if context.provider == .claude {
            out += activityNotifications(context, ledger: &ledger)
        }

        // Quiet hours filter last so all the bookkeeping above still happens.
        let allowed = out.filter { candidate in
            guard context.settings.isWithinQuietHours(context.now) else { return true }
            return context.settings.criticalBypassesQuietHours && candidate.severity == .critical
        }

        // Record delivery times only for what actually goes out.
        for note in allowed {
            ledger.lastFired[cooldownKey(note.category, note.cooldownScope)] = context.now
        }
        return allowed
    }

    // MARK: usage

    private static func usageNotifications(
        _ context: PolicyContext,
        ledger: inout NotificationLedger
    ) -> [PendingNotification] {
        guard let snapshot = context.snapshot else { return [] }
        var out: [PendingNotification] = []
        let thresholds = context.settings.normalizedThresholds

        for limit in snapshot.limits {
            let ledgerLimitID = "\(context.provider.rawValue)#\(limit.id)"
            // Bucketed to the minute. The reset instant must never be used at full precision
            // in a dedup key: the API jitters its fractional seconds on every response, so a
            // key built from the raw value is unique every poll and dedups nothing.
            let windowKey = limit.resetsAt
                .map { ISO8601.string(from: Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded(.down) * 60)) }
                ?? "nowindow"
            let previousReset = ledger.lastResetSeen[ledgerLimitID]
            let previousPercent = ledger.lastPercent[ledgerLimitID]

            // A quota window has rolled over only when utilisation actually **falls**.
            //
            // This used to trigger on `resets_at` moving forward, which looked reasonable and
            // was completely wrong: that timestamp advances on every single response, so the
            // app announced "Weekly quota reset — was 39%, now 39%" every couple of minutes
            // and re-armed every usage threshold behind it. A timestamp is corroboration; the
            // drop is the evidence.
            let dropped = previousPercent.map { $0 - limit.percent > 5 } ?? false
            let resetMovedMaterially: Bool = {
                guard let resetsAt = limit.resetsAt, let previousReset else { return true }
                // Real rollovers move the boundary by hours or days, never by seconds.
                return resetsAt.timeIntervalSince(previousReset) > 300
            }()
            let resetDetected = dropped && resetMovedMaterially

            if resetDetected {
                // Re-arm every threshold for the new window.
                ledger.firedKeys = ledger.firedKeys.filter { !$0.hasPrefix("\(ledgerLimitID)|") }

                if context.settings.notifyOnReset, let previousPercent, previousPercent >= 25 {
                    out.append(
                        PendingNotification(
                            id: "reset|\(ledgerLimitID)|\(windowKey)",
                            category: .quotaReset,
                            title: "\(context.provider.displayName) · \(limit.shortTitle) quota reset",
                            body: "Was \(Format.percent(previousPercent)) — now \(Format.percent(limit.percent)).",
                            severity: .normal,
                            cooldownScope: context.provider.rawValue
                        )
                    )
                }
            }

            // Threshold crossings. The key embeds the window so each window announces once.
            for threshold in thresholds where limit.percent >= Double(threshold) {
                let key = "\(ledgerLimitID)|\(windowKey)|\(threshold)"
                guard !ledger.firedKeys.contains(key) else { continue }
                // Only announce the highest threshold crossed in one evaluation — jumping
                // 40 % → 96 % should produce one notification, not four.
                let higherPending = thresholds.contains {
                    $0 > threshold && limit.percent >= Double($0)
                        && !ledger.firedKeys.contains("\(ledgerLimitID)|\(windowKey)|\($0)")
                }
                ledger.firedKeys.insert(key)
                guard !higherPending else { continue }

                let severity: Severity = threshold >= 95 ? .critical : threshold >= 75 ? .warning : .normal
                var body = "\(Format.percent(limit.remainingPercent)) remaining"
                if let until = limit.timeUntilReset(now: context.now) {
                    body += " · resets in \(Format.duration(until))"
                }
                out.append(
                    PendingNotification(
                        id: key,
                        category: .usageThreshold,
                        title: "\(context.provider.displayName) · \(limit.shortTitle) at \(threshold)%",
                        body: body,
                        severity: severity,
                        cooldownScope: context.provider.rawValue
                    )
                )
            }

            // Projected to run out before the window resets.
            if context.settings.notifyOnProjectedOverrun,
               let projection = context.projections[limit.id],
               projection.willExhaustBeforeReset,
               let eta = projection.timeToExhaustion,
               let rate = projection.burnRate,
               // Only when the estimate is grounded: enough samples and a coherent trend.
               rate.sampleCount >= 4, rate.fitQuality >= 0.5, limit.percent < 100,
               allowed(
                   .projectedOverrun, ledger: ledger, now: context.now,
                   scope: context.provider.rawValue
               ) {
                out.append(
                    PendingNotification(
                        id: "projected|\(ledgerLimitID)|\(windowKey)",
                        category: .projectedOverrun,
                        title: "\(context.provider.displayName) · \(limit.shortTitle) projected to run out",
                        body: "At \(Format.rate(rate.perHour)) you hit 100% in \(Format.duration(eta)), before the reset.",
                        severity: .warning,
                        cooldownScope: context.provider.rawValue
                    )
                )
            }

            // Sudden acceleration.
            if context.settings.notifyOnSurge,
               context.surgingLimitIDs.contains(limit.id),
               limit.percent >= 40,
               allowed(
                   .usageSurge, ledger: ledger, now: context.now,
                   scope: context.provider.rawValue
               ) {
                out.append(
                    PendingNotification(
                        id: "surge|\(ledgerLimitID)|\(windowKey)",
                        category: .usageSurge,
                        title: "\(context.provider.displayName) · \(limit.shortTitle) climbing fast",
                        body: "Now \(Format.percent(limit.percent)) and accelerating.",
                        severity: .warning,
                        cooldownScope: context.provider.rawValue
                    )
                )
            }

            ledger.lastResetSeen[ledgerLimitID] = limit.resetsAt
            ledger.lastPercent[ledgerLimitID] = limit.percent
        }
        return out
    }

    /// Keeps window bookkeeping current while notifications are switched off, so turning them
    /// back on does not produce a burst of stale alerts.
    private static func trackWindows(_ context: PolicyContext, ledger: inout NotificationLedger) {
        guard let snapshot = context.snapshot else { return }
        for limit in snapshot.limits {
            let key = "\(context.provider.rawValue)#\(limit.id)"
            ledger.lastResetSeen[key] = limit.resetsAt
            ledger.lastPercent[key] = limit.percent
        }
    }

    // MARK: API health

    private static func apiNotifications(
        _ context: PolicyContext,
        ledger: inout NotificationLedger
    ) -> [PendingNotification] {
        guard context.settings.notifyOnAPIError else {
            if context.apiHealthy { ledger.setFailureCount(0, for: context.provider) }
            return []
        }

        guard let error = context.apiError, !context.apiHealthy else {
            ledger.setFailureCount(0, for: context.provider)
            return []
        }

        let failures = ledger.failureCount(for: context.provider) + 1
        ledger.setFailureCount(failures, for: context.provider)
        let providerScope = context.provider.rawValue

        switch error {
        case .unauthorized, .forbidden, .missingToken, .codexAuthenticationRequired, .cliNotFound:
            guard allowed(
                .apiAuth, ledger: ledger, now: context.now, scope: providerScope
            ) else { return [] }
            return [
                PendingNotification(
                    id: "api-auth|\(providerScope)",
                    category: .apiAuth,
                    title: "\(context.provider.displayName) · \(error.title(for: context.provider))",
                    body: error.detail(for: context.provider),
                    severity: .warning,
                    cooldownScope: providerScope
                )
            ]

        case .rateLimited:
            guard allowed(
                .apiRateLimited, ledger: ledger, now: context.now, scope: providerScope
            ) else { return [] }
            return [
                PendingNotification(
                    id: "api-rate-limited|\(providerScope)",
                    category: .apiRateLimited,
                    title: "\(context.provider.displayName) · Usage service rate limited",
                    body: error.detail(for: context.provider),
                    severity: .normal,
                    cooldownScope: providerScope
                )
            ]

        default:
            // A single blip is not news. Speak up only once it looks persistent.
            guard failures >= 3,
                  allowed(
                      .apiUnavailable, ledger: ledger, now: context.now, scope: providerScope
                  )
            else { return [] }
            return [
                PendingNotification(
                    id: "api-unavailable|\(providerScope)",
                    category: .apiUnavailable,
                    title: "\(context.provider.displayName) · Usage data unavailable",
                    body: "\(error.title(for: context.provider)). Showing the last known values.",
                    severity: .normal,
                    cooldownScope: providerScope
                )
            ]
        }
    }

    // MARK: Claude Code

    private static func activityNotifications(
        _ context: PolicyContext,
        ledger: inout NotificationLedger
    ) -> [PendingNotification] {
        guard let activity = context.activity, activity.hookInstalled else { return [] }
        var out: [PendingNotification] = []

        for session in activity.sessions {
            let name = session.displayName

            // Needs attention. The key deliberately excludes any timestamp: one alert per
            // attention *episode*. Including `lastEventAt` meant the key changed with every
            // hook event, so a session parked on a permission prompt re-announced itself
            // every time the cooldown lapsed.
            let attentionPrefix = "attention|\(session.sessionId)|"
            if !session.needsAttention {
                // Episode over — forget it so the next genuine one can speak up.
                ledger.announcedAttention = ledger.announcedAttention.filter {
                    !$0.hasPrefix(attentionPrefix)
                }
            }
            if session.needsAttention, context.settings.notifyClaudeCodeAttention {
                let reason = session.attentionReason ?? session.status.displayName
                let key = attentionPrefix + reason
                if !ledger.announcedAttention.contains(key),
                   allowed(.claudeAttention, ledger: ledger, now: context.now, scope: session.sessionId) {
                    ledger.announcedAttention.insert(key)
                    out.append(
                        PendingNotification(
                            id: key,
                            category: .claudeAttention,
                            title: "Claude Code · \(name)",
                            body: reason,
                            severity: session.status == .permissionRequired ? .warning : .normal,
                            cooldownScope: session.sessionId
                        )
                    )
                }
            }

            // Turn finished, but only if it ran long enough to be worth interrupting for.
            if context.settings.notifyClaudeCodeCompletion,
               session.status == .completed,
               let completedAt = session.lastCompletedAt,
               let duration = session.lastTurnSeconds,
               duration >= context.settings.longTaskSeconds {
                let key = "done|\(session.sessionId)|\(ISO8601.string(from: completedAt))"
                if !ledger.announcedCompletions.contains(key),
                   allowed(.claudeCompleted, ledger: ledger, now: context.now, scope: session.sessionId) {
                    ledger.announcedCompletions.insert(key)
                    var body = "Finished after \(Format.duration(duration))"
                    if session.openTasks > 0 { body += " · \(session.openTasks) task(s) open" }
                    out.append(
                        PendingNotification(
                            id: key,
                            category: .claudeCompleted,
                            title: "Claude Code finished · \(name)",
                            body: body,
                            severity: .normal,
                            cooldownScope: session.sessionId
                        )
                    )
                }
            }

            // Errors and rate limits. Same rule as attention: one alert per episode, keyed by
            // the state rather than by the last event's timestamp.
            let errorPrefix = "err|\(session.sessionId)|"
            let inErrorState = session.status == .error || session.status == .rateLimited
            if !inErrorState {
                ledger.announcedAttention = ledger.announcedAttention.filter {
                    !$0.hasPrefix(errorPrefix)
                }
            }
            if context.settings.notifyClaudeCodeError, inErrorState {
                let key = errorPrefix + session.status.rawValue
                if !ledger.announcedAttention.contains(key),
                   allowed(.claudeError, ledger: ledger, now: context.now, scope: session.sessionId) {
                    ledger.announcedAttention.insert(key)
                    out.append(
                        PendingNotification(
                            id: key,
                            category: .claudeError,
                            title: session.status == .rateLimited
                                ? "Claude Code rate limited · \(name)"
                                : "Claude Code error · \(name)",
                            body: session.lastError.map { "Last: \($0)" } ?? session.status.displayName,
                            severity: .warning,
                            cooldownScope: session.sessionId
                        )
                    )
                }
            }
        }
        return out
    }

    // MARK: cooldown

    /// - Parameter scope: an optional sub-key so a cooldown can apply per Claude Code session
    ///   rather than across all of them. Two projects blocking on a permission prompt at the
    ///   same moment should both be announced; the cooldown is there to stop *one* session
    ///   repeating itself, not to hide the second project.
    private static func allowed(
        _ category: NotificationCategory,
        ledger: NotificationLedger,
        now: Date,
        scope: String? = nil,
        cooldown: TimeInterval? = nil
    ) -> Bool {
        let window = cooldown ?? category.defaultCooldown
        guard window > 0 else { return true }
        guard let last = ledger.lastFired[cooldownKey(category, scope)] else { return true }
        return now.timeIntervalSince(last) >= window
    }

    static func cooldownKey(_ category: NotificationCategory, _ scope: String?) -> String {
        guard let scope else { return category.rawValue }
        return "\(category.rawValue)#\(scope)"
    }
}

/// Shared, locale-light formatting used in both notifications and the popover.
public enum Format {
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    public static func rate(_ perHour: Double) -> String {
        if perHour >= 10 { return "\(Int(perHour.rounded()))%/h" }
        return String(format: "%.1f%%/h", perHour)
    }

    /// Compact durations: `45s`, `12m`, `2h 28m`, `5d 2h`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        if hours < 24 { return remMinutes > 0 ? "\(hours)h \(remMinutes)m" : "\(hours)h" }
        let days = hours / 24
        let remHours = hours % 24
        return remHours > 0 ? "\(days)d \(remHours)h" : "\(days)d"
    }

    /// "just now", "12s ago", "4m ago".
    public static func relativeAge(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "just now" }
        return "\(duration(seconds)) ago"
    }
}

/// Loads and saves the ledger. Separate from the policy so the policy stays pure.
public enum NotificationLedgerStore {
    public static func load(url: URL = AppPaths.notificationLedgerFile) -> NotificationLedger {
        guard let data = AtomicFile.read(url),
              let ledger = try? JSONDecoder.store.decode(NotificationLedger.self, from: data)
        else { return NotificationLedger() }
        return ledger
    }

    public static func save(_ ledger: NotificationLedger, url: URL = AppPaths.notificationLedgerFile) {
        guard let data = try? JSONEncoder.store.encode(ledger) else { return }
        try? AtomicFile.write(data, to: url)
    }
}
