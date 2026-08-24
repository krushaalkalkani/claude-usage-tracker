import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite("Pace and go/no-go")
struct PaceAndVerdictTests {

    private func weekly(percent: Double, resetsIn days: Double) -> LimitWindow {
        LimitWindow(
            id: "weekly_all", kind: "weekly_all", group: .weekly,
            title: "7-day limit", shortTitle: "Weekly",
            percent: percent,
            resetsAt: Date.fixedNow.addingTimeInterval(days * 86_400),
            severity: .normal
        )
    }

    // MARK: Pace

    @Test("pace compares usage against how much of the window has elapsed")
    func paceAgainstEvenBurn() throws {
        // 3 days into a 7-day window ≈ 43% elapsed. 43% used would be exactly even.
        let onPace = try #require(
            UsageAnalytics.pace(for: weekly(percent: 43, resetsIn: 4), now: .fixedNow)
        )
        #expect(onPace.isOnPace)
        #expect(onPace.summary == "On pace")

        // Same point in the week, but 70% spent.
        let hot = try #require(
            UsageAnalytics.pace(for: weekly(percent: 70, resetsIn: 4), now: .fixedNow)
        )
        #expect(!hot.isOnPace)
        #expect(hot.delta > 0)
        #expect(hot.summary.contains("ahead"))

        // …and 20% spent.
        let cool = try #require(
            UsageAnalytics.pace(for: weekly(percent: 20, resetsIn: 4), now: .fixedNow)
        )
        #expect(cool.delta < 0)
        #expect(cool.summary.contains("behind"))
    }

    @Test("no pace claim in the opening moments of a window")
    func refusesEarlyInWindow() {
        // Two hours into seven days. A single early request would read as wildly ahead.
        #expect(UsageAnalytics.pace(for: weekly(percent: 3, resetsIn: 6.9), now: .fixedNow) == nil)
    }

    @Test("no pace claim without a reset time")
    func requiresWindow() {
        let noReset = LimitWindow(
            id: "x", kind: "weekly_all", group: .weekly, title: "t", shortTitle: "t",
            percent: 50, resetsAt: nil, severity: .normal
        )
        #expect(UsageAnalytics.pace(for: noReset, now: .fixedNow) == nil)
    }

    // MARK: Go / no-go

    private func samples(id: String, perHour: Double, hours: Double, endingAt end: Double)
        -> [UsageSample] {
        stride(from: 0.0, through: hours, by: 0.1).map { h in
            UsageSample(
                t: Date.fixedNow.addingTimeInterval((h - hours) * 3600),
                limits: [id: max(0, end - perHour * (hours - h))]
            )
        }
    }

    @Test("a task that fits gets a go")
    func goWhenAffordable() {
        let limit = LimitWindow(
            id: "session", kind: "session", group: .session, title: "5-hour", shortTitle: "S",
            percent: 20, resetsAt: Date.fixedNow.addingTimeInterval(4 * 3600), severity: .normal
        )
        // 6%/h for 30 minutes = 3%, against 80% headroom.
        let v = UsageAnalytics.verdict(
            for: limit, taskMinutes: 30,
            samples: samples(id: "session", perHour: 6, hours: 2, endingAt: 20), now: .fixedNow
        )
        #expect(v.call == .go)
    }

    @Test("a task that would run out gets a stop, with the real runway")
    func stopWhenItWouldExhaust() {
        let limit = LimitWindow(
            id: "session", kind: "session", group: .session, title: "5-hour", shortTitle: "S",
            percent: 90, resetsAt: Date.fixedNow.addingTimeInterval(4 * 3600), severity: .critical
        )
        // 40%/h with 10% left: about 15 minutes of runway, so an hour is out.
        let v = UsageAnalytics.verdict(
            for: limit, taskMinutes: 60,
            samples: samples(id: "session", perHour: 40, hours: 2, endingAt: 90), now: .fixedNow
        )
        #expect(v.call == .stop)
        #expect(v.detail.contains("15m") || v.detail.contains("14m") || v.detail.contains("16m"),
                "should quote the actual runway, got: \(v.detail)")
    }

    @Test("without a burn rate it says so rather than guessing")
    func unknownWithoutEvidence() {
        let limit = LimitWindow(
            id: "session", kind: "session", group: .session, title: "5-hour", shortTitle: "S",
            percent: 50, resetsAt: Date.fixedNow.addingTimeInterval(4 * 3600), severity: .normal
        )
        let v = UsageAnalytics.verdict(for: limit, taskMinutes: 60, samples: [], now: .fixedNow)
        #expect(v.call == .unknown)
        #expect(v.detail.contains("Not enough history"))
    }

    @Test("a reset partway through the task is counted as a refill, not a cost")
    func resetDuringTaskIsNotCharged() {
        // 30%/h, 40% headroom, but the window resets in 30 minutes: only 15% is actually
        // spent before the tank refills, so an hour-long task is fine.
        let limit = LimitWindow(
            id: "session", kind: "session", group: .session, title: "5-hour", shortTitle: "S",
            percent: 60, resetsAt: Date.fixedNow.addingTimeInterval(1_800), severity: .warning
        )
        let v = UsageAnalytics.verdict(
            for: limit, taskMinutes: 60,
            samples: samples(id: "session", perHour: 30, hours: 2, endingAt: 60), now: .fixedNow
        )
        #expect(v.estimatedCost < 20, "only the pre-reset portion counts, got \(v.estimatedCost)")
        #expect(v.call != .stop)
    }
}
