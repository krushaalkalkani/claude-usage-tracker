import SwiftUI
import AppKit
import ClaudeUsageCore

struct PopoverView: View {
    @Bindable var model: AppModel
    @State private var sparklineRange: SparklineRange = .fiveHours
    @State private var checkMinutes: Double = 30
    @State private var showingCursorLogin = false

    private var now: Date { model.tick }

    /// The one limit that gets the hero treatment, within the selected provider's tab.
    private var hero: LimitWindow? { model.primaryLimit }

    /// Everything else on this tab, ranked tightest-first.
    private var others: [LimitWindow] {
        guard let snapshot = model.snapshot else { return [] }
        return snapshot.limits.filter { $0.id != hero?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProviderTabBar(model: model)
            header
            body(for: model.snapshot)
            footer
        }
        .frame(width: DS.panelWidth)
        // Deepen the system material into one considered surface. No severity wash: it
        // made a healthy account look like a pastel warning, and colour that is always on
        // stops meaning anything.
        .background(DS.scrim)
        .onAppear { sparklineRange = model.settings.sparklineRange }
        .onChange(of: sparklineRange) { _, newValue in
            model.updateSettings { $0.sparklineRange = newValue }
        }
        .sheet(isPresented: $showingCursorLogin) {
            CursorLoginSheet(model: model)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    StatusDot(color: headerStatusColor)
                    // The panel is no longer one provider's view, so the title stops
                    // claiming to be. It names a provider only when just one is tracked.
                    Text(headerTitle)
                        .font(DS.label(13, weight: .semibold))
                        .foregroundStyle(DS.ink)
                }
                Spacer(minLength: 8)
                Text(statusLine)
                    .font(DS.figure(10))
                    .foregroundStyle(DS.inkFaint)
            }
            if let note = headerSubtitle {
                Text(note)
                    .font(DS.label(9.5))
                    .foregroundStyle(DS.inkFaint)
            }
        }
        .panelRow()
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // The tab bar already says which service is showing; the header describes it in full —
    // its plan, its own allowance caveat, its own freshness.
    private var headerTitle: String { model.selectedProvider.headerTitle }

    private var headerSubtitle: String? { model.selectedProvider.allowanceDescription }

    private var statusLine: String {
        var parts: [String] = []
        if let plan = model.planLabel { parts.append(plan) }
        if model.isRefreshing {
            parts.append("refreshing")
        } else if let last = model.lastSuccessAt {
            parts.append(Format.relativeAge(now.timeIntervalSince(last)))
        }
        return parts.joined(separator: " · ")
    }

    private var headerStatusColor: Color {
        if model.snapshot == nil { return DS.inkFaint }
        if model.lastError != nil { return DS.tight }
        return DS.accent(model.providerSeverity(model.selectedProvider))
    }

    // MARK: Body

    @ViewBuilder
    private func body(for snapshot: UsageSnapshot?) -> some View {
        if snapshot == nil && shouldShowConnectPrompt {
            // Each tab offers its own connect flow — switching to ChatGPT with Claude already
            // connected should not fall through to Claude's prompt or an empty state.
            switch model.selectedProvider {
            case .claude:
                ClaudeConnectPrompt(model: model).padding(.bottom, 14)
            case .chatgpt:
                ChatGPTConnectPrompt(model: model).padding(.bottom, 14)
            case .cursor:
                CursorConnectPrompt(model: model) { showingCursorLogin = true }
                    .padding(.bottom, 14)
            }
        } else if let snapshot {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                // Each tab shows its own error only — a dead Codex token has no bearing on
                // the Claude tab and should not appear there.
                if let error = model.lastError {
                    ErrorBanner(
                        error: error,
                        provider: model.selectedProvider,
                        isShowingCached: model.snapshot != nil
                    )
                    .panelRow()
                }

                if let hero {
                    HeroLimitView(
                        limit: hero,
                        projection: model.projection(for: hero),
                        isTightest: snapshot.limits.count > 1,
                        pace: UsageAnalytics.pace(for: hero, now: now),
                        now: now
                    )
                }

                if let hero, model.settings.showRunwayCheck {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        SectionRule()
                        RunwayCheckView(
                            limit: hero, samples: model.samples, now: now,
                            minutes: $checkMinutes
                        )
                    }
                }

                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionRule()
                        Eyebrow(text: "Other limits").panelRow()
                        ForEach(others, id: \.rowKey) { limit in
                            CompactLimitRow(
                                limit: limit,
                                projection: model.projection(for: limit),
                                now: now
                            )
                        }
                    }
                }

                if let spend = snapshot.spend {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        SectionRule()
                        SpendRow(spend: spend)
                    }
                }

                if snapshot.provider == .chatgpt,
                   snapshot.credits?.isPresentable == true || snapshot.spendControl != nil {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        SectionRule()
                        ChatGPTAccountMetadata(snapshot: snapshot, now: now)
                    }
                }

                if model.selectedProvider == .claude && model.settings.activityEnabled {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        SectionRule()
                        ActivitySectionView(activity: model.activity, now: now)
                    }
                }

                SectionRule()
                SparklineSection(
                    samples: model.samples,
                    limitID: hero?.id,
                    severity: model.overallSeverity,
                    range: $sparklineRange,
                    now: now
                )

                if model.settings.debugMode, !snapshot.schemaWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Eyebrow(text: "Schema notes")
                        ForEach(snapshot.schemaWarnings, id: \.self) { warning in
                            Text(warning)
                                .font(DS.figure(9.5))
                                .foregroundStyle(DS.inkFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .panelRow()
                }
            }
            .padding(.bottom, 14)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.lastError {
                    ErrorBanner(
                        error: error,
                        provider: model.selectedProvider,
                        isShowingCached: false
                    )
                    .panelRow()
                } else {
                    Text(emptyStateText)
                        .font(DS.label(11.5))
                        .foregroundStyle(DS.inkMuted)
                        .panelRow()
                }
            }
            .padding(.bottom, 14)
        }
    }

    private var shouldShowConnectPrompt: Bool {
        guard model.snapshot == nil else { return false }
        switch model.lastError {
        case .missingToken, .unauthorized, .forbidden, .codexAuthenticationRequired, .cliNotFound,
             .missingCursorSession:
            return true
        default:
            return false
        }
    }

    private var emptyStateText: String {
        if model.isRefreshing || model.lastSuccessAt == nil { return "Fetching your usage…" }
        return "No usage limits reported for this account."
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "arrow.clockwise", help: "Refresh now") { model.refreshNow() }
            IconButton(symbol: "chart.bar.doc.horizontal", help: "Open dashboard") {
                NSWorkspace.shared.open(model.dashboardURL(for: model.selectedProvider))
            }
            SettingsLink {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.inkMuted)
            .help("Settings")
            .simultaneousGesture(TapGesture().onEnded {
                // Settings opens behind the panel unless the app is brought forward first.
                NSApp.activate(ignoringOtherApps: true)
            })

            Spacer(minLength: 6)

            if model.isStale(now: now), model.lastSuccessAt != nil {
                Text("stale")
                    .font(DS.figure(9.5, weight: .medium))
                    .foregroundStyle(DS.tight)
                    .padding(.trailing, 2)
            }

            IconButton(symbol: "power", help: "Quit Claude Usage", tint: DS.inkFaint) {
                model.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, DS.hInset - 4)
        .padding(.vertical, 7)
        .background(alignment: .top) {
            Rectangle().fill(DS.hairline).frame(height: 1)
        }
    }
}

// MARK: - Error banner

private struct ErrorBanner: View {
    let error: UsageAPIError
    let provider: UsageProvider
    let isShowingCached: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title(for: provider))
                    .font(DS.label(11, weight: .semibold))
                    .foregroundStyle(DS.ink)
                Text(
                    isShowingCached
                        ? "\(error.detail(for: provider)) Showing the last values received."
                        : error.detail(for: provider)
                )
                    .font(DS.label(10.5))
                    .foregroundStyle(DS.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    private var tint: Color { error.isTransient ? DS.tight : DS.spent }

    private var symbol: String {
        switch error {
        case .unauthorized, .forbidden, .missingToken, .codexAuthenticationRequired,
             .missingCursorSession:
            return "key.slash"
        case .cliNotFound, .unsupportedCLI: return "terminal"
        case .offline: return "wifi.slash"
        case .rateLimited: return "hourglass"
        case .unrecognizedSchema, .invalidJSON: return "questionmark.diamond"
        default: return "exclamationmark.triangle"
        }
    }
}

// MARK: - First run

private struct ClaudeConnectPrompt: View {
    @Bindable var model: AppModel
    @State private var pasted: String = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Connect an OAuth token")
                .font(DS.label(12, weight: .semibold))
                .foregroundStyle(DS.ink)
            Text("Sign in to Claude Code and this app reuses those credentials, or paste a token. It goes to your login keychain, never to a file.")
                .font(DS.label(11))
                .foregroundStyle(DS.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Paste token", text: $pasted)
                .textFieldStyle(.roundedBorder)
                .font(DS.label(11))

            HStack(spacing: 8) {
                Button("Save") {
                    failed = !model.saveToken(pasted)
                    if !failed { pasted = "" }
                }
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Look again") { model.refreshNow() }
                Spacer()
            }
            .controlSize(.small)

            if failed {
                Text("Could not write to the keychain.")
                    .font(DS.label(10.5))
                    .foregroundStyle(DS.spent)
            }
        }
        .panelRow()
    }
}

private struct ChatGPTConnectPrompt: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Connect with Codex")
                .font(DS.label(12, weight: .semibold))
                .foregroundStyle(DS.ink)
            Text(message)
                .font(DS.label(11))
                .foregroundStyle(DS.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Setup instructions") {
                    if let url = URL(string: "https://developers.openai.com/codex/auth/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Look again") { model.refreshNow() }
                Spacer()
            }
            .controlSize(.small)

            Text("The tracker never starts an interactive login or asks for an API key.")
                .font(DS.label(10))
                .foregroundStyle(DS.inkFaint)
        }
        .panelRow()
    }

    private var message: String {
        let state = model.state(for: .chatgpt)
        if state.cliDetected == false {
            return "Install the Codex CLI and sign in to ChatGPT from Codex. Usage will load automatically after you choose to sign in."
        }
        return "Codex is installed, but its ChatGPT sign-in needs attention. Open Codex or run codex login when you are ready."
    }
}

private struct CursorConnectPrompt: View {
    @Bindable var model: AppModel
    var onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Connect Cursor")
                .font(DS.label(12, weight: .semibold))
                .foregroundStyle(DS.ink)
            Text("Cursor has no read-only CLI or API token, so this app signs in through a one-time embedded browser and keeps only the resulting session in your login keychain.")
                .font(DS.label(11))
                .foregroundStyle(DS.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Connect Cursor") { onConnect() }
                Button("Look again") { model.refreshNow() }
                Spacer()
            }
            .controlSize(.small)

            Text("The tracker never reads cookies from Safari or Chrome — only from this sign-in.")
                .font(DS.label(10))
                .foregroundStyle(DS.inkFaint)
        }
        .panelRow()
    }
}

private struct ChatGPTAccountMetadata: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(text: "ChatGPT allowance")
            if let credits = snapshot.credits, credits.isPresentable {
                metadataRow("Credits", creditsText(credits))
            }
            if let control = snapshot.spendControl {
                metadataRow("Spend control", "\(control.used) of \(control.limit)")
                if let resetsAt = control.resetsAt {
                    Text("Resets in \(Format.duration(max(0, resetsAt.timeIntervalSince(now))))")
                        .font(DS.label(10))
                        .foregroundStyle(DS.inkFaint)
                }
            }
        }
        .panelRow()
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(DS.label(11)).foregroundStyle(DS.inkMuted)
            Spacer()
            Text(value).font(DS.figure(10.5, weight: .semibold)).foregroundStyle(DS.ink)
        }
    }

    private func creditsText(_ credits: UsageCredits) -> String {
        if credits.unlimited == true { return "Unlimited" }
        if let balance = credits.balance { return balance }
        if credits.hasCredits == true { return "Available" }
        if credits.hasCredits == false { return "None" }
        return "Available"
    }
}
