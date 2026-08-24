import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite("Per-project attribution")
struct AttributionTests {

    private func sample(_ minute: Double, _ percent: Double, _ projects: [String])
        -> UsageSample {
        UsageSample(
            t: Date.fixedNow.addingTimeInterval(minute * 60),
            limits: ["session": percent],
            provider: .claude,
            activeProjects: projects
        )
    }

    @Test("consumption is credited to whatever was running")
    func creditsTheRunningProject() {
        let s = [
            sample(0, 10, []),
            sample(2, 16, ["alpha"]),   // +6 → alpha
            sample(4, 20, ["beta"]),    // +4 → beta
        ]
        let b = UsageAttribution.attribute(samples: s, limitID: "session", provider: .claude)

        #expect(b.total == 10)
        #expect(b.shares.count == 2)
        #expect(b.shares[0].project == "alpha")
        #expect(b.shares[0].points == 6)
        #expect(b.shares[1].points == 4)
        #expect(b.unattributed == 0)
        #expect(!b.isApproximate, "no overlap, so nothing was guessed")
    }

    @Test("overlapping projects split the interval and the result says so")
    func splitsAndFlagsOverlap() {
        let s = [sample(0, 10, []), sample(2, 20, ["alpha", "beta"])]
        let b = UsageAttribution.attribute(samples: s, limitID: "session", provider: .claude)

        #expect(b.shares.allSatisfy { $0.points == 5 }, "10 points split evenly across two")
        #expect(b.isApproximate, "an even split is a guess and must be labelled")
        #expect(b.sharedIntervals == 1)
    }

    @Test("usage with nothing running is not forced onto a project")
    func keepsUnattributedSeparate() {
        // Quota spent in a browser, or by a session predating the hook.
        let s = [sample(0, 10, []), sample(2, 25, []), sample(4, 30, ["alpha"])]
        let b = UsageAttribution.attribute(samples: s, limitID: "session", provider: .claude)

        #expect(b.unattributed == 15)
        #expect(b.shares.count == 1)
        #expect(b.shares[0].points == 5)
        #expect(b.total == 20)
    }

    @Test("a quota reset is not counted as negative usage")
    func ignoresResetBoundary() {
        let s = [
            sample(0, 80, ["alpha"]),
            sample(2, 5, ["alpha"]),    // reset: -75, must be skipped entirely
            sample(4, 9, ["alpha"]),    // +4
        ]
        let b = UsageAttribution.attribute(samples: s, limitID: "session", provider: .claude)

        #expect(b.total == 4, "only the post-reset climb counts, got \(b.total)")
        #expect(b.shares.first?.points == 4)
    }

    @Test("one provider's samples never leak into another's breakdown")
    func isolatesProviders() {
        let claude = sample(2, 20, ["alpha"])
        let chatgpt = UsageSample(
            t: Date.fixedNow.addingTimeInterval(120), limits: ["session": 90],
            provider: .chatgpt, activeProjects: ["beta"]
        )
        let s = [sample(0, 10, []), claude, chatgpt]
        let b = UsageAttribution.attribute(samples: s, limitID: "session", provider: .claude)

        // `session` exists on both providers; only Claude's may be counted here.
        #expect(b.total == 10)
        #expect(b.shares.map(\.project) == ["alpha"])
    }

    @Test("a single sample yields nothing rather than a fabricated total")
    func needsTwoPoints() {
        let b = UsageAttribution.attribute(
            samples: [sample(0, 40, ["alpha"])], limitID: "session", provider: .claude
        )
        #expect(b.isEmpty)
        #expect(b.shares.isEmpty)
    }

    @Test("older samples without the field are simply unattributed")
    func toleratesPreAttributionSamples() throws {
        // Written before activeProjects existed.
        let json = """
        [{"t":"2026-08-24T10:00:00Z","limits":{"session":10},"provider":"claude"},
         {"t":"2026-08-24T10:02:00Z","limits":{"session":30},"provider":"claude"}]
        """
        let decoded = try JSONDecoder.store.decode([UsageSample].self, from: Data(json.utf8))
        #expect(decoded.allSatisfy { $0.activeProjects.isEmpty })

        let b = UsageAttribution.attribute(samples: decoded, limitID: "session", provider: .claude)
        #expect(b.unattributed == 20, "no crash, no invented owner")
    }
}
