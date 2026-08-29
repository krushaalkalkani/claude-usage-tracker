import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite("Which limit binds first")
struct LimitConstraintTests {

    /// A projection describing "this window hits 100 % in `dryIn` hours, and resets in
    /// `resetIn` hours". Built directly rather than through `UsageAnalytics.projection` so
    /// each test states the situation it is about.
    private func projection(
        _ id: String, percent: Double, dryIn: Double?, resetIn: Double?
    ) -> UsageProjection {
        UsageProjection(
            limitID: id,
            currentPercent: percent,
            burnRate: BurnRate(perHour: 5, sampleCount: 10, span: 3600, fitQuality: 0.9),
            projectedAtReset: resetIn.map { percent + 5 * $0 },
            timeToExhaustion: dryIn.map { $0 * 3600 },
            timeUntilReset: resetIn.map { $0 * 3600 }
        )
    }

    // MARK: The bug this type exists for

    @Test("a session minutes from its reset does not outrank a weekly that runs dry first")
    func nearlyResetSessionDoesNotWin() throws {
        // Exactly the panel in the bug report: the 5-hour session is the highest number on
        // screen, but it refills in 21 minutes and cannot block anyone. The model window is
        // lower but is on course to hit its ceiling two days before its own reset.
        let session = makeLimit(
            id: "session", percent: 55, resetsAt: Date.fixedNow.plus(minutes: 21)
        )
        let fable = makeLimit(
            id: "weekly_scoped|m:fable", group: .weekly, percent: 46,
            resetsAt: Date.fixedNow.plus(days: 4.96), model: "Fable"
        )
        let ranked = try #require(LimitConstraint.rank(
            [session, fable],
            projections: [
                // Holds out past its reset — 0.35h of clock left, 9h of quota.
                "session": projection("session", percent: 55, dryIn: 9, resetIn: 0.35),
                // Dry in 2d 3h with 4d 23h still to run.
                "weekly_scoped|m:fable": projection(
                    "weekly_scoped|m:fable", percent: 46, dryIn: 51, resetIn: 119
                ),
            ]
        ))
        #expect(ranked.limit.id == "weekly_scoped|m:fable")
        #expect(ranked.reason == .runsDry)

        // Ranking on utilisation alone is what picked the session.
        #expect(makeSnapshot(limits: [session, fable]).bottleneck?.id == "session")
    }

    @Test("the soonest to run dry wins among several that will")
    func soonestDryWins() throws {
        let weekly = makeLimit(id: "weekly_all", group: .weekly, percent: 32,
                               resetsAt: Date.fixedNow.plus(days: 5))
        let fable = makeLimit(id: "fable", group: .weekly, percent: 46,
                              resetsAt: Date.fixedNow.plus(days: 5), model: "Fable")
        let ranked = try #require(LimitConstraint.rank(
            [weekly, fable],
            projections: [
                "weekly_all": projection("weekly_all", percent: 32, dryIn: 98, resetIn: 120),
                "fable": projection("fable", percent: 46, dryIn: 51, resetIn: 120),
            ]
        ))
        #expect(ranked.limit.id == "fable")
    }

    // MARK: Falling back

    @Test("with no projections it ranks on current utilisation")
    func fallsBackToUtilisation() throws {
        // A fresh launch has no history, so this is the common case rather than an edge one.
        let session = makeLimit(id: "session", percent: 55, resetsAt: Date.fixedNow.plus(hours: 1))
        let weekly = makeLimit(id: "weekly_all", group: .weekly, percent: 32,
                               resetsAt: Date.fixedNow.plus(days: 5))
        let ranked = try #require(LimitConstraint.rank([session, weekly]))
        #expect(ranked.limit.id == "session")
        #expect(ranked.reason == .tightest)
    }

    @Test("a window with a rate is judged on where it is heading, not where it sits")
    func ranksOnProjectedUtilisation() throws {
        // 20 % now but climbing to 80 % by the reset beats 45 % that is going nowhere.
        let climbing = makeLimit(id: "climbing", group: .weekly, percent: 20,
                                 resetsAt: Date.fixedNow.plus(days: 5))
        let flat = makeLimit(id: "flat", group: .weekly, percent: 45,
                             resetsAt: Date.fixedNow.plus(days: 5))
        let ranked = try #require(LimitConstraint.rank(
            [climbing, flat],
            projections: [
                "climbing": UsageProjection(
                    limitID: "climbing", currentPercent: 20,
                    burnRate: BurnRate(perHour: 0.5, sampleCount: 10, span: 7200, fitQuality: 0.9),
                    projectedAtReset: 80, timeToExhaustion: nil, timeUntilReset: 120 * 3600
                ),
                "flat": UsageProjection(
                    limitID: "flat", currentPercent: 45,
                    burnRate: BurnRate(perHour: 0, sampleCount: 10, span: 7200, fitQuality: 1),
                    projectedAtReset: 45, timeToExhaustion: nil, timeUntilReset: 120 * 3600
                ),
            ]
        ))
        #expect(ranked.limit.id == "climbing")
    }

    // MARK: Exhaustion

    @Test("a window already at the ceiling outranks everything")
    func exhaustedWins() throws {
        let spent = makeLimit(id: "spent", group: .other, percent: 100, resetsAt: nil)
        let dry = makeLimit(id: "dry", group: .weekly, percent: 60,
                            resetsAt: Date.fixedNow.plus(days: 5))
        let ranked = try #require(LimitConstraint.rank(
            [dry, spent],
            projections: ["dry": projection("dry", percent: 60, dryIn: 10, resetIn: 120)]
        ))
        #expect(ranked.limit.id == "spent")
        #expect(ranked.reason == .exhausted)
    }

    // MARK: Stability

    @Test("an exhaustion estimate landing on its own reset is not called running dry")
    func marginPreventsFlapping() throws {
        // Dry at 119h into a 120h window is the estimate agreeing with the reset, not a
        // warning. Without the margin this flips in and out of the hero slot every poll and
        // the panel — which resizes to its content — visibly jumps each time.
        let weekly = makeLimit(id: "weekly_all", group: .weekly, percent: 90,
                               resetsAt: Date.fixedNow.plus(days: 5))
        let ranked = try #require(LimitConstraint.rank(
            [weekly],
            projections: ["weekly_all": projection("weekly_all", percent: 90,
                                                   dryIn: 119, resetIn: 120)]
        ))
        #expect(ranked.reason == .tightest)

        // Comfortably before the reset, it is a real warning.
        let early = try #require(LimitConstraint.rank(
            [weekly],
            projections: ["weekly_all": projection("weekly_all", percent: 90,
                                                   dryIn: 40, resetIn: 120)]
        ))
        #expect(early.reason == .runsDry)
    }

    @Test("ties go to the window the provider marked active")
    func activeWindowBreaksTies() throws {
        let idle = makeLimit(id: "idle", group: .weekly, percent: 50,
                             resetsAt: Date.fixedNow.plus(days: 5))
        let active = makeLimit(id: "active", group: .weekly, percent: 50.4,
                               resetsAt: Date.fixedNow.plus(days: 5), isActive: true)
        let ranked = try #require(LimitConstraint.rank([idle, active]))
        #expect(ranked.limit.id == "active")
    }

    @Test("no limits means no answer rather than a fabricated one")
    func emptyIsNil() {
        #expect(LimitConstraint.rank([]) == nil)
        #expect(makeSnapshot(limits: []).constraint() == nil)
    }

    // MARK: Projections belong to their own provider

    @Test("a projection is only applied to the limit it was computed for")
    func projectionsAreKeyedByLimit() throws {
        // `weekly_all` exists on more than one provider. A stale or foreign entry under a
        // different key must not silently steer the ranking.
        let a = makeLimit(id: "weekly_all", group: .weekly, percent: 30,
                          resetsAt: Date.fixedNow.plus(days: 5))
        let b = makeLimit(id: "session", percent: 70, resetsAt: Date.fixedNow.plus(hours: 2))
        let ranked = try #require(LimitConstraint.rank(
            [a, b],
            projections: ["something_else": projection("something_else", percent: 99,
                                                       dryIn: 1, resetIn: 100)]
        ))
        #expect(ranked.limit.id == "session")
        #expect(ranked.reason == .tightest)
    }
}
