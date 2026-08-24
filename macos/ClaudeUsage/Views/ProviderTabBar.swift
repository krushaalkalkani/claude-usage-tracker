import SwiftUI
import ClaudeUsageCore

/// Claude and ChatGPT as two genuinely separate tabs.
///
/// The panel used to merge both into one ranked list — technically tidy, but it meant you
/// could never look at "just Claude" or "just ChatGPT" the way the mental model of two
/// separate subscriptions actually works. This restores the split, and goes further: each
/// tab, even when not selected, carries its own live status dot and tightest-limit badge, so
/// switching is optional for the headline number and only required for the detail underneath.
struct ProviderTabBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsageProvider.allCases) { provider in
                TabButton(
                    provider: provider,
                    isSelected: model.selectedProvider == provider,
                    percent: model.providerTightestPercent(provider, now: model.tick),
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
    let percent: Double?
    let severity: Severity
    let hasError: Bool
    let needsAttention: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                StatusDot(color: dotColor)
                Text(provider.displayName)
                    .font(DS.label(12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                badge
            }
            .foregroundStyle(isSelected ? DS.ink : DS.inkMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
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

    /// The live preview on an unselected tab — the new bit. Selected tabs skip it: the full
    /// detail is already on screen underneath, so repeating the number would be noise.
    @ViewBuilder
    private var badge: some View {
        if hasError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DS.tight)
        } else if !isSelected, let percent {
            Text("\(Int(percent.rounded()))%")
                .font(DS.figure(10.5, weight: .semibold))
                .foregroundStyle(DS.accent(severity))
                .monospacedDigit()
        }
    }

    private var dotColor: Color {
        if needsAttention { return DS.tight }
        if hasError { return DS.tight }
        guard percent != nil else { return DS.inkFaint }
        return DS.accent(severity)
    }

    private var accessibilityLabel: String {
        var parts = [provider.displayName]
        if let percent { parts.append("\(Int(percent.rounded())) percent") }
        if hasError { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }
}
