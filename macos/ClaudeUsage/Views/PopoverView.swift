import SwiftUI
import AppKit
import ClaudeUsageCore

struct PopoverView: View {
    @Bindable var model: AppModel
    @State private var sparklineRange: SparklineRange = .fiveHours
    @State private var checkMinutes: Double = 30

    private var now: Date { model.tick }

    /// The one limit that gets the hero treatment — the tightest across every provider.
    private var hero: LimitWindow? { model.unifiedHero }

    /// Everything else, still ranked tightest-first, regardless of which service it came from.
    private var others: [LimitWindow] {
        model.allLimitsRanked.filter { !model.isSameLimit($0, hero) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
    }

    // MARK: Header

    private var providerSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(UsageProvider.allCases) { provider in
                if provider != UsageProvider.allCases.first {
                    Text("|")
                        .font(DS.label(10))
                        .foregroundStyle(DS.inkFaint.opacity(0.65))
                }
                Button {
                    model.selectProvider(provider)
                } label: {
                    HStack(spacing: 4) {
                        Text(provider.displayName)
                        Text(providerPercent(provider))
                            .font(DS.figure(10, weight: .semibold))
                    }
                    .font(DS.label(10.5, weight: model.selectedProvider == provider ? .semibold : .medium))
                    .foregroundStyle(model.selectedProvider == provider ? DS.ink : DS.inkMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(model.selectedProvider == provider ? DS.surface : Color.clear)
                            .overlay(
                                Capsule().strokeBorder(
                                    model.selectedProvider == provider ? DS.surfaceStroke : Color.clear,
                                    lineWidth: 1
                                )
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(provider.displayName) usage")
            }
            Spacer(minLength: 0)
        }
        .panelRow()
        .padding(.top, 10)
    }

    private func providerPercent(_ provider: UsageProvider) -> String {
        guard let percent = model.providerTightestPercent(provider, now: now) else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

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

    private var headerTitle: String {
        let live = model.providersWithData
        guard live.count == 1, let only = live.first else { return "Usage" }
        return only.headerTitle
    }

    /// The Codex/agentic caveat only belongs here when ChatGPT is the only thing on screen;
    /// in a mixed list it would look like it applied to the Claude rows too.
    private var headerSubtitle: String? {
        let live = model.providersWithData
        guard live.count == 1, let only = live.first else { return nil }
        return only.allowanceDescription
    }

    private var statusLine: String {
        var parts: [String] = []
        // With both providers listed, one plan label would be ambiguous.
        if model.providersWithData.count == 1, let plan = model.planLabel { parts.append(plan) }
        if model.isRefreshing {
            parts.append("refreshing")
        } else if let last = model.lastSuccessAt {
            parts.append(Format.relativeAge(now.timeIntervalSince(last)))
        }
        return parts.joined(separator: " · ")
    }

    private var headerStatusColor: Color {
        if model.providersWithData.isEmpty { return DS.inkFaint }
        if !model.providerErrors.isEmpty { return DS.tight }
        // Worst severity across everything tracked, not just the formerly-selected provider.
        let worst = model.allLimitsRanked.map(\.severity).max() ?? .normal
        return DS.accent(worst)
    }

    // MARK: Body

    @ViewBuilder
    private func body(for snapshot: UsageSnapshot?) -> some View {
        if model.providersWithData.isEmpty && shouldShowConnectPrompt {
            // Nothing anywhere: offer the provider that is closest to being usable.
            if model.state(for: .claude).snapshot == nil && model.lastError == .missingToken {
                ClaudeConnectPrompt(model: model).padding(.bottom, 14)
            } else {
                ChatGPTConnectPrompt(model: model).padding(.bottom, 14)
            }
        } else if let snapshot {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                // One banner per failing provider: a dead Codex token must not hide a Claude
                // problem, and neither should silence the other's data.
                ForEach(model.providerErrors, id: \.0) { provider, error in
                    ErrorBanner(
                        error: error,
                        provider: provider,
                        isShowingCached: model.state(for: provider).snapshot != nil
                    )
                    .panelRow()
                }

                if let hero {
                    HeroLimitView(
                        limit: hero,
                        projection: model.projection(for: hero),
                        isTightest: model.allLimitsRanked.count > 1,
                        showsProvider: model.providersWithData.count > 1,
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
                        Eyebrow(
                            text: "All limits",
                            detail: model.providersWithData.count > 1 ? "tightest first" : nil
                        ).panelRow()
                        ForEach(others, id: \.rowKey) { limit in
                            CompactLimitRow(
                                limit: limit,
                                projection: model.projection(for: limit),
                                now: now,
                                showsProvider: model.providersWithData.count > 1
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
        case .missingToken, .unauthorized, .forbidden, .codexAuthenticationRequired, .cliNotFound:
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
        case .unauthorized, .forbidden, .missingToken, .codexAuthenticationRequired:
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
