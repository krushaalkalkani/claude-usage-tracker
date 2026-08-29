import SwiftUI
import ClaudeUsageCore

/// One genuinely separate tab per tracked service.
///
/// The panel used to merge them into one ranked list — technically tidy, but it meant you
/// could never look at "just Claude" or "just ChatGPT" the way the mental model of separate
/// subscriptions actually works. This restores the split, and goes further: each tab, even
/// when not selected, carries its own live status dot and its own headline percentage, so
/// switching is optional for the headline number and only required for the detail underneath.
///
/// That percentage is **what is left**, the same figure and the same window the hero shows
/// once you switch to the tab. It used to be utilisation, which meant the Claude pill read
/// "55%" while the Claude hero one row below read "45%" — the same limit, two numbers, and
/// nothing on screen saying which was which.
///
/// The name and the percentage are stacked rather than sat side by side. Side by side worked
/// at two and three providers and broke at four: 380pt of panel divided four ways left each
/// label about 25pt after its dot and number, which rendered Cursor and ChatGPT as the same
/// truncated "C…" — the one thing a provider switcher must never do. Stacking gives the name
/// the tab's full width and costs one row of height.
struct ProviderTabBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsageProvider.allCases) { provider in
                TabButton(
                    provider: provider,
                    isSelected: model.selectedProvider == provider,
                    remaining: model.providerRemainingPercent(provider, now: model.tick),
                    severity: model.providerSeverity(provider),
                    hasError: model.state(for: provider).lastError != nil,
                    needsAttention: provider == .claude && !model.activity.attentionSessions.isEmpty
                ) {
                    // Deliberately not wrapped in withAnimation: the popover window resizes
                    // itself to fit each tab's content (.windowResizability(.contentSize)),
                    // and animating the content diff at the same time produced a visible
                    // stutter — two animation systems moving the same pixels on different
                    // curves. The tab pill still animates its own highlight below; only the
                    // body swap itself is instant, which is how Xcode's inspector tabs and
                    // Mail's sidebar switcher behave too.
                    model.selectProvider(provider)
                }
            }
        }
        .padding(3)
        .background(DS.dim, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .panelRow()
        .padding(.top, 10)
        // Left/right arrows switch tabs without reaching for the trackpad — the panel is a
        // keyboard-navigable window, and a two-item switcher is exactly what arrow keys are for.
        .onMoveCommand { direction in
            guard direction == .left || direction == .right else { return }
            let all = UsageProvider.allCases
            guard let i = all.firstIndex(of: model.selectedProvider) else { return }
            let next = direction == .right ? (i + 1) % all.count : (i - 1 + all.count) % all.count
            model.selectProvider(all[next])
        }
    }
}

private struct TabButton: View {
    let provider: UsageProvider
    let isSelected: Bool
    /// Percentage points still available on that provider's binding limit.
    let remaining: Double?
    let severity: Severity
    let hasError: Bool
    let needsAttention: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    StatusDot(color: dotColor)
                    Text(provider.displayName)
                        .font(DS.label(11.5, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        // The longest name ("ChatGPT") is within a hair of the tab width at
                        // the largest system text sizes; shrinking beats truncating.
                        .minimumScaleFactor(0.75)
                }
                badge
            }
            .foregroundStyle(isSelected ? DS.ink : DS.inkMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? DS.surface : Color.clear)
                    .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected ? DS.surfaceStroke : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            // Scoped to just this pill's own fill/stroke/shadow, not to selectProvider's
            // effect on the rest of the panel — the body below switches instantly (see the
            // note on the button action above), so only the highlight itself needs to ease.
            .animation(.easeOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The live preview line. Always occupies its row, on every tab, so the four pills stay
    /// the same height and the row does not jump as the selection moves. A tab with nothing
    /// to report shows a placeholder rather than collapsing.
    @ViewBuilder
    private var badge: some View {
        if hasError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DS.tight)
                .frame(height: 12)
        } else if let remaining {
            Text("\(Int(remaining.rounded()))%")
                .font(DS.figure(10.5, weight: .semibold))
                // Muted on the selected tab: the same number is the hero directly below, so
                // here it is orientation rather than the headline.
                .foregroundStyle(isSelected ? DS.inkFaint : DS.accent(severity))
                .monospacedDigit()
                .frame(height: 12)
        } else {
            Text("—")
                .font(DS.figure(10.5, weight: .semibold))
                .foregroundStyle(DS.inkFaint)
                .frame(height: 12)
        }
    }

    private var dotColor: Color {
        if needsAttention { return DS.tight }
        if hasError { return DS.tight }
        guard remaining != nil else { return DS.inkFaint }
        return DS.accent(severity)
    }

    private var accessibilityLabel: String {
        var parts = [provider.displayName]
        if let remaining { parts.append("\(Int(remaining.rounded())) percent left") }
        if hasError { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}
