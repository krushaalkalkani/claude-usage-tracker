import SwiftUI
import ClaudeUsageCore

/// "3d 6h left", or "reset due" once the instant has passed — which happens whenever the panel
/// is showing cached values from before the window rolled over. "0s left" implied a live
/// countdown that had merely reached zero.
private func resetLabel(_ resetsAt: Date, now: Date) -> String {
    let remaining = resetsAt.timeIntervalSince(now)
    return remaining > 0 ? "\(Format.duration(remaining)) left" : "reset due"
}

/// The hero. One limit gets this treatment — whichever is closest to its ceiling — and
/// everything else is a quiet two-line row.
///
/// The headline figure is **what's left**, not what's used. Every tracker shows "67% used";
/// you plan against the 33%.
struct HeroLimitView: View {
    let limit: LimitWindow
    let projection: UsageProjection?
    let isTightest: Bool
    /// Name the provider in the eyebrow. Off when only one service is being tracked.
    var showsProvider: Bool = true
    /// Ahead of / behind an even burn for this window. Nil when the window has barely begun.
    var pace: UsagePace?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(periodLabel.uppercased())
                    .font(DS.eyebrow)
                    .kerning(DS.eyebrowKerning)
                    .foregroundStyle(DS.inkFaint)
                Spacer(minLength: 0)
                if isTightest {
                    Chip(text: "tightest", color: DS.accent(limit.severity))
                }
            }

            // The figure and its two qualifiers share one baseline, so the 46pt line box
            // cannot shove them apart — the previous version stacked them and they collided with
            // the chip.
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(limit.remainingPercent.rounded()))")
                    .font(DS.hero())
                    .tracking(-1.8)
                    .foregroundStyle(DS.accent(limit.severity))
                    .monospacedDigit()
                Text("%")
                    .font(DS.label(19, weight: .medium))
                    .foregroundStyle(DS.accent(limit.severity).opacity(0.45))
                    .padding(.trailing, 5)

                VStack(alignment: .leading, spacing: 1) {
                    Text("remaining")
                        .font(DS.label(11.5, weight: .medium))
                        .foregroundStyle(DS.ink)
                    Text("\(Int(limit.percent.rounded()))% used")
                        .font(DS.label(10.5))
                        .foregroundStyle(DS.inkFaint)
                }

                Spacer(minLength: DS.Space.s)

                if let resetsAt = limit.resetsAt {
                    Text(resetLabel(resetsAt, now: now))
                        .font(DS.figure(10.5))
                        .foregroundStyle(DS.inkMuted)
                }
            }

            if let projection {
                RunwayView(
                    projection: projection,
                    percent: limit.percent,
                    severity: limit.severity,
                    resetsAt: limit.resetsAt,
                    now: now
                )
            }

            if let pace {
                PaceBar(pace: pace, severity: limit.severity)
            }
        }
        .padding(DS.Space.m + 2)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DS.surfaceStroke, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 7, y: 2)
        )
        .panelRow()
    }

    private var periodLabel: String {
        // In a list spanning services, an unlabelled "WEEKLY · 7-DAY" hero is ambiguous.
        guard showsProvider else { return basePeriodLabel }
        // "ChatGPT · Weekly · 7-day" states the period twice; the short title is enough
        // once the provider is named.
        return "\(limit.provider.displayName) · \(limit.shortTitle)"
    }

    private var basePeriodLabel: String {
        let period = durationLabel
        if let model = limit.modelName { return "\(model) · \(period)" }
        if let surface = limit.surface { return "\(surface) · \(period)" }
        switch limit.group {
        case .session: return "Session · \(period)"
        case .weekly: return "Weekly · \(period)"
        case .other:
            return limit.shortTitle == limit.kind ? period : "\(limit.shortTitle) · \(period)"
        }
    }

    private var durationLabel: String {
        guard let seconds = limit.windowDuration, seconds > 0 else {
            switch limit.group {
            case .session: return "5-hour"
            case .weekly: return "7-day"
            case .other: return limit.kind.replacingOccurrences(of: "_", with: " ")
            }
        }
        if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 {
            return "\(Int(seconds / 86_400))-day"
        }
        if seconds >= 3_600, seconds.truncatingRemainder(dividingBy: 3_600) == 0 {
            return "\(Int(seconds / 3_600))-hour"
        }
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(Int(seconds / 60))-minute"
        }
        return Format.duration(seconds)
    }
}

/// The quiet rows. Values align in a strict right-hand column so the eye scans straight down.
struct CompactLimitRow: View {
    let limit: LimitWindow
    let projection: UsageProjection?
    let now: Date
    /// Prefixes the row with the provider. On by default: in one ranked list across services,
    /// "Weekly 49%" is ambiguous without saying whose weekly it is.
    var showsProvider: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.s) {
                HStack(spacing: 4) {
                    if showsProvider {
                        Text(limit.provider.displayName)
                            .font(DS.label(12))
                            .foregroundStyle(DS.inkFaint)
                        Text("·")
                            .font(DS.label(12))
                            .foregroundStyle(DS.inkFaint.opacity(0.6))
                    }
                    Text(label)
                        .font(DS.label(12, weight: .medium))
                        .foregroundStyle(DS.ink)
                }
                .lineLimit(1)

                if limit.isActive {
                    Chip(text: "active", color: DS.inkFaint)
                }

                Spacer(minLength: DS.Space.s)

                TickMeter(
                    fraction: limit.percent / 100,
                    color: DS.accent(limit.severity),
                    tickCount: 16,
                    height: 9,
                    tickWidth: 1.5
                )
                .frame(width: 78)

                Text("\(Int(limit.percent.rounded()))%")
                    .font(DS.figure(11.5, weight: .semibold))
                    .foregroundStyle(limit.severity == .normal ? DS.ink : DS.accent(limit.severity))
                    .frame(width: 38, alignment: .trailing)
            }

            if let detail {
                Text(detail)
                    .font(DS.label(10))
                    .foregroundStyle(DS.inkFaint)
            }
        }
        .panelRow()
    }

    private var label: String {
        if let model = limit.modelName { return model }
        if let surface = limit.surface { return surface }
        switch limit.group {
        case .session: return "Session"
        case .weekly: return "Weekly"
        case .other: return limit.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let resetsAt = limit.resetsAt {
            parts.append(resetLabel(resetsAt, now: now))
        }
        if let projection, let rate = projection.burnRate, rate.isMeaningful {
            if projection.willExhaustBeforeReset, let eta = projection.timeToExhaustion {
                parts.append("dry in \(Format.duration(eta))")
            } else if limit.group == .weekly {
                parts.append("\(String(format: "%.0f", rate.perHour * 24))%/day")
            } else {
                parts.append(Format.rate(rate.perHour))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Extra usage. Two figures and a reason — a meter added nothing they didn't already say.
struct SpendRow: View {
    let spend: SpendInfo

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Eyebrow(text: "Extra usage", detail: statusText)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(spend.used?.formatted ?? "—")
                    .font(DS.figure(15, weight: .semibold))
                    .foregroundStyle(spend.overage != nil ? DS.spent : DS.ink)
                if let limit = spend.limit {
                    Text("of \(limit.formatted)")
                        .font(DS.figure(11))
                        .foregroundStyle(DS.inkFaint)
                }
                Spacer(minLength: 4)
                if let over = spend.overage {
                    Text("over by \(over.formatted)")
                        .font(DS.figure(10.5, weight: .medium))
                        .foregroundStyle(DS.spent)
                }
            }
            if let reason = spend.disabledExplanation {
                Text(reason)
                    .font(DS.label(10))
                    .foregroundStyle(DS.inkFaint)
            }
        }
        .panelRow()
        .help(spend.disclaimer ?? "")
    }

    private var statusText: String {
        if spend.enabled { return "enabled" }
        if spend.limitReached == true { return "cap reached" }
        return "disabled"
    }
}


/// How consumption compares with an even burn across the window.
///
/// "62% used" is unreadable on its own — 62% by Wednesday is trouble, 62% by Sunday is fine.
/// The marker is where an even burn would be right now; the fill is where you actually are.
struct PaceBar: View {
    let pace: UsagePace
    let severity: Severity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.dim).frame(height: 3)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, w * min(pace.used / 100, 1)), height: 3)
                    // The even-burn marker.
                    Rectangle()
                        .fill(DS.inkMuted)
                        .frame(width: 1.5, height: 9)
                        .offset(x: w * min(pace.windowElapsed, 1) - 0.75)
                }
                .frame(height: 9)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 9)

            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .semibold))
                Text(pace.summary)
                    .font(DS.label(10.5, weight: .medium))
                Spacer(minLength: 0)
                Text("\(Int((pace.windowElapsed * 100).rounded()))% of window elapsed")
                    .font(DS.label(10))
                    .foregroundStyle(DS.inkFaint)
            }
            .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pace.summary), \(Int((pace.windowElapsed * 100).rounded())) percent of the window elapsed")
    }

    private var tint: Color {
        if pace.isOnPace { return DS.inkMuted }
        return pace.delta > 0 ? DS.accent(severity == .normal ? .warning : severity) : DS.healthy
    }

    private var symbol: String {
        if pace.isOnPace { return "equal.circle" }
        return pace.delta > 0 ? "arrow.up.right" : "arrow.down.right"
    }
}
