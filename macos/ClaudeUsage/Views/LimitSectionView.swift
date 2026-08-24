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
        let period = limit.group == .session ? "5-hour" : "7-day"
        if let model = limit.modelName { return "\(model) · \(period)" }
        if let surface = limit.surface { return "\(surface) · \(period)" }
        switch limit.group {
        case .session: return "Session · 5-hour"
        case .weekly: return "Weekly · 7-day"
        case .other: return limit.kind.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// The quiet rows. Values align in a strict right-hand column so the eye scans straight down.
struct CompactLimitRow: View {
    let limit: LimitWindow
    let projection: UsageProjection?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.s) {
                Text(label)
                    .font(DS.label(12, weight: .medium))
                    .foregroundStyle(DS.ink)
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
