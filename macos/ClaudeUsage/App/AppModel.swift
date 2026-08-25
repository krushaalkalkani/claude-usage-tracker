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
    /// Credential sources the server rejected this run.
    ///
    /// In memory only, and cleared by a manual refresh or by saving a token, so
    /// re-authenticating elsewhere (Claude Code, say) gets another chance without a
    /// relaunch. Persisting it would mean a fixed credential stayed shunned forever.
    private var rejectedSources: Set<TokenSource> = []
    public private(set) var notificationAvailability: NotificationService.Availability = .notDetermined
    public private(set) var launchAtLoginState: LaunchAtLogin.State = .unavailable
    public private(set) var selectedProvider: UsageProvider
    /// Ticks once a second only while the popover is open, so countdowns move without the
    /// whole app re-rendering all day.
    public private(set) var tick: Date = Date()
    /// Forces the icon back into the menu bar for a grace period after launch or a reopen.
    ///
    /// Without this, "hide when healthy" is a trap: the icon is the only way into Settings,
    /// so once hidden there would be no way to turn the setting off again. Re-running the app
    /// (`open -a ClaudeUsage`, or double-clicking it) sends a reopen event and brings it back.
    public private(set) var isTemporarilyRevealed = true
    private var revealTask: Task<Void, Never>?
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
    private let cursor: CursorUsageServiceProtocol
    private let cursorSessionStore: CursorSessionCookieStoreProtocol
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
        cursor: CursorUsageServiceProtocol = CursorUsageService(),
        cursorSessionStore: CursorSessionCookieStoreProtocol = CursorSessionCookieStore(),
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
        self.cursor = cursor
        self.cursorSessionStore = cursorSessionStore
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
        revealMenuBarTemporarily()
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
        revealTask?.cancel()
        revealTask = nil
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
        // Give every credential another go: hitting Refresh is exactly what someone does
        // after re-authenticating somewhere else.
        rejectedSources.removeAll()
        tokenStore.invalidateCache()
        startRefreshLoop()
    }

    private func refreshAllUsage() async {
        async let claude: Void = refreshClaudeUsage()
        async let chatgpt: Void = refreshChatGPTUsage()
        async let cursorRefresh: Void = refreshCursorUsage()
        _ = await (claude, chatgpt, cursorRefresh)
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

        // Walk the credential chain. A source the server refuses is set aside and the next
        // one is tried straight away — otherwise the same rejected token is re-sent every
        // couple of minutes while a working credential sits unused behind it in the order.
        while true {
            guard let token = tokenStore.resolve(excluding: rejectedSources) else {
                tokenSource = nil
                recordFailure(rejectedSources.isEmpty ? .missingToken : .unauthorized,
                              for: .claude)
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
                handleSuccess(fresh, planLabel: profile?.planLabel, source: .anthropicOAuth)
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
                recordFailure(error, for: .claude)
                return
            } catch {
                recordFailure(.network(error.localizedDescription), for: .claude)
                return
            }
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

    private func refreshCursorUsage() async {
        guard shouldRefresh(.cursor) else { return }
        updateProvider(.cursor) {
            $0.isRefreshing = true
            $0.cliDetected = cursor.hasStoredSession()
        }
        defer { updateProvider(.cursor) { $0.isRefreshing = false } }

        do {
            let result = try await cursor.fetchUsage()
            updateProvider(.cursor) { $0.cliDetected = true }
            handleSuccess(
                result.snapshot, planLabel: result.planLabel, source: .cursorWebViewSession
            )
        } catch is CancellationError {
            return
        } catch let error as UsageAPIError {
            recordFailure(error, for: .cursor)
        } catch {
            recordFailure(.network(error.localizedDescription), for: .cursor)
        }
    }

    private func handleSuccess(
        _ fresh: UsageSnapshot,
        planLabel: String?,
        source: ProviderDataSource
    ) {
        let provider = fresh.provider
        let providerSamples = history.append(
            .from(fresh, activeProjects: busyProjectNames()),
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
            case .missingToken, .unauthorized, .forbidden, .codexAuthenticationRequired,
                 .missingCursorSession:
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

    /// Projects Claude Code is actively working in right now.
    ///
    /// Captured at sample time because session files are ephemeral — they are deleted when
    /// the session ends or its process dies, so there is no way to ask later.
    private func busyProjectNames() -> [String] {
        let staleAfter = settings.activityStaleSeconds
        let now = Date()
        return Array(Set(
            activity.sessions
                .filter { $0.resolvedStatus(now: now, staleAfter: staleAfter).isBusy }
                .map(\.displayName)
        )).sorted()
    }

    /// Consumption split across the projects that were running, for the hero's limit.
    public func attribution(for limit: LimitWindow, since: Date) -> UsageAttribution.Breakdown {
        UsageAttribution.attribute(
            samples: state(for: limit.provider).samples,
            limitID: limit.id,
            provider: limit.provider,
            since: since
        )
    }

    /// Analytics for a limit, read from **its own** provider's state.
    ///
    /// Limit ids are only unique *within* a provider — `weekly_all` exists on both Claude and
    /// ChatGPT — so this must never be looked up by bare id against whichever provider happens
    /// to be selected, or one tab's window could end up described by the other's burn rate.
    public func projection(for limit: LimitWindow) -> UsageProjection? {
        state(for: limit.provider).projections[limit.id]
    }

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

    /// Whether the status item should be in the menu bar at all.
    ///
    /// Anything that needs the user overrides the setting: an error, a Claude Code prompt, or
    /// a limit at or above the threshold. Hiding is only ever for the quiet case.
    var shouldAppearInMenuBar: Bool {
        guard settings.hideWhenHealthy else { return true }
        if isTemporarilyRevealed { return true }
        if !activity.attentionSessions.isEmpty { return true }
        let now = Date()
        if UsageProvider.allCases.contains(where: { state(for: $0).lastError != nil }) { return true }
        let worst = UsageProvider.allCases
            .compactMap { providerTightestPercent($0, now: now) }
            .max()
        // No data is not the same as healthy — stay visible rather than vanish silently.
        guard let worst else { return true }
        return worst >= settings.hideBelowPercent
    }

    /// Brings the icon back for `seconds`, so Settings stays reachable while hidden.
    public func revealMenuBarTemporarily(seconds: TimeInterval = 20) {
        isTemporarilyRevealed = true
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.isTemporarilyRevealed = false }
        }
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
            || lastError == .cliNotFound || lastError == .missingCursorSession {
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

    /// Worst severity for one provider's own limits — used by the tab bar so an unselected
    /// tab's dot reflects that provider only, not whichever one is currently on screen.
    public func providerSeverity(_ provider: UsageProvider) -> Severity {
        state(for: provider).snapshot?.limitSeverity ?? .normal
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

    /// Called by `CursorLoginSheet` once the embedded `WKWebView` login has produced a
    /// `cursor.com` cookie. Saving triggers an immediate refresh, exactly like `saveToken`.
    public func saveCursorSession(_ cookie: String) -> Bool {
        let ok = cursorSessionStore.save(cookie: cookie)
        if ok {
            updateProvider(.cursor) { $0.lastError = nil }
            refreshNow()
        }
        return ok
    }

    public func hasCursorSession() -> Bool {
        cursorSessionStore.load() != nil
    }

    public func disconnectCursor() {
        cursorSessionStore.clear()
        updateProvider(.cursor) {
            $0.snapshot = nil
            $0.lastSuccessAt = nil
            $0.lastError = .missingCursorSession
            $0.isShowingCachedData = false
            $0.connectionState = .authenticationRequired
            $0.dataSource = nil
            $0.planLabel = nil
            $0.cliDetected = false
            $0.projections = [:]
            $0.surgingLimitIDs = []
            $0.weeklyAveragePerDay = nil
        }
        LastUsageCache.clear(provider: .cursor)
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
            cursor: DeadCursorService(),
            cursorSessionStore: DeadCursorSessionStore(),
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
            $0.dataSource = Self.previewDataSource(for: snapshot.provider)
            $0.cliDetected = snapshot.provider == .claude ? nil : true
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
            $0.dataSource = Self.previewDataSource(for: snapshot.provider)
            $0.cliDetected = snapshot.provider == .claude ? nil : true
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
            $0.connectionState = (error == .codexAuthenticationRequired || error == .missingCursorSession)
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

    private struct DeadCursorService: CursorUsageServiceProtocol {
        func fetchUsage() async throws -> CursorUsageResult { throw UsageAPIError.offline }
        func hasStoredSession() -> Bool { false }
    }

    private struct DeadCursorSessionStore: CursorSessionCookieStoreProtocol {
        func load() -> String? { nil }
        func save(cookie: String) -> Bool { false }
        func clear() -> Bool { false }
    }

    private static func previewDataSource(for provider: UsageProvider) -> ProviderDataSource {
        switch provider {
        case .claude: return .anthropicOAuth
        case .chatgpt: return .codexCLI
        case .cursor: return .cursorWebViewSession
        }
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
