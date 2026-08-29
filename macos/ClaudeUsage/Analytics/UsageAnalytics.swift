import Foundation

/// One recorded observation. Deliberately tiny: a week of 2-minute samples is ~5000 entries,
/// so the on-disk representation stays well under a megabyte.
public struct UsageSample: Sendable, Codable, Equatable {
    /// Older samples have no provider field and decode as Claude.
    public let provider: UsageProvider
    public let t: Date
    /// limit id → percent
    public let limits: [String: Double]
    /// Spend percent, when the account exposes spend.
    public let spend: Double?
    /// Claude Code projects that were working when this sample was taken.
    ///
    /// Recorded at sample time rather than reconstructed later: the hook's own state is
    /// ephemeral (session files vanish when the process dies), so the only reliable record of
    /// "who was busy at 14:32" is the one written at 14:32.
    public let activeProjects: [String]

    public init(
        t: Date,
        limits: [String: Double],
        spend: Double? = nil,
        provider: UsageProvider = .claude,
        activeProjects: [String] = []
    ) {
        self.provider = provider
        self.t = t
        self.limits = limits
        self.spend = spend
        self.activeProjects = activeProjects
    }

    public static func from(
        _ snapshot: UsageSnapshot,
        activeProjects: [String] = []
    ) -> UsageSample {
        UsageSample(
            t: snapshot.fetchedAt,
            limits: Dictionary(
                snapshot.limits.map { ($0.id, $0.percent) },
                uniquingKeysWith: { a, _ in a }
            ),
            spend: snapshot.spend?.percent,
            provider: snapshot.provider,
            activeProjects: activeProjects
        )
    }

    private enum CodingKeys: String, CodingKey {
        case provider, t, limits, spend, activeProjects
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(UsageProvider.self, forKey: .provider) ?? .claude
        t = try c.decode(Date.self, forKey: .t)
        limits = try c.decodeIfPresent([String: Double].self, forKey: .limits) ?? [:]
        spend = try c.decodeIfPresent(Double.self, forKey: .spend)
        // Absent on samples written before attribution existed.
        activeProjects = try c.decodeIfPresent([String].self, forKey: .activeProjects) ?? []
    }
}

/// What we can say about how fast a limit is being consumed. Every field is optional
/// precisely so the UI can say "not enough data" instead of showing a fabricated number.
public struct BurnRate: Sendable, Equatable {
    /// Percentage points consumed per hour.
    public let perHour: Double
    /// How many samples the estimate is based on.
    public let sampleCount: Int
    /// The wall-clock span those samples cover.
    public let span: TimeInterval
    /// Coefficient of determination of the linear fit, 0...1. Low values mean bursty usage.
    public let fitQuality: Double

    public var perDay: Double { perHour * 24 }
    public var isMeaningful: Bool { perHour > 0.01 }
}

public struct UsageProjection: Sendable, Equatable {
    public let limitID: String
    public let currentPercent: Double
    public let burnRate: BurnRate?
    /// Projected utilisation at the reset instant, if a rate and a reset time are known.
    public let projectedAtReset: Double?
    /// Time until the limit reaches 100 %, if it is on course to.
    public let timeToExhaustion: TimeInterval?
    public let timeUntilReset: TimeInterval?
    /// True when the projection says the ceiling arrives before the reset does.
    public var willExhaustBeforeReset: Bool {
        guard let timeToExhaustion, let timeUntilReset else { return false }
        return timeToExhaustion < timeUntilReset
    }
    /// Nothing reliable can be said yet.
    public var isIndeterminate: Bool { burnRate == nil }
}

public enum UsageAnalytics {
    /// Minimum evidence before we are willing to state a rate.
    public static let minimumSamples = 3
    /// Floor on observed time, regardless of how short the quota window is.
    public static let minimumSpan: TimeInterval = 300
    /// …and, on top of that floor, this fraction of the window must have been observed.
    ///
    /// A flat five minutes is fine for a 5-hour session but nowhere near enough for a 7-day
    /// window: extrapolating ten minutes of heavy use into "93%/day" is a confident-looking
    /// number with almost nothing behind it. 2% of the window means ~6 minutes for the
    /// session limit and ~3.4 hours for the weekly one.
    public static let minimumSpanFraction = 0.02

    /// Nominal length of a quota window, where we know it.
    public static func windowLength(for group: LimitGroup) -> TimeInterval? {
        switch group {
        case .session: return 5 * 3600
        case .weekly: return 7 * 86_400
        case .other: return nil
        }
    }

    public static func windowLength(for limit: LimitWindow) -> TimeInterval? {
        if let duration = limit.windowDuration, duration > 0 { return duration }
        return windowLength(for: limit.group)
    }

    /// How much history a given limit needs before its trend is worth stating.
    public static func requiredSpan(for limit: LimitWindow) -> TimeInterval {
        guard let length = windowLength(for: limit) else { return minimumSpan }
        return max(minimumSpan, length * minimumSpanFraction)
    }

    /// Samples belonging to the *current* quota window for `limitID`.
    ///
    /// A quota reset makes utilisation fall off a cliff. Averaging across that boundary would
    /// report a negative or absurdly low burn rate, so we cut the series at the last drop.
    public static func currentWindowSamples(
        _ samples: [UsageSample],
        limitID: String,
        provider: UsageProvider = .claude,
        windowStart: Date? = nil,
        dropTolerance: Double = 5
    ) -> [(Date, Double)] {
        var series: [(Date, Double)] = samples
            .filter { $0.provider == provider }
            .compactMap { s in s.limits[limitID].map { (s.t, $0) } }
            .sorted { $0.0 < $1.0 }

        if let windowStart {
            series = series.filter { $0.0 >= windowStart }
        }

        // Walk backwards to the most recent point where the value fell materially — that is
        // where the current window began.
        guard series.count > 1 else { return series }
        var cutIndex = 0
        for i in stride(from: series.count - 1, to: 0, by: -1) {
            if series[i - 1].1 - series[i].1 > dropTolerance {
                cutIndex = i
                break
            }
        }
        return Array(series[cutIndex...])
    }

    /// Least-squares slope over the window, in percentage points per hour.
    public static func burnRate(
        _ samples: [UsageSample],
        limitID: String,
        provider: UsageProvider = .claude,
        windowStart: Date? = nil,
        requiredSpan: TimeInterval = minimumSpan
    ) -> BurnRate? {
        let series = currentWindowSamples(
            samples, limitID: limitID, provider: provider, windowStart: windowStart
        )
        return burnRate(series: series, requiredSpan: requiredSpan)
    }

    static func burnRate(
        series: [(Date, Double)],
        requiredSpan: TimeInterval = minimumSpan
    ) -> BurnRate? {
        guard series.count >= minimumSamples else { return nil }
        guard let first = series.first, let last = series.last else { return nil }
        let span = last.0.timeIntervalSince(first.0)
        guard span >= max(minimumSpan, requiredSpan) else { return nil }

        // x in hours since the first sample, y in percent.
        let xs = series.map { $0.0.timeIntervalSince(first.0) / 3600 }
        let ys = series.map(\.1)
        let n = Double(series.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n

        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<series.count {
            let dx = xs[i] - meanX
            let dy = ys[i] - meanY
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 0 else { return nil }

        let slope = sxy / sxx
        // r² — 1 when usage is perfectly linear, near 0 when it is bursty. A flat series
        // (syy == 0) is a perfect fit of a zero slope.
        let r2 = syy > 0 ? min(1, max(0, (sxy * sxy) / (sxx * syy))) : 1

        return BurnRate(
            perHour: max(0, slope),
            sampleCount: series.count,
            span: span,
            fitQuality: r2
        )
    }

    public static func projection(
        for limit: LimitWindow,
        samples: [UsageSample],
        now: Date
    ) -> UsageProjection {
        // Only consider samples inside the current window. If we know when the window opened
        // (reset time minus its nominal length) we can be stricter still.
        let rate = burnRate(
            samples,
            limitID: limit.id,
            provider: limit.provider,
            windowStart: windowStart(for: limit),
            requiredSpan: requiredSpan(for: limit)
        )
        let untilReset = limit.timeUntilReset(now: now)

        var projected: Double?
        var toExhaustion: TimeInterval?

        if let rate, rate.isMeaningful {
            if let untilReset {
                projected = limit.percent + rate.perHour * (untilReset / 3600)
            }
            if limit.percent < 100 {
                let hours = (100 - limit.percent) / rate.perHour
                if hours.isFinite && hours >= 0 {
                    toExhaustion = hours * 3600
                }
            } else {
                toExhaustion = 0
            }
        }

        return UsageProjection(
            limitID: limit.id,
            currentPercent: limit.percent,
            burnRate: rate,
            projectedAtReset: projected,
            timeToExhaustion: toExhaustion,
            timeUntilReset: untilReset
        )
    }

    /// The instant the current quota window opened, derived from its reset time and the
    /// window length implied by `group`. Returns nil for windows of unknown length.
    public static func windowStart(for limit: LimitWindow) -> Date? {
        guard let resetsAt = limit.resetsAt, let length = windowLength(for: limit) else {
            return nil
        }
        return resetsAt.addingTimeInterval(-length)
    }

    /// Average consumption per day over the window so far — the figure the weekly section
    /// shows, which is more legible than a per-hour rate for a 7-day window.
    public static func averagePerDay(
        _ samples: [UsageSample],
        limit: LimitWindow,
        now: Date
    ) -> Double? {
        guard let start = windowStart(for: limit) else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 3600 else { return nil }
        // Prefer measured usage over the assumption that the window started at 0 %.
        let series = currentWindowSamples(
            samples, limitID: limit.id, provider: limit.provider, windowStart: start
        )
        if let first = series.first, series.count >= minimumSamples {
            let span = now.timeIntervalSince(first.0)
            // Same proportional guard as the burn rate: a 7-day average extrapolated from
            // minutes of history is a fabrication, not an estimate.
            guard span >= requiredSpan(for: limit) else { return nil }
            return (limit.percent - first.1) / (span / 86_400)
        }
        return limit.percent / (elapsed / 86_400)
    }

    /// Detects a sudden acceleration: the most recent leg is much steeper than the window
    /// average. Used for the "usage suddenly increasing" alert.
    public static func isSurging(
        _ samples: [UsageSample],
        limit: LimitWindow,
        multiplier: Double = 3,
        minimumRecentRate: Double = 5
    ) -> Bool {
        let series = currentWindowSamples(
            samples, limitID: limit.id, provider: limit.provider,
            windowStart: windowStart(for: limit)
        )
        guard series.count >= minimumSamples + 1 else { return false }
        // A "surge" only means something relative to an established baseline.
        guard let start = series.first, let end = series.last,
              end.0.timeIntervalSince(start.0) >= requiredSpan(for: limit)
        else { return false }
        guard let a = series.dropLast().last, let b = series.last else { return false }
        let dt = b.0.timeIntervalSince(a.0)
        guard dt >= 60 else { return false }
        let recent = (b.1 - a.1) / (dt / 3600)
        guard recent >= minimumRecentRate else { return false }
        guard let overall = burnRate(series: Array(series.dropLast())), overall.perHour > 0.01 else {
            return recent >= minimumRecentRate
        }
        return recent > overall.perHour * multiplier
    }

    /// Highest value seen for a limit within the retained history.
    public static func peak(
        _ samples: [UsageSample], limitID: String, provider: UsageProvider = .claude
    ) -> (Date, Double)? {
        samples
            .filter { $0.provider == provider }
            .compactMap { s in s.limits[limitID].map { (s.t, $0) } }
            .max { $0.1 < $1.1 }
    }

    /// How long the reported value has been unchanged — "time since last API usage change".
    public static func timeSinceChange(
        _ samples: [UsageSample],
        limitID: String,
        provider: UsageProvider = .claude,
        now: Date,
        epsilon: Double = 0.01
    ) -> TimeInterval? {
        let series = samples
            .filter { $0.provider == provider }
            .compactMap { s in s.limits[limitID].map { (s.t, $0) } }
            .sorted { $0.0 < $1.0 }
        guard let last = series.last else { return nil }
        var changedAt = last.0
        for i in stride(from: series.count - 1, to: 0, by: -1) {
            if abs(series[i].1 - series[i - 1].1) > epsilon {
                changedAt = series[i].0
                break
            }
            changedAt = series[i - 1].0
        }
        return max(0, now.timeIntervalSince(changedAt))
    }
}

// MARK: - Pace

/// Whether consumption is ahead of or behind an even burn for the window.
///
/// "62% used" means nothing without knowing how far into the week you are. Spending 62% by
/// Wednesday is trouble; by Sunday it is fine. Pace answers that in one number.
public struct UsagePace: Sendable, Equatable {
    /// 0...1 of the window elapsed.
    public let windowElapsed: Double
    /// Percentage points actually used.
    public let used: Double
    /// Percentage points an even burn would have used by now.
    public let expected: Double
    /// used − expected. Positive means burning faster than even.
    public var delta: Double { used - expected }

    /// Ahead/behind expressed against the even-burn line, e.g. 1.4 = 40% faster than even.
    public var ratio: Double? {
        guard expected > 0.5 else { return nil }
        return used / expected
    }

    /// Small deviations are noise, not signal.
    public var isOnPace: Bool { abs(delta) < 5 }

    public var summary: String {
        if isOnPace { return "On pace" }
        let word = delta > 0 ? "ahead of" : "behind"
        return "\(Int(abs(delta).rounded()))% \(word) an even burn"
    }
}

extension UsageAnalytics {
    /// Pace for a limit, from the window's own length. Returns nil when the window length is
    /// unknown or the window has barely started, where the figure would be meaningless.
    public static func pace(for limit: LimitWindow, now: Date) -> UsagePace? {
        guard let resetsAt = limit.resetsAt, let length = windowLength(for: limit), length > 0
        else { return nil }

        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = (length - remaining) / length
        // The first few percent of a window cannot support a pace claim: one early request
        // reads as "1000% ahead".
        guard elapsed > 0.05, elapsed <= 1 else { return nil }

        return UsagePace(
            windowElapsed: elapsed,
            used: limit.percent,
            expected: elapsed * 100
        )
    }
}

// MARK: - Go / no-go

/// Whether there is room to start a piece of work of a given size.
public struct RunwayVerdict: Sendable, Equatable {
    public enum Call: String, Sendable {
        /// Comfortably enough quota.
        case go
        /// Enough, but not much spare.
        case tight
        /// Would run out partway through.
        case stop
        /// No burn-rate estimate yet, so no honest answer.
        case unknown
    }

    public let call: Call
    /// Percentage points estimated for the task.
    public let estimatedCost: Double
    /// Percentage points available before the ceiling.
    public let headroom: Double
    public let detail: String
}

extension UsageAnalytics {
    /// Estimates whether a task of `minutes` can finish before the limit is reached.
    ///
    /// Deliberately conservative and deliberately refuses to answer without evidence: the
    /// whole point is to avoid starting an hour of agent work that dies at minute forty.
    public static func verdict(
        for limit: LimitWindow,
        taskMinutes: Double,
        samples: [UsageSample],
        now: Date
    ) -> RunwayVerdict {
        let headroom = max(0, 100 - limit.percent)
        guard taskMinutes > 0 else {
            return RunwayVerdict(call: .unknown, estimatedCost: 0, headroom: headroom,
                                 detail: "No task length given")
        }

        guard let rate = burnRate(
            samples,
            limitID: limit.id,
            provider: limit.provider,
            windowStart: windowStart(for: limit),
            requiredSpan: requiredSpan(for: limit)
        ), rate.isMeaningful else {
            return RunwayVerdict(
                call: .unknown, estimatedCost: 0, headroom: headroom,
                detail: "Not enough history to estimate"
            )
        }

        let cost = rate.perHour * (taskMinutes / 60)
        // A reset partway through the task effectively refills the tank, so a task that
        // outlasts the window is judged only on the part before the reset.
        let untilReset = limit.timeUntilReset(now: now)
        let effectiveCost: Double = {
            guard let untilReset, untilReset < taskMinutes * 60 else { return cost }
            return rate.perHour * (untilReset / 3600)
        }()

        let call: RunwayVerdict.Call
        if effectiveCost > headroom { call = .stop }
        else if effectiveCost > headroom * 0.7 { call = .tight }
        else { call = .go }

        let detail: String
        switch call {
        case .stop:
            let affordable = rate.perHour > 0 ? headroom / rate.perHour * 60 : 0
            detail = "Only about \(Int(affordable.rounded()))m of runway at \(Format.rate(rate.perHour))"
        case .tight, .go:
            detail = "Needs ~\(Format.percentAtLeast(effectiveCost)) of the \(Format.percent(headroom)) left"
        case .unknown:
            detail = ""
        }

        return RunwayVerdict(
            call: call, estimatedCost: effectiveCost, headroom: headroom, detail: detail
        )
    }
}
