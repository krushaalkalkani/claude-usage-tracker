import Foundation

/// Which limit will actually stop you first.
///
/// The panel used to pick its headline by raw utilisation — highest `percent` wins. That
/// sorts a table correctly and is wrong in practice, because a percentage says nothing about
/// *when*. A 5-hour session at 55 % with twenty minutes left on its clock cannot block you:
/// it refills before you could spend the rest. A weekly window at 46 % burning fast enough to
/// hit its ceiling two days before it resets absolutely can. Ranking on percent alone put the
/// harmless one in the hero slot and buried the real constraint in a quiet row underneath —
/// and, because the rule is data-dependent, it also made two providers disagree about which
/// *kind* of limit deserved the headline for no reason the user could see.
///
/// This ranks by consequence instead: already stopped, then stopping before the reset
/// (soonest first), then — when nothing is projected to run out — whichever window is heading
/// for the highest utilisation.
public enum LimitConstraint {

    /// Why a window was chosen. The panel states this rather than leaving the user to
    /// reverse-engineer it from the numbers.
    public enum Reason: String, Sendable, Equatable, Codable {
        /// At or past the ceiling right now.
        case exhausted
        /// On course to hit the ceiling before the window resets.
        case runsDry
        /// Nothing is projected to run out; this one is closest to its ceiling.
        case tightest

        /// Label for the hero chip. Short enough to sit next to the eyebrow.
        public var chipText: String {
            switch self {
            case .exhausted: return "at the limit"
            case .runsDry: return "runs out first"
            case .tightest: return "tightest"
            }
        }
    }

    public struct Ranked: Sendable, Equatable {
        public let limit: LimitWindow
        public let reason: Reason

        public init(limit: LimitWindow, reason: Reason) {
            self.limit = limit
            self.reason = reason
        }
    }

    /// A projection must clear the reset by a real margin before we call it "runs dry".
    /// Without the margin, a window whose exhaustion estimate lands within noise of its own
    /// reset flips in and out of the hero slot on every poll, and the panel — which resizes
    /// itself to its content — visibly jumps each time.
    static let dryMargin = 0.9

    /// Ranks `limits`, preferring evidence from `projections` where it exists.
    ///
    /// `projections` is keyed by `LimitWindow.id`, which is only unique *within* a provider,
    /// so callers must pass the projections belonging to these limits' own provider.
    /// Passing none is supported and degrades to ranking by current utilisation, which is
    /// what a freshly launched app with no history has to do anyway.
    public static func rank(
        _ limits: [LimitWindow],
        projections: [String: UsageProjection] = [:]
    ) -> Ranked? {
        guard !limits.isEmpty else { return nil }

        var exhausted: [LimitWindow] = []
        /// (window, seconds until it hits the ceiling)
        var runningDry: [(LimitWindow, TimeInterval)] = []
        /// (window, utilisation it is heading for)
        var rest: [(LimitWindow, Double)] = []

        for limit in limits {
            if limit.percent >= 100 {
                exhausted.append(limit)
                continue
            }
            let projection = projections[limit.id]
            if let projection,
               let toDry = projection.timeToExhaustion,
               let untilReset = projection.timeUntilReset,
               untilReset > 0,
               toDry < untilReset * dryMargin {
                runningDry.append((limit, toDry))
                continue
            }
            // With a burn rate in hand, judge a window by where it is heading rather than
            // where it happens to sit mid-window. Without one, current utilisation is the
            // only honest answer.
            rest.append((limit, projection?.projectedAtReset ?? limit.percent))
        }

        if let worst = exhausted.max(by: { rankedBelow($0, $1, $0.percent, $1.percent) }) {
            return Ranked(limit: worst, reason: .exhausted)
        }
        // Soonest to run dry wins, so `min` rather than `max`.
        if let soonest = runningDry.min(by: { a, b in
            if abs(a.1 - b.1) < 60, a.0.isActive != b.0.isActive { return a.0.isActive }
            return a.1 < b.1
        }) {
            return Ranked(limit: soonest.0, reason: .runsDry)
        }
        if let tightest = rest.max(by: { rankedBelow($0.0, $1.0, $0.1, $1.1) }) {
            return Ranked(limit: tightest.0, reason: .tightest)
        }
        return nil
    }

    /// True when `a` ranks below `b`. Values within a point of each other are a tie, broken
    /// in favour of the window the provider marked active — the one in force right now.
    private static func rankedBelow(
        _ a: LimitWindow, _ b: LimitWindow, _ aValue: Double, _ bValue: Double
    ) -> Bool {
        if abs(aValue - bValue) < 1, a.isActive != b.isActive { return b.isActive }
        return aValue < bValue
    }
}

extension UsageSnapshot {
    /// The window that binds this snapshot first, with the reason it was chosen.
    ///
    /// Prefer this over `bottleneck` for anything the user reads. `bottleneck` remains the
    /// pure "highest utilisation" answer, which is still the right one for storage-level
    /// questions that must not depend on how much history happens to be loaded.
    public func constraint(projections: [String: UsageProjection] = [:]) -> LimitConstraint.Ranked? {
        LimitConstraint.rank(limits, projections: projections)
    }
}
