import Foundation

/// Splits quota consumption across the Claude Code projects that were running at the time.
///
/// Nothing else can do this: it needs the usage series *and* a record of which projects were
/// working, and this app is the only thing holding both.
///
/// **What it can and cannot know.** Attribution is inferred, never measured — the usage API
/// reports a single account-wide number and says nothing about who spent it. So:
///
/// * Resolution is the polling interval. A burst that starts and finishes between two samples
///   is credited to whoever was busy at the later sample.
/// * When several projects are busy across one interval the delta is split evenly, because
///   there is no signal saying otherwise.
/// * Consumption while no project was running — claude.ai in a browser, another client, a
///   session started before the hook was installed — lands in `unattributed` rather than being
///   forced onto whichever project happened to run next.
///
/// Those limits are surfaced in the UI rather than hidden; a confident-looking breakdown that
/// quietly guessed would be worse than none.
public enum UsageAttribution {

    public struct Share: Sendable, Equatable, Identifiable {
        public let project: String
        /// Percentage points of the limit consumed.
        public let points: Double
        /// Number of sample intervals this project was credited in.
        public let intervals: Int
        public var id: String { project }
    }

    public struct Breakdown: Sendable, Equatable {
        public let shares: [Share]
        /// Points consumed while nothing was known to be running.
        public let unattributed: Double
        /// Total points consumed over the period.
        public let total: Double
        /// Intervals where more than one project was busy, so the split was even rather than
        /// measured. Reported so the UI can qualify the numbers.
        public let sharedIntervals: Int

        public var isEmpty: Bool { total <= 0.01 }

        /// True when enough of the total is guesswork that the breakdown should be qualified.
        public var isApproximate: Bool { sharedIntervals > 0 }
    }

    /// Attributes consumption of one limit over `samples`.
    ///
    /// - Parameter samples: the full series; it is filtered to `provider` and sorted here.
    public static func attribute(
        samples: [UsageSample],
        limitID: String,
        provider: UsageProvider,
        since: Date? = nil
    ) -> Breakdown {
        let series = samples
            .filter { $0.provider == provider }
            .filter { sample in since.map { sample.t >= $0 } ?? true }
            .sorted { $0.t < $1.t }

        guard series.count >= 2 else {
            return Breakdown(shares: [], unattributed: 0, total: 0, sharedIntervals: 0)
        }

        var points: [String: Double] = [:]
        var counts: [String: Int] = [:]
        var unattributed = 0.0
        var total = 0.0
        var sharedIntervals = 0

        for i in 1..<series.count {
            let previous = series[i - 1], current = series[i]
            guard let a = previous.limits[limitID], let b = current.limits[limitID] else { continue }

            let delta = b - a
            // A drop is a quota reset, not negative usage. Skip the boundary rather than
            // letting it subtract from a project's total.
            guard delta > 0 else { continue }
            total += delta

            // Credit the projects busy at the *end* of the interval: the work that consumed
            // the quota is the work that was running as it was consumed.
            let busy = current.activeProjects.isEmpty
                ? previous.activeProjects
                : current.activeProjects

            guard !busy.isEmpty else {
                unattributed += delta
                continue
            }
            if busy.count > 1 { sharedIntervals += 1 }

            let each = delta / Double(busy.count)
            for project in busy {
                points[project, default: 0] += each
                counts[project, default: 0] += 1
            }
        }

        let shares = points
            .map { Share(project: $0.key, points: $0.value, intervals: counts[$0.key] ?? 0) }
            .sorted { $0.points > $1.points }

        return Breakdown(
            shares: shares,
            unattributed: unattributed,
            total: total,
            sharedIntervals: sharedIntervals
        )
    }
}
