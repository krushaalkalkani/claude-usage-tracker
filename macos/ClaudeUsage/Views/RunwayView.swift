import SwiftUI
import ClaudeUsageCore

/// The runway strip — the one thing this panel is built around.
///
/// Every other usage tracker gives you three disconnected facts: *67% used*, *resets in 1h 4m*,
/// *burning 44%/h*. You then do the arithmetic in your head to answer the only question that
/// matters: **will I run out before it resets?**
///
/// This strip does the arithmetic. The scale runs from *now* to *the reset*. Lit ticks are how
/// far your current burn rate actually carries you; the unlit tail is time you will spend
/// blocked, with a raised tick at the moment you go dry.
struct RunwayView: View {
    let projection: UsageProjection
    let percent: Double
    let severity: Severity
    let resetsAt: Date?
    let now: Date

    private enum Outcome {
        case unknown
        case steady
        case lastsPastReset
        case runsDry(fraction: Double, dryFor: TimeInterval, inTime: TimeInterval)
        case exhausted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs + 2) {
            meter
            caption
        }
    }

    @ViewBuilder
    private var meter: some View {
        switch outcome {
        case .unknown:
            // Unlit scale. Deliberately inert — an empty progress bar would read as zero.
            TickMeter(fraction: 0, color: DS.inkFaint, height: 13)

        case .steady, .lastsPastReset:
            TickMeter(fraction: 1, color: DS.accent(severity), height: 13)

        case .exhausted:
            TickMeter(fraction: 0, color: DS.spent, breakpoint: 0, height: 13,
                      dimPastBreakpoint: true)

        case .runsDry(let fraction, _, _):
            TickMeter(
                fraction: fraction,
                color: DS.accent(severity),
                breakpoint: fraction,
                height: 13,
                dimPastBreakpoint: true
            )
        }
    }

    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            // Naming both ends makes it unambiguous that this scale is time, not quantity.
            Text("now")
                .font(DS.label(9.5))
                .foregroundStyle(DS.inkFaint)
            Text(headline)
                .font(DS.label(10.5, weight: .medium))
                .foregroundStyle(headlineColor)
            Spacer(minLength: 4)
            if let resetsAt {
                Text(Self.clock.string(from: resetsAt))
                    .font(DS.figure(10))
                    .foregroundStyle(DS.inkFaint)
            }
        }
    }

    private var outcome: Outcome {
        if percent >= 100 { return .exhausted }
        guard let rate = projection.burnRate else { return .unknown }
        guard rate.isMeaningful else { return .steady }
        guard let untilReset = projection.timeUntilReset, untilReset > 0 else { return .steady }
        guard let dry = projection.timeToExhaustion else { return .steady }
        if dry >= untilReset { return .lastsPastReset }
        return .runsDry(fraction: dry / untilReset, dryFor: untilReset - dry, inTime: dry)
    }

    private var headline: String {
        switch outcome {
        case .unknown: return "no trend yet"
        case .steady: return "holding steady"
        case .lastsPastReset: return "lasts past the reset"
        case .exhausted: return "at the limit until reset"
        case .runsDry(_, let dryFor, let inTime):
            return "dry in \(Format.duration(inTime)) · blocked \(Format.duration(dryFor))"
        }
    }

    private var headlineColor: Color {
        switch outcome {
        case .runsDry, .exhausted: return DS.spent
        case .unknown: return DS.inkFaint
        default: return DS.inkMuted
        }
    }

    /// Built once — this view redraws every second while the panel is open.
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
}
