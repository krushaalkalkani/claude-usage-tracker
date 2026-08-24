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

    public private(set) var providerStates: [UsageProvider: ProviderUsageState]
    public private(set) var profile: AccountProfile?
    public private(set) var activity: ActivityState = .unavailable
    public private(set) var tokenSource: TokenSource?
    public private(set) var notificationAvailability: NotificationService.Availability = .notDetermined
    public private(set) var launchAtLoginState: LaunchAtLogin.State = .unavailable
    public private(set) var selectedProvider: UsageProvider
    /// Ticks once a second only while the popover is open, so countdowns move without the
    /// whole app re-rendering all day.
    public private(set) var tick: Date = Date()
    public var isPopoverOpen: Bool = false {
        didSet { popoverVisibilityChanged() }
    }

    public var settings: AppSettings { settingsStore.current }

    public var snapshot: UsageSnapshot? { state(for: selectedProvider).snapshot }
    public var samples: [UsageSample] { state(for: selectedProvider).samples }
    public var projections: [String: UsageProjection] { state(for: selectedProvider).projections }
    public var surgingLimitIDs: Set<String> { state(for: selectedProvider).surgingLimitIDs }
    public var weeklyAveragePerDay: Double? { state(for: selectedProvider).weeklyAveragePerDay }
    public var lastError: UsageAPIError? { state(for: selectedProvider).lastError }
    public var isRefreshing: Bool { state(for: selectedProvider).isRefreshing }
    public var lastSuccessAt: Date? { state(for: selectedProvider).lastSuccessAt }
    public var isShowingCachedData: Bool { state(for: selectedProvider).isShowingCachedData }
    public var planLabel: String? { state(for: selectedProvider).planLabel }

    // MARK: Dependencies

    private let api: UsageAPIClientProtocol
    private let chatGPT: ChatGPTUsageServiceProtocol
    private let tokenStore: TokenStore
    private let history: HistoryStore
    private let settingsStore: SettingsStore
    private let activityMonitor: ActivityMonitor
    private let notifications: NotificationService
    /// Non-nil only for deterministic preview rendering, so settings previews never query
    /// the user's keychain or filesystem for credential availability.
    private let previewTokenSources: [TokenSource]?
    private let backoff = BackoffPolicy()
    private var ledger: NotificationLedger

    private var refreshTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var activityWatcher: ActivityWatcher?
    /// Profile metadata changes rarely; fetch it at most once an hour.
    private var lastProfileFetch: Date?
    private static let profileInterval: TimeInterval = 3_600

    public init(
        api: UsageAPIClientProtocol = UsageAPIClient(),
        chatGPT: ChatGPTUsageServiceProtocol = ChatGPTUsageService(),
        tokenStore: TokenStore = TokenStore(),
        history: HistoryStore = HistoryStore(),
        settingsStore: SettingsStore = SettingsStore(),
        activityMonitor: ActivityMonitor = ActivityMonitor(),
        notifications: NotificationService = NotificationService(),
        previewTokenSources: [TokenSource]? = nil,
        loadsPersistentState: Bool = true
    ) {
        self.providerStates = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases.map { ($0, ProviderUsageState(provider: $0)) }
        )
        self.selectedProvider = settingsStore.current.selectedProvider
        self.api = api
        self.chatGPT = chatGPT
        self.tokenStore = tokenStore
        self.history = history
        self.settingsStore = settingsStore
        self.activityMonitor = activityMonitor
        self.notifications = notifications
        self.previewTokenSources = previewTokenSources
        self.ledger = loadsPersistentState ? NotificationLedgerStore.load() : NotificationLedger()

        if loadsPersistentState { AppPaths.ensureRoot() }
        for provider in UsageProvider.allCases {
            updateProvider(provider) { state in
                state.samples = history.load(provider: provider)
                // Show each provider's last known values immediately and independently.
                if loadsPersistentState, let cached = LastUsageCache.load(provider: provider) {
                    state.snapshot = cached
                    state.lastSuccessAt = cached.fetchedAt
                    state.isShowingCachedData = true
                    state.connectionState = .unknown
                }
            }
        }
        self.launchAtLoginState = LaunchAtLogin.state
        for provider in UsageProvider.allCases { recomputeAnalytics(for: provider) }
    }

    public func state(for provider: UsageProvider) -> ProviderUsageState {
        providerStates[provider] ?? ProviderUsageState(provider: provider)
    }

    private func updateProvider(
        _ provider: UsageProvider,
        _ mutate: (inout ProviderUsageState) -> Void
    ) {
        var state = providerStates[provider] ?? ProviderUsageState(provider: provider)
        mutate(&state)
        providerStates[provider] = state
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
                await self.refreshAllUsage()
                if Task.isCancelled { return }
                let delay = await MainActor.run { self.nextDelay() }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func nextDelay() -> TimeInterval {
        TimeInterval(settings.refreshInterval.rawValue)
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
        for provider in UsageProvider.allCases {
            updateProvider(provider) {
                $0.consecutiveFailures = 0
                $0.nextRetryAt = nil
            }
        }
        startRefreshLoop()
    }

    private func refreshAllUsage() async {
        async let claude: Void = refreshClaudeUsage()
        async let chatgpt: Void = refreshChatGPTUsage()
        _ = await (claude, chatgpt)
    }

    private func shouldRefresh(_ provider: UsageProvider, now: Date = Date()) -> Bool {
        let state = state(for: provider)
        guard !state.isRefreshing else { return false }
        guard let retry = state.nextRetryAt else { return true }
        return retry <= now
    }

    private func refreshClaudeUsage() async {
        guard shouldRefresh(.claude) else { return }
        updateProvider(.claude) { $0.isRefreshing = true }
        defer { updateProvider(.claude) { $0.isRefreshing = false } }

        guard let token = tokenStore.resolve() else {
            tokenSource = nil
            recordFailure(.missingToken, for: .claude)
            return
        }
        tokenSource = token.source

        if token.isExpired {
            recordFailure(.unauthorized, for: .claude)
            return
        }

        do {
            let fresh = try await api.fetchUsage(token: token.value)
            handleSuccess(fresh, planLabel: profile?.planLabel, source: .anthropicOAuth)
            await maybeFetchProfile(token: token.value)
        } catch is CancellationError {
            return
        } catch let error as UsageAPIError {
            if error == .unauthorized { tokenStore.invalidateCache() }
            recordFailure(error, for: .claude)
        } catch {
            recordFailure(.network(error.localizedDescription), for: .claude)
        }
    }

    private func refreshChatGPTUsage() async {
        guard shouldRefresh(.chatgpt) else { return }
        updateProvider(.chatgpt) {
            $0.isRefreshing = true
            $0.cliDetected = chatGPT.isCLIDetected()
        }
        defer { updateProvider(.chatgpt) { $0.isRefreshing = false } }

        do {
            let result = try await chatGPT.fetchUsage()
            updateProvider(.chatgpt) { $0.cliDetected = result.cliDetected }
            handleSuccess(
                result.snapshot, planLabel: result.planLabel,
                source: result.source
            )
        } catch is CancellationError {
            return
        } catch let error as UsageAPIError {
            recordFailure(error, for: .chatgpt)
        } catch {
            recordFailure(.cliUnavailable, for: .chatgpt)
        }
    }

    private func handleSuccess(
        _ fresh: UsageSnapshot,
        planLabel: String?,
        source: ProviderDataSource
    ) {
        let provider = fresh.provider
        let providerSamples = history.append(
            .from(fresh),
            retention: settings.historyRetention.duration,
            now: fresh.fetchedAt
        )
        updateProvider(provider) { state in
            state.consecutiveFailures = 0
            state.nextRetryAt = nil
            state.lastError = nil
            state.snapshot = fresh
            state.planLabel = planLabel ?? state.planLabel
            state.lastSuccessAt = fresh.fetchedAt
            state.isShowingCachedData = false
            state.samples = providerSamples
            state.connectionState = .connected
            state.dataSource = source
        }
        LastUsageCache.save(fresh, provider: provider)
        recomputeAnalytics(for: provider)
        if provider == .claude { refreshActivity(evaluate: false) }
        evaluateNotifications(for: provider, apiError: nil, healthy: true)
    }

    /// Recomputes the derived analytics once per poll.
    ///
    /// These used to be computed properties. Each read ran a linear regression over the whole
    /// retained history for every limit — and the popover reads them once a second, so a
    /// week of samples turned into tens of thousands of floating-point operations per second
    /// while the panel was open. Caching them is the difference between an idle menu bar app
    /// and one that shows up in Activity Monitor.
    private func recomputeAnalytics(for provider: UsageProvider) {
        let current = state(for: provider)
        guard let snapshot = current.snapshot else {
            updateProvider(provider) {
                $0.projections = [:]
                $0.surgingLimitIDs = []
                $0.weeklyAveragePerDay = nil
            }
            return
        }
        let now = Date()
        let projections = Dictionary(
            uniqueKeysWithValues: snapshot.limits.map {
                ($0.id, UsageAnalytics.projection(for: $0, samples: current.samples, now: now))
            }
        )
        let surgingLimitIDs = Set(
            snapshot.limits
                .filter { UsageAnalytics.isSurging(current.samples, limit: $0) }
                .map(\.id)
        )
        // Also cached: this one sorts the sample series, and the weekly section would
        // otherwise recompute it on every tick of the popover's clock.
        let weeklyAveragePerDay = snapshot.weeklyLimit.flatMap {
            UsageAnalytics.averagePerDay(current.samples, limit: $0, now: now)
        }
        updateProvider(provider) {
            $0.projections = projections
            $0.surgingLimitIDs = surgingLimitIDs
            $0.weeklyAveragePerDay = weeklyAveragePerDay
        }
    }

    private func recordFailure(_ error: UsageAPIError, for provider: UsageProvider) {
        let previous = state(for: provider)
        let failures = previous.consecutiveFailures + 1
        let retryAfter: TimeInterval?
        if case .rateLimited(let after) = error { retryAfter = after } else { retryAfter = nil }
        let delay = max(
            backoff.delay(failureCount: failures, retryAfter: retryAfter),
            TimeInterval(settings.refreshInterval.rawValue)
        )
        updateProvider(provider) { state in
            state.consecutiveFailures = failures
            state.nextRetryAt = Date().addingTimeInterval(delay)
            state.lastError = error
            if state.snapshot != nil { state.isShowingCachedData = true }
            switch error {
            case .missingToken, .unauthorized, .forbidden, .codexAuthenticationRequired:
                state.connectionState = .authenticationRequired
            case .cliNotFound:
                state.connectionState = .unavailable
                state.cliDetected = false
            default:
                state.connectionState = .unavailable
            }
        }
        evaluateNotifications(for: provider, apiError: error, healthy: false)
    }

    private func maybeFetchProfile(token: String) async {
        if let last = lastProfileFetch, Date().timeIntervalSince(last) < Self.profileInterval,
           profile != nil {
            return
        }
        lastProfileFetch = Date()
        profile = try? await api.fetchProfile(token: token)
        if let profile {
            updateProvider(.claude) { $0.planLabel = profile.planLabel }
        }
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
            let claude = self.state(for: .claude)
            evaluateNotifications(
                for: .claude, apiError: claude.lastError, healthy: claude.lastError == nil
            )
        }
    }

    // MARK: Notifications

    private func evaluateNotifications(
        for provider: UsageProvider,
        apiError: UsageAPIError?,
        healthy: Bool
    ) {
        let providerState = state(for: provider)
        let context = PolicyContext(
            now: Date(),
            settings: settings,
            snapshot: providerState.snapshot,
            provider: provider,
            projections: providerState.projections,
            surgingLimitIDs: providerState.surgingLimitIDs,
            activity: provider == .claude ? activity : nil,
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

    /// The status item follows the selected popover tab while still choosing that provider's
    /// configured real limit. Disconnected or stale cached data remains unavailable.
    var menuBarMetric: MenuBarUsageMetric? {
        MenuBarMetricPolicy.selected(
            provider: selectedProvider,
            states: providerStates,
            primaryMetric: settings.primaryMetric,
            now: Date(),
            refreshInterval: TimeInterval(settings.refreshInterval.rawValue)
        )
    }

    var liveProviderCount: Int {
        let now = Date()
        let interval = TimeInterval(settings.refreshInterval.rawValue)
        return UsageProvider.allCases.filter {
            state(for: $0).hasCurrentData(now: now, refreshInterval: interval)
        }.count
    }

    public func providerTightestPercent(_ provider: UsageProvider, now: Date) -> Double? {
        let state = state(for: provider)
        guard state.hasCurrentData(
            now: now, refreshInterval: TimeInterval(settings.refreshInterval.rawValue)
        ) else { return nil }
        return state.snapshot?.bottleneck?.percent
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
        if lastError == .missingToken || lastError == .codexAuthenticationRequired
            || lastError == .cliNotFound {
            return "Not connected"
        }
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
        selectedProvider = after.selectedProvider

        if after.historyRetention != before.historyRetention {
            history.applyRetention(after.historyRetention.duration)
            for provider in UsageProvider.allCases {
                updateProvider(provider) { $0.samples = history.load(provider: provider) }
                recomputeAnalytics(for: provider)
            }
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
        for provider in UsageProvider.allCases {
            updateProvider(provider) {
                $0.samples = []
                $0.projections = [:]
                $0.surgingLimitIDs = []
                $0.weeklyAveragePerDay = nil
            }
        }
    }

    public func selectProvider(_ provider: UsageProvider) {
        guard provider != selectedProvider else { return }
        _ = settingsStore.update { $0.selectedProvider = provider }
        selectedProvider = provider
    }

    public func saveToken(_ token: String) -> Bool {
        let ok = tokenStore.save(token: token)
        if ok {
            tokenStore.invalidateCache()
            refreshNow()
        }
        return ok
    }

    public func disconnect() {
        tokenStore.deleteStoredToken()
        tokenStore.invalidateCache()
        profile = nil
        updateProvider(.claude) {
            $0.snapshot = nil
            $0.lastSuccessAt = nil
            $0.lastError = .missingToken
            $0.isShowingCachedData = false
            $0.connectionState = .authenticationRequired
            $0.dataSource = nil
            $0.planLabel = nil
            $0.projections = [:]
            $0.surgingLimitIDs = []
            $0.weeklyAveragePerDay = nil
        }
        LastUsageCache.clear(provider: .claude)
    }

    public func dashboardURL(for provider: UsageProvider) -> URL {
        if provider == .claude, let custom = URL(string: settings.dashboardURL) {
            return custom
        }
        return provider.dashboardURL
    }

    public func availableTokenSources() -> [TokenSource] {
        previewTokenSources ?? tokenStore.availableSources()
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
            chatGPT: DeadChatGPTService(),
            history: HistoryStore(url: URL(fileURLWithPath: "/dev/null")),
            settingsStore: SettingsStore(
                defaults: UserDefaults(suiteName: "preview-\(UUID().uuidString)") ?? .standard
            ),
            previewTokenSources: [.claudeCodeKeychain],
            loadsPersistentState: false
        )
        model.tokenSource = .claudeCodeKeychain
        model.activity = activity
        if snapshot.provider == .claude {
            model.profile = AccountProfile(
                planLabel: plan, rateLimitTier: nil, subscriptionStatus: nil,
                extraUsageAvailable: nil
            )
        }
        model.updateProvider(snapshot.provider) {
            $0.snapshot = snapshot
            $0.samples = samples
            $0.planLabel = plan
            $0.lastSuccessAt = now.addingTimeInterval(-12)
            $0.lastError = error
            $0.isShowingCachedData = error != nil
            $0.connectionState = error == nil ? .connected : .unavailable
            $0.dataSource = snapshot.provider == .claude ? .anthropicOAuth : .codexCLI
            $0.cliDetected = snapshot.provider == .chatgpt ? true : nil
        }
        model.tick = now
        model.selectProvider(snapshot.provider)
        model.recomputeAnalytics(for: snapshot.provider)
        return model
    }

    /// Adds or replaces one provider in a preview model without touching persisted data.
    func previewApply(
        snapshot: UsageSnapshot,
        samples: [UsageSample] = [],
        plan: String? = nil,
        error: UsageAPIError? = nil,
        select: Bool = false,
        now: Date = Date()
    ) {
        updateProvider(snapshot.provider) {
            $0.snapshot = snapshot
            $0.samples = samples
            $0.planLabel = plan
            $0.lastSuccessAt = now.addingTimeInterval(-12)
            $0.lastError = error
            $0.isShowingCachedData = error != nil
            $0.connectionState = error == nil ? .connected : .unavailable
            $0.dataSource = snapshot.provider == .claude ? .anthropicOAuth : .codexCLI
            $0.cliDetected = snapshot.provider == .chatgpt ? true : nil
        }
        if select { selectProvider(snapshot.provider) }
        recomputeAnalytics(for: snapshot.provider)
    }

    /// Preview-only: puts the panel into an error state after construction.
    func previewApply(error: UsageAPIError) {
        updateProvider(selectedProvider) {
            $0.lastError = error
            $0.isShowingCachedData = true
            $0.connectionState = .unavailable
        }
    }

    /// Preview-only disconnected state for a provider that has no cached snapshot.
    func previewApply(
        provider: UsageProvider,
        error: UsageAPIError,
        cliDetected: Bool? = nil,
        select: Bool = true
    ) {
        updateProvider(provider) {
            $0.snapshot = nil
            $0.lastSuccessAt = nil
            $0.lastError = error
            $0.isShowingCachedData = false
            $0.connectionState = error == .codexAuthenticationRequired
                ? .authenticationRequired : .unavailable
            $0.cliDetected = cliDetected
            $0.dataSource = nil
        }
        if select { selectProvider(provider) }
    }

    /// Never called during a preview render; exists so `preview` cannot hit the network.
    private struct DeadAPIClient: UsageAPIClientProtocol {
        func fetchUsage(token: String) async throws -> UsageSnapshot { throw UsageAPIError.offline }
        func fetchProfile(token: String) async throws -> AccountProfile { throw UsageAPIError.offline }
    }

    private struct DeadChatGPTService: ChatGPTUsageServiceProtocol {
        func fetchUsage() async throws -> ChatGPTUsageResult { throw UsageAPIError.offline }
        func isCLIDetected() -> Bool { false }
    }

    /// Sanitized debug text. Contains the response body only — never the token, and with the
    /// workspace/organization identifiers stripped.
    public func debugExport() -> String {
        var lines: [String] = []
        lines.append("Claude Usage Tracker - debug export")
        lines.append("generated: \(ISO8601.string(from: Date()))")
        lines.append("Claude credential source: \(tokenSource?.label ?? "none") (value not included)")
        lines.append("activity: hook \(activity.hookInstalled ? "installed" : "not installed"), \(activity.sessions.count) session(s)")
        for provider in UsageProvider.allCases {
            let state = state(for: provider)
            lines.append("")
            lines.append("--- \(provider.displayName) ---")
            lines.append("connection: \(state.connectionState.rawValue)")
            lines.append("data source: \(state.dataSource?.label ?? "none")")
            lines.append("last success: \(state.lastSuccessAt.map(ISO8601.string(from:)) ?? "never")")
            lines.append("cached: \(state.isShowingCachedData ? "yes" : "no")")
            lines.append("consecutive failures: \(state.consecutiveFailures)")
            lines.append("last error: \(state.lastError?.title(for: provider) ?? "none")")
            lines.append("samples retained: \(state.samples.count)")
            if let snapshot = state.snapshot {
                lines.append("schema warnings: \(snapshot.schemaWarnings.isEmpty ? "none" : snapshot.schemaWarnings.joined(separator: "; "))")
                lines.append("usage payload (sanitized):")
                lines.append(DebugSanitizer.encoded(snapshot.raw))
            }
        }
        return lines.joined(separator: "\n")
    }
}
