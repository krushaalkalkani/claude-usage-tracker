import Foundation
import Observation
import SwiftUI
import ClaudeUsageCore

/// Everything the views read, and the single place polling is scheduled.
///
/// `@MainActor` throughout: the refresh loop is one `Task`, and there is exactly one of it, so
/// there is no window in which two fetches can interleave and write state out of order.
@MainActor
@Observable
public final class AppModel {

    // MARK: Published state

    public private(set) var snapshot: UsageSnapshot?
    public private(set) var profile: AccountProfile?
    public private(set) var activity: ActivityState = .unavailable
    public private(set) var samples: [UsageSample] = []
    /// Recomputed once per poll — see `recomputeAnalytics()`.
    public private(set) var projections: [String: UsageProjection] = [:]
    public private(set) var surgingLimitIDs: Set<String> = []
    public private(set) var weeklyAveragePerDay: Double?
    public private(set) var lastError: UsageAPIError?
    /// True while a fetch is in flight.
    public private(set) var isRefreshing = false
    /// When the last *successful* fetch landed. Drives "Updated N ago" and staleness.
    public private(set) var lastSuccessAt: Date?
    /// Set when the displayed snapshot came from disk rather than this session's network.
    public private(set) var isShowingCachedData = false
    public private(set) var tokenSource: TokenSource?
    /// Credential sources the server rejected this run.
    ///
    /// In memory only, and cleared by a manual refresh or by saving a token, so
    /// re-authenticating elsewhere (Claude Code, say) gets another chance without a
    /// relaunch. Persisting it would mean a fixed credential stayed shunned forever.
    private var rejectedSources: Set<TokenSource> = []
    public private(set) var notificationAvailability: NotificationService.Availability = .notDetermined
    public private(set) var launchAtLoginState: LaunchAtLogin.State = .unavailable
    /// Ticks once a second only while the popover is open, so countdowns move without the
    /// whole app re-rendering all day.
    public private(set) var tick: Date = Date()
    public var isPopoverOpen: Bool = false {
        didSet { popoverVisibilityChanged() }
    }

    public var settings: AppSettings { settingsStore.current }

    // MARK: Dependencies

    private let api: UsageAPIClientProtocol
    private let tokenStore: TokenStore
    private let history: HistoryStore
    private let settingsStore: SettingsStore
    private let activityMonitor: ActivityMonitor
    private let notifications: NotificationService
    private let backoff = BackoffPolicy()
    private var ledger: NotificationLedger

    private var refreshTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var activityWatcher: ActivityWatcher?
    private var consecutiveFailures = 0
    /// Profile metadata changes rarely; fetch it at most once an hour.
    private var lastProfileFetch: Date?
    private static let profileInterval: TimeInterval = 3_600

    public init(
        api: UsageAPIClientProtocol = UsageAPIClient(),
        tokenStore: TokenStore = TokenStore(),
        history: HistoryStore = HistoryStore(),
        settingsStore: SettingsStore = SettingsStore(),
        activityMonitor: ActivityMonitor = ActivityMonitor(),
        notifications: NotificationService = NotificationService()
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.history = history
        self.settingsStore = settingsStore
        self.activityMonitor = activityMonitor
        self.notifications = notifications
        self.ledger = NotificationLedgerStore.load()

        AppPaths.ensureRoot()
        self.samples = history.load()
        // Show the last known values immediately, clearly labelled as cached, rather than
        // an empty panel or a row of zeros.
        if let cached = LastUsageCache.load() {
            self.snapshot = cached
            self.lastSuccessAt = cached.fetchedAt
            self.isShowingCachedData = true
        }
        self.launchAtLoginState = LaunchAtLogin.state
        recomputeAnalytics()
    }

    // MARK: Lifecycle

    public func start() {
        refreshActivity()
        startActivityWatcher()
        startRefreshLoop()
        Task { [notifications] in
            await notifications.requestAuthorization()
            await MainActor.run { self.notificationAvailability = notifications.currentAvailability }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        tickTask?.cancel()
        tickTask = nil
        activityWatcher?.stop()
        activityWatcher = nil
        history.flush()
        NotificationLedgerStore.save(ledger)
    }

    private func startRefreshLoop() {
        // Wait for the outgoing loop to actually finish before the new one starts. Without
        // this, a manual refresh could begin while the previous iteration is still unwinding,
        // see `isRefreshing == true`, and silently do nothing.
        let previous = refreshTask
        refreshTask = Task { [weak self] in
            previous?.cancel()
            _ = await previous?.value

            // One loop, one in-flight request. No overlapping fetches by construction.
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshUsage()
                if Task.isCancelled { return }
                let delay = await MainActor.run { self.nextDelay() }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func nextDelay() -> TimeInterval {
        guard consecutiveFailures > 0 else {
            return TimeInterval(settings.refreshInterval.rawValue)
        }
        let retryAfter: TimeInterval?
        if case .rateLimited(let after) = lastError { retryAfter = after } else { retryAfter = nil }
        let backoffDelay = backoff.delay(failureCount: consecutiveFailures, retryAfter: retryAfter)
        // Never poll *more* often than the user asked for, even on the first retry.
        return max(backoffDelay, TimeInterval(settings.refreshInterval.rawValue))
    }

    /// The 1 Hz clock exists only while the panel is visible.
    private func popoverVisibilityChanged() {
        if isPopoverOpen {
            tick = Date()
            refreshActivity()
            tickTask?.cancel()
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self else { return }
                    await MainActor.run { self.tick = Date() }
                }
            }
        } else {
            tickTask?.cancel()
            tickTask = nil
        }
    }

    private func startActivityWatcher() {
        guard settings.activityEnabled else { return }
        let watcher = ActivityWatcher { [weak self] in
            Task { @MainActor in self?.refreshActivity() }
        }
        watcher.start()
        activityWatcher = watcher
    }

    // MARK: Refresh

    public func refreshNow() {
        // Restarting the loop both fetches immediately and resets the schedule, so a manual
        // refresh cannot leave two loops running.
        consecutiveFailures = 0
        // Give every credential another go: hitting Refresh is exactly what someone does
        // after re-authenticating somewhere else.
        rejectedSources.removeAll()
        tokenStore.invalidateCache()
        startRefreshLoop()
    }

    private func refreshUsage() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Walk the credential chain. A source the server refuses is set aside and the next
        // one is tried straight away — the previous version re-sent the same rejected token
        // every couple of minutes indefinitely while a working credential sat unused behind
        // it in the priority order.
        while true {
            guard let token = tokenStore.resolve(excluding: rejectedSources) else {
                tokenSource = nil
                recordFailure(rejectedSources.isEmpty ? .missingToken : .unauthorized)
                return
            }
            tokenSource = token.source

            if token.isExpired {
                rejectedSources.insert(token.source)
                tokenStore.invalidateCache()
                continue
            }

            do {
                let fresh = try await api.fetchUsage(token: token.value)
                handleSuccess(fresh)
                await maybeFetchProfile(token: token.value)
                return
            } catch is CancellationError {
                return
            } catch let error as UsageAPIError {
                if error == .unauthorized || error == .forbidden {
                    rejectedSources.insert(token.source)
                    tokenStore.invalidateCache()
                    continue
                }
                recordFailure(error)
                return
            } catch {
                recordFailure(.network(error.localizedDescription))
                return
            }
        }
    }

    private func handleSuccess(_ fresh: UsageSnapshot) {
        consecutiveFailures = 0
        lastError = nil
        snapshot = fresh
        lastSuccessAt = fresh.fetchedAt
        isShowingCachedData = false

        samples = history.append(
            .from(fresh),
            retention: settings.historyRetention.duration,
            now: fresh.fetchedAt
        )
        LastUsageCache.save(fresh)
        recomputeAnalytics()
        refreshActivity(evaluate: false)
        evaluateNotifications(apiError: nil, healthy: true)
    }

    /// Recomputes the derived analytics once per poll.
    ///
    /// These used to be computed properties. Each read ran a linear regression over the whole
    /// retained history for every limit — and the popover reads them once a second, so a
    /// week of samples turned into tens of thousands of floating-point operations per second
    /// while the panel was open. Caching them is the difference between an idle menu bar app
    /// and one that shows up in Activity Monitor.
    private func recomputeAnalytics() {
        guard let snapshot else {
            projections = [:]
            surgingLimitIDs = []
            weeklyAveragePerDay = nil
            return
        }
        let now = Date()
        projections = Dictionary(
            uniqueKeysWithValues: snapshot.limits.map {
                ($0.id, UsageAnalytics.projection(for: $0, samples: samples, now: now))
            }
        )
        surgingLimitIDs = Set(
            snapshot.limits
                .filter { UsageAnalytics.isSurging(samples, limit: $0) }
                .map(\.id)
        )
        // Also cached: this one sorts the sample series, and the weekly section would
        // otherwise recompute it on every tick of the popover's clock.
        weeklyAveragePerDay = snapshot.weeklyLimit.flatMap {
            UsageAnalytics.averagePerDay(samples, limit: $0, now: now)
        }
    }

    private func recordFailure(_ error: UsageAPIError) {
        consecutiveFailures += 1
        lastError = error
        // Deliberately do NOT clear `snapshot`: showing the last known numbers with an
        // explicit age beats replacing everything with 0%.
        if snapshot != nil { isShowingCachedData = true }
        evaluateNotifications(apiError: error, healthy: false)
    }

    private func maybeFetchProfile(token: String) async {
        if let last = lastProfileFetch, Date().timeIntervalSince(last) < Self.profileInterval,
           profile != nil {
            return
        }
        lastProfileFetch = Date()
        profile = try? await api.fetchProfile(token: token)
    }

    // MARK: Activity

    /// - Parameter evaluate: pass `false` when the caller will evaluate notifications itself,
    ///   so one poll never runs the policy twice.
    public func refreshActivity(evaluate: Bool = true) {
        guard settings.activityEnabled else {
            activity = .unavailable
            return
        }
        let state = activityMonitor.read(staleAfter: settings.activityStaleSeconds)
        let changed = state != activity
        activity = state
        if changed && evaluate {
            evaluateNotifications(apiError: lastError, healthy: lastError == nil)
        }
    }

    // MARK: Notifications

    private func evaluateNotifications(apiError: UsageAPIError?, healthy: Bool) {
        let context = PolicyContext(
            now: Date(),
            settings: settings,
            snapshot: snapshot,
            projections: projections,
            surgingLimitIDs: surgingLimitIDs,
            activity: activity,
            apiError: apiError,
            apiHealthy: healthy
        )
        let before = ledger
        let pending = NotificationPolicy.evaluate(context, ledger: &ledger)

        // The activity watcher fires this on every hook event — i.e. on every Claude Code
        // tool call. Writing the ledger unconditionally would mean a disk write several times
        // a second during a busy session, so only persist when something actually changed.
        if ledger != before {
            NotificationLedgerStore.save(ledger)
        }
        guard !pending.isEmpty else { return }
        Task { [notifications] in await notifications.deliver(pending) }
    }

    // MARK: Derived values

    /// The limit whose number goes in the menu bar.
    public var primaryLimit: LimitWindow? {
        guard let snapshot else { return nil }
        switch settings.primaryMetric {
        case .auto: return snapshot.bottleneck
        case .session: return snapshot.sessionLimit ?? snapshot.bottleneck
        case .weekly: return snapshot.weeklyLimit ?? snapshot.bottleneck
        case .highestModel: return snapshot.modelLimits.first ?? snapshot.bottleneck
        case .spend: return nil
        }
    }

    public var primaryPercent: Double? {
        if settings.primaryMetric == .spend { return snapshot?.spend?.percent }
        return primaryLimit?.percent
    }

    /// A one-character hint shown when the menu-bar number is not the session limit, so
    /// "5h = 25 %, 7d = 91 %" cannot be misread as a comfortable session.
    public var primaryTag: String? {
        guard settings.showMetricTag else { return nil }
        if settings.primaryMetric == .spend { return "$" }
        guard let limit = primaryLimit else { return nil }
        if limit.isModelScoped { return "M" }
        switch limit.group {
        case .session: return nil
        case .weekly: return "W"
        case .other: return "•"
        }
    }

    /// One line explaining which limit matters most right now.
    public var headline: String {
        if lastError == .missingToken { return "Not connected" }
        guard let snapshot, let bottleneck = snapshot.bottleneck else {
            return lastError?.title ?? "No usage data"
        }
        if snapshot.limits.count > 1 {
            return "\(bottleneck.shortTitle) is your tightest limit"
        }
        return bottleneck.title
    }

    /// Drives the menu bar tint, the severity rail, and the panel wash — so it tracks quota
    /// urgency only, not the standing state of the extra-usage balance.
    public var overallSeverity: Severity {
        snapshot?.limitSeverity ?? .normal
    }

    public var statusLabel: String {
        if activity.attentionSessions.isEmpty == false { return "Needs you" }
        switch overallSeverity {
        case .normal: return "Good"
        case .warning: return "Tight"
        case .critical: return "Critical"
        }
    }

    /// True when the data on screen is old enough to warn about.
    public func isStale(now: Date) -> Bool {
        guard let lastSuccessAt else { return snapshot != nil }
        return now.timeIntervalSince(lastSuccessAt) > TimeInterval(settings.refreshInterval.rawValue) * 3
    }

    // MARK: Settings mutation

    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        let before = settingsStore.current
        let after = settingsStore.update(mutate)

        if after.historyRetention != before.historyRetention {
            history.applyRetention(after.historyRetention.duration)
            samples = history.load()
        }
        if after.refreshInterval != before.refreshInterval {
            startRefreshLoop()
        }
        if after.activityEnabled != before.activityEnabled {
            activityWatcher?.stop()
            activityWatcher = nil
            if after.activityEnabled { startActivityWatcher() }
            refreshActivity()
        }
        if after.launchAtLogin != before.launchAtLogin {
            launchAtLoginState = LaunchAtLogin.set(after.launchAtLogin)
            // Reflect what actually happened; registration can be refused.
            if launchAtLoginState.isOn != after.launchAtLogin {
                _ = settingsStore.update { $0.launchAtLogin = launchAtLoginState.isOn }
            }
        }
    }

    public func clearHistory() {
        history.clear()
        samples = []
    }

    public func saveToken(_ token: String) -> Bool {
        let ok = tokenStore.save(token: token)
        if ok {
            rejectedSources.removeAll()
            tokenStore.invalidateCache()
            refreshNow()
        }
        return ok
    }

    public func disconnect() {
        tokenStore.deleteStoredToken()
        rejectedSources.removeAll()
        tokenStore.invalidateCache()
        snapshot = nil
        profile = nil
        lastSuccessAt = nil
        LastUsageCache.clear()
        lastError = .missingToken
    }

    public func availableTokenSources() -> [TokenSource] {
        tokenStore.availableSources()
    }

    public func refreshNotificationAvailability() {
        Task { [notifications] in
            await notifications.refreshAvailability()
            await MainActor.run { self.notificationAvailability = notifications.currentAvailability }
        }
    }

    // MARK: Preview

    /// Builds a model populated from a fixture, without touching the network, the keychain,
    /// or the user's stored history. Used by `--render-preview` to generate the README
    /// screenshots, and to eyeball layout changes without waiting for a live poll.
    static func preview(
        snapshot: UsageSnapshot,
        activity: ActivityState,
        samples: [UsageSample],
        plan: String? = "Max",
        error: UsageAPIError? = nil,
        now: Date = Date()
    ) -> AppModel {
        let model = AppModel(
            api: DeadAPIClient(),
            history: HistoryStore(url: URL(fileURLWithPath: "/dev/null")),
            settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "preview") ?? .standard)
        )
        model.snapshot = snapshot
        model.activity = activity
        model.samples = samples
        model.profile = AccountProfile(
            planLabel: plan, rateLimitTier: nil, subscriptionStatus: nil, extraUsageAvailable: nil
        )
        model.lastSuccessAt = now.addingTimeInterval(-12)
        model.lastError = error
        model.tick = now
        model.recomputeAnalytics()
        return model
    }

    /// Preview-only: puts the panel into an error state after construction.
    func previewApply(error: UsageAPIError) {
        lastError = error
        isShowingCachedData = true
    }

    /// Never called during a preview render; exists so `preview` cannot hit the network.
    private struct DeadAPIClient: UsageAPIClientProtocol {
        func fetchUsage(token: String) async throws -> UsageSnapshot { throw UsageAPIError.offline }
        func fetchProfile(token: String) async throws -> AccountProfile { throw UsageAPIError.offline }
    }

    /// Sanitized debug text. Contains the response body only — never the token, and with the
    /// workspace/organization identifiers stripped.
    public func debugExport() -> String {
        var lines: [String] = []
        lines.append("Claude Usage Tracker — debug export")
        lines.append("generated: \(ISO8601.string(from: Date()))")
        lines.append("token source: \(tokenSource?.label ?? "none") (value not included)")
        lines.append("last success: \(lastSuccessAt.map(ISO8601.string(from:)) ?? "never")")
        lines.append("consecutive failures: \(consecutiveFailures)")
        lines.append("last error: \(lastError.map { "\($0.title) — \($0.detail)" } ?? "none")")
        lines.append("samples retained: \(samples.count)")
        lines.append("activity: hook \(activity.hookInstalled ? "installed" : "not installed"), \(activity.sessions.count) session(s)")
        if let snapshot {
            lines.append("schema warnings: \(snapshot.schemaWarnings.isEmpty ? "none" : snapshot.schemaWarnings.joined(separator: "; "))")
            lines.append("")
            lines.append("--- usage payload (sanitized) ---")
            lines.append(sanitizedPayload(snapshot.raw))
        }
        return lines.joined(separator: "\n")
    }

    private func sanitizedPayload(_ raw: JSONValue?) -> String {
        guard let raw else { return "(not retained)" }
        let scrubbed = scrub(raw)
        guard let data = try? JSONEncoder.pretty.encode(scrubbed),
              let text = String(data: data, encoding: .utf8)
        else { return "(could not encode)" }
        return text
    }

    /// Redacts anything that could identify the account. Keys are matched, not values, so a
    /// new identifier field is caught by name rather than by guesswork.
    private func scrub(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let dict):
            var out: [String: JSONValue] = [:]
            for (key, child) in dict {
                let lower = key.lowercased()
                if lower.contains("token") || lower.contains("uuid") || lower.contains("email")
                    || lower.contains("secret") || lower == "id" || lower.hasSuffix("_id")
                    || lower.contains("organization") || lower.contains("workspace") {
                    out[key] = .string("<redacted>")
                } else {
                    out[key] = scrub(child)
                }
            }
            return .object(out)
        case .array(let items):
            return .array(items.map(scrub))
        default:
            return value
        }
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
