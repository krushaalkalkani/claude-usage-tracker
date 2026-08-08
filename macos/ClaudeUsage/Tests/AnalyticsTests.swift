import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite("Usage analytics")
struct AnalyticsTests {
    private let start = Date.fixedNow.plus(hours: -2)

    @Test("a steady climb produces the right rate")
    func steadyRate() {
        let samples = linearSamples(
            limitID: "session", from: start, count: 13, everyMinutes: 10,
            startPercent: 10, perHour: 6
        )
        let rate = try! #require(UsageAnalytics.burnRate(samples, limitID: "session"))
        #expect(abs(rate.perHour - 6) < 0.001)
        #expect(rate.sampleCount == 13)
        #expect(rate.fitQuality > 0.99)
        #expect(abs(rate.perDay - 144) < 0.1)
    }

    @Test("too few samples means no rate at all, not a guess")
    func insufficientSamples() {
        let samples = linearSamples(
            limitID: "session", from: start, count: 2, everyMinutes: 10,
            startPercent: 10, perHour: 6
        )
        #expect(UsageAnalytics.burnRate(samples, limitID: "session") == nil)
    }

    @Test("samples spanning too little time produce no rate")
    func insufficientSpan() {
        // Four samples 30s apart: enough points, not enough elapsed time to be meaningful.
        let samples = linearSamples(
            limitID: "session", from: start, count: 4, everyMinutes: 0.5,
            startPercent: 10, perHour: 6
        )
        #expect(UsageAnalytics.burnRate(samples, limitID: "session") == nil)
    }

    @Test("a quota reset does not poison the rate")
    func resetBoundary() {
        // Climb to 90%, reset to 2%, then climb again at a different rate.
        var samples = linearSamples(
            limitID: "session", from: start, count: 8, everyMinutes: 10,
            startPercent: 55, perHour: 12
        )
        let afterReset = start.plus(minutes: 80)
        samples += linearSamples(
            limitID: "session", from: afterReset, count: 6, everyMinutes: 10,
            startPercent: 2, perHour: 4
        )

        let rate = try! #require(UsageAnalytics.burnRate(samples, limitID: "session"))
        // Averaging across the drop would report something near zero or negative; we want the
        // post-reset slope only.
        #expect(abs(rate.perHour - 4) < 0.2)
        #expect(rate.sampleCount == 6)
    }

    @Test("a falling series never reports a negative burn rate")
    func negativeSlopeClamped() {
        let samples = linearSamples(
            limitID: "session", from: start, count: 6, everyMinutes: 20,
            startPercent: 50, perHour: -4
        )
        // The drop-detector will cut the series; whatever survives must not be negative.
        if let rate = UsageAnalytics.burnRate(samples, limitID: "session") {
            #expect(rate.perHour >= 0)
        }
    }

    @Test("a flat series is a valid zero rate, not a failure")
    func flatSeries() {
        let samples = linearSamples(
            limitID: "session", from: start, count: 8, everyMinutes: 15,
            startPercent: 40, perHour: 0
        )
        let rate = try! #require(UsageAnalytics.burnRate(samples, limitID: "session"))
        #expect(rate.perHour == 0)
        #expect(!rate.isMeaningful)
    }

    @Test("projection extrapolates to the reset instant")
    func projectionAtReset() {
        let limit = makeLimit(percent: 40, resetsAt: Date.fixedNow.plus(hours: 2.5))
        let samples = linearSamples(
            limitID: limit.id, from: Date.fixedNow.plus(hours: -2), count: 13,
            everyMinutes: 10, startPercent: 16, perHour: 12
        )
        let p = UsageAnalytics.projection(for: limit, samples: samples, now: .fixedNow)
        // 40% now + 12%/h × 2.5h = 70%.
        #expect(abs((p.projectedAtReset ?? 0) - 70) < 1)
        #expect(p.willExhaustBeforeReset == false)
    }

    @Test("exhaustion before reset is detected")
    func exhaustionBeforeReset() {
        let limit = makeLimit(percent: 82, resetsAt: Date.fixedNow.plus(hours: 2.67))
        let samples = linearSamples(
            limitID: limit.id, from: Date.fixedNow.plus(hours: -2), count: 13,
            everyMinutes: 10, startPercent: 54, perHour: 14
        )
        let p = UsageAnalytics.projection(for: limit, samples: samples, now: .fixedNow)
        let eta = try! #require(p.timeToExhaustion)
        // (100 - 82) / 14 h ≈ 1h17m.
        #expect(abs(eta - 4628) < 120)
        #expect(p.willExhaustBeforeReset)
    }

    @Test("a 7-day window needs hours of history, not minutes, before it states a trend")
    func weeklyNeedsMoreEvidenceThanSession() {
        // Ten minutes of steep usage — plenty for the 5-hour window, nowhere near enough to
        // claim a per-day average across seven days.
        let start = Date.fixedNow.plus(minutes: -10)

        let session = makeLimit(percent: 67, resetsAt: Date.fixedNow.plus(hours: 1))
        let sessionSamples = linearSamples(
            limitID: session.id, from: start, count: 6, everyMinutes: 2,
            startPercent: 60, perHour: 44
        )
        let sessionProjection = UsageAnalytics.projection(
            for: session, samples: sessionSamples, now: .fixedNow
        )
        #expect(!sessionProjection.isIndeterminate, "the session limit should still report")

        let weekly = makeLimit(
            id: "weekly_all", kind: "weekly_all", group: .weekly,
            percent: 36, resetsAt: Date.fixedNow.plus(days: 5)
        )
        let weeklySamples = linearSamples(
            limitID: weekly.id, from: start, count: 6, everyMinutes: 2,
            startPercent: 34, perHour: 12
        )
        let weeklyProjection = UsageAnalytics.projection(
            for: weekly, samples: weeklySamples, now: .fixedNow
        )
        #expect(weeklyProjection.isIndeterminate, "10 minutes should not yield a 7-day trend")
        #expect(UsageAnalytics.averagePerDay(weeklySamples, limit: weekly, now: .fixedNow) == nil)
        #expect(!UsageAnalytics.isSurging(weeklySamples, limit: weekly))
    }

    @Test("required evidence scales with the window length")
    func requiredSpanScales() {
        let session = makeLimit(percent: 10, resetsAt: nil)
        let weekly = makeLimit(
            id: "w", kind: "weekly_all", group: .weekly, percent: 10, resetsAt: nil
        )
        // 2% of 5h ≈ 6 min, 2% of 7d ≈ 3.4 h.
        #expect(UsageAnalytics.requiredSpan(for: session) == 360)
        #expect(abs(UsageAnalytics.requiredSpan(for: weekly) - 12_096) < 1)

        // An unknown window length falls back to the flat floor rather than guessing.
        let odd = makeLimit(
            id: "x", kind: "monthly_experimental", group: .other, percent: 10, resetsAt: nil
        )
        #expect(UsageAnalytics.requiredSpan(for: odd) == UsageAnalytics.minimumSpan)
    }

    @Test("once a weekly window has hours of history the trend comes back")
    func weeklyReportsWithEnoughHistory() {
        let weekly = makeLimit(
            id: "weekly_all", kind: "weekly_all", group: .weekly,
            percent: 36, resetsAt: Date.fixedNow.plus(days: 5)
        )
        // Six hours of samples — comfortably past the 3.4-hour requirement.
        let samples = linearSamples(
            limitID: weekly.id, from: Date.fixedNow.plus(hours: -6), count: 37,
            everyMinutes: 10, startPercent: 24, perHour: 2
        )
        let p = UsageAnalytics.projection(for: weekly, samples: samples, now: .fixedNow)
        #expect(!p.isIndeterminate)
        #expect(abs((p.burnRate?.perHour ?? 0) - 2) < 0.1)
    }

    @Test("with no history a projection is explicitly indeterminate")
    func indeterminate() {
        let limit = makeLimit(percent: 50, resetsAt: Date.fixedNow.plus(hours: 1))
        let p = UsageAnalytics.projection(for: limit, samples: [], now: .fixedNow)
        #expect(p.isIndeterminate)
        #expect(p.projectedAtReset == nil)
        #expect(p.timeToExhaustion == nil)
        #expect(p.willExhaustBeforeReset == false)
    }

    @Test("a limit already at 100% reports zero time remaining")
    func alreadyExhausted() {
        let limit = makeLimit(percent: 100, resetsAt: Date.fixedNow.plus(hours: 1))
        let samples = linearSamples(
            limitID: limit.id, from: Date.fixedNow.plus(hours: -2), count: 13,
            everyMinutes: 10, startPercent: 76, perHour: 12
        )
        let p = UsageAnalytics.projection(for: limit, samples: samples, now: .fixedNow)
        #expect(p.timeToExhaustion == 0)
    }

    @Test("weekly average per day uses measured samples when available")
    func averagePerDay() {
        let weekly = makeLimit(
            id: "weekly_all", kind: "weekly_all", group: .weekly,
            percent: 35, resetsAt: Date.fixedNow.plus(days: 4)
        )
        let samples = linearSamples(
            limitID: weekly.id, from: Date.fixedNow.plus(days: -2), count: 20,
            everyMinutes: 144, startPercent: 15, perHour: 0.4167
        )
        let avg = try! #require(UsageAnalytics.averagePerDay(samples, limit: weekly, now: .fixedNow))
        // ~10 points/day.
        #expect(abs(avg - 10) < 1.5)
    }

    @Test("surge detection needs a real acceleration")
    func surge() {
        let id = "session"
        var samples = linearSamples(
            limitID: id, from: start, count: 8, everyMinutes: 10,
            startPercent: 40, perHour: 2
        )
        #expect(!UsageAnalytics.isSurging(samples, limit: makeLimit(percent: 42, resetsAt: nil)))

        // A sudden 12-point jump in 10 minutes = 72%/h.
        let last = samples.last!
        samples.append(
            UsageSample(t: last.t.plus(minutes: 10), limits: [id: last.limits[id]! + 12])
        )
        #expect(UsageAnalytics.isSurging(samples, limit: makeLimit(percent: 55, resetsAt: nil)))
    }

    @Test("peak and time-since-change read the retained history")
    func peakAndStillness() {
        let id = "session"
        let samples = [
            UsageSample(t: start, limits: [id: 20]),
            UsageSample(t: start.plus(minutes: 20), limits: [id: 61]),
            UsageSample(t: start.plus(minutes: 40), limits: [id: 44]),
            UsageSample(t: start.plus(minutes: 60), limits: [id: 44]),
            UsageSample(t: start.plus(minutes: 80), limits: [id: 44]),
        ]
        #expect(UsageAnalytics.peak(samples, limitID: id)?.1 == 61)
        let still = try! #require(
            UsageAnalytics.timeSinceChange(samples, limitID: id, now: start.plus(minutes: 90))
        )
        // Unchanged since the 40-minute sample.
        #expect(abs(still - 3000) < 1)
    }

    @Test("durations format compactly at every scale")
    func durationFormatting() {
        #expect(Format.duration(45) == "45s")
        #expect(Format.duration(12 * 60) == "12m")
        #expect(Format.duration(2 * 3600 + 28 * 60) == "2h 28m")
        #expect(Format.duration(5 * 86_400 + 2 * 3600) == "5d 2h")
        #expect(Format.duration(3 * 86_400) == "3d")
        #expect(Format.duration(-10) == "0s")
    }
}
