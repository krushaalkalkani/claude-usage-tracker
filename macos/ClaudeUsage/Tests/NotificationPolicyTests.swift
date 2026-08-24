import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite("Notification policy")
struct NotificationPolicyTests {
    private let reset = Date.fixedNow.plus(hours: 2)

    private func context(
        limits: [LimitWindow],
        settings: AppSettings = permissiveSettings,
        projections: [String: UsageProjection] = [:],
        surging: Set<String> = [],
        activity: ActivityState? = nil,
        error: UsageAPIError? = nil,
        healthy: Bool = true,
        now: Date = .fixedNow
    ) -> PolicyContext {
        PolicyContext(
            now: now, settings: settings,
            snapshot: makeSnapshot(limits: limits, at: now),
            projections: projections, surgingLimitIDs: surging,
            activity: activity, apiError: error, apiHealthy: healthy
        )
    }

    // MARK: Thresholds

    @Test("crossing a threshold fires exactly once per quota window")
    func firesOnce() {
        var ledger = NotificationLedger()
        let limit = makeLimit(percent: 76, resetsAt: reset)

        let first = NotificationPolicy.evaluate(context(limits: [limit]), ledger: &ledger)
        #expect(first.count == 1)
        #expect(first.first?.title.contains("75%") == true)

        // Same window, same value, five more polls: silence.
        for _ in 0..<5 {
            let again = NotificationPolicy.evaluate(context(limits: [limit]), ledger: &ledger)
            #expect(again.isEmpty)
        }
    }

    @Test("a big jump announces only the highest threshold crossed")
    func collapsesMultipleCrossings() {
        var ledger = NotificationLedger()
        // 4% → 96% in one poll would naively fire 50, 75, 90, and 95.
        _ = NotificationPolicy.evaluate(
            context(limits: [makeLimit(percent: 4, resetsAt: reset)]), ledger: &ledger
        )
        let out = NotificationPolicy.evaluate(
            context(limits: [makeLimit(percent: 96, resetsAt: reset)]), ledger: &ledger
        )
        #expect(out.count == 1)
        #expect(out.first?.title.contains("95%") == true)
        #expect(out.first?.severity == .critical)
    }

    @Test("a new quota window re-arms every threshold")
    func rearmsAfterReset() {
        var ledger = NotificationLedger()
        let firstWindow = makeLimit(percent: 92, resetsAt: reset)
        let fired = NotificationPolicy.evaluate(context(limits: [firstWindow]), ledger: &ledger)
        #expect(fired.count == 1)

        // Window rolls: reset time moves forward and utilisation drops.
        let newWindow = makeLimit(percent: 3, resetsAt: reset.plus(hours: 5))
        let atReset = NotificationPolicy.evaluate(
            context(limits: [newWindow], now: reset.plus(minutes: 1)), ledger: &ledger
        )
        #expect(atReset.contains { $0.category == .quotaReset })

        // Climbing again in the new window fires the same threshold a second time.
        let climbAgain = NotificationPolicy.evaluate(
            context(
                limits: [makeLimit(percent: 92, resetsAt: reset.plus(hours: 5))],
                now: reset.plus(minutes: 30)
            ),
            ledger: &ledger
        )
        #expect(climbAgain.contains { $0.category == .usageThreshold })
    }

    @Test("jittering resets_at does not fake a reset on every poll")
    func rollingResetTimestampIsNotAReset() {
        // The API stamps resets_at with fractional seconds that differ on every response for
        // the same window (…:00.196578, then …:00.275325). Round-tripping through the ledger
        // rounds them off, so a naive `resetsAt > previousReset` was true on *every* poll:
        // "Weekly quota reset — was 39%, now 39%" every two minutes, with every usage
        // threshold re-armed behind it.
        var ledger = NotificationLedger()
        var settings = AppSettings()
        settings.usageThresholds = [25, 50]
        var fired: [PendingNotification] = []

        for poll in 0..<12 {
            // Same window, same utilisation — only the sub-second noise moves.
            let jittered = reset.plus(days: 5).addingTimeInterval(Double(poll) * 0.0731)
            let limit = LimitWindow(
                id: "weekly_all", kind: "weekly_all", group: .weekly,
                title: "7-day limit", shortTitle: "Weekly",
                percent: 39, resetsAt: jittered.truncatingSubsecond, severity: .normal
            )
            fired += NotificationPolicy.evaluate(
                context(limits: [limit], settings: settings, now: reset.plus(minutes: Double(poll * 2))),
                ledger: &ledger
            )
        }

        #expect(fired.filter { $0.category == .quotaReset }.isEmpty,
                "a jittering timestamp must never read as a reset")
        // 25% is genuinely crossed, so it announces once across all twelve polls.
        #expect(fired.filter { $0.category == .usageThreshold }.count == 1)
    }

    @Test("a session parked on a permission prompt is announced once per episode")
    func attentionAnnouncedOncePerEpisode() {
        var ledger = NotificationLedger()
        var fired: [PendingNotification] = []

        func poll(_ minute: Int, attention: Bool) -> [PendingNotification] {
            let at = reset.plus(minutes: Double(minute))
            let session = ActivitySession(
                sessionId: "s1", project: "demo",
                status: attention ? .permissionRequired : .working,
                lastEvent: "PreToolUse", lastEventAt: at,
                needsAttention: attention,
                attentionReason: attention ? "Permission requested" : nil,
                updatedAt: at
            )
            return NotificationPolicy.evaluate(
                context(
                    limits: [],
                    activity: ActivityState(sessions: [session], hookInstalled: true, sampledAt: at),
                    now: at
                ),
                ledger: &ledger
            )
        }

        // Blocked on a permission prompt for twenty minutes while other hook events land,
        // each one moving lastEventAt — which used to mint a fresh dedup key every time.
        for i in 0..<10 { fired += poll(i * 2, attention: true) }
        #expect(fired.filter { $0.category == .claudeAttention }.count == 1)

        // Granted, then a genuinely new prompt later: that is a fresh episode.
        _ = poll(22, attention: false)
        #expect(poll(24, attention: true).filter { $0.category == .claudeAttention }.count == 1)
    }

    @Test("a reset from a low value is not worth announcing")
    func quietResetFromIdle() {
        var ledger = NotificationLedger()
        _ = NotificationPolicy.evaluate(
            context(limits: [makeLimit(percent: 4, resetsAt: reset)]), ledger: &ledger
        )
        let out = NotificationPolicy.evaluate(
            context(
                limits: [makeLimit(percent: 0, resetsAt: reset.plus(hours: 5))],
                now: reset.plus(minutes: 1)
            ),
            ledger: &ledger
        )
        #expect(!out.contains { $0.category == .quotaReset })
    }

    @Test("each limit is tracked independently")
    func perLimitDedup() {
        var ledger = NotificationLedger()
        let session = makeLimit(id: "session", percent: 80, resetsAt: reset)
        let weekly = makeLimit(
            id: "weekly_all", kind: "weekly_all", group: .weekly,
            percent: 80, resetsAt: reset.plus(days: 5)
        )
        let out = NotificationPolicy.evaluate(context(limits: [session, weekly]), ledger: &ledger)
        #expect(out.count == 2)
        #expect(Set(out.map(\.id)).count == 2)
    }

    @Test("custom thresholds are honoured and normalized")
    func customThresholds() {
        var settings = permissiveSettings
        settings.usageThresholds = [100, 60, 60, 0, -5, 30]
        #expect(settings.normalizedThresholds == [30, 60, 100])

        var ledger = NotificationLedger()
        let out = NotificationPolicy.evaluate(
            context(limits: [makeLimit(percent: 65, resetsAt: reset)], settings: settings),
            ledger: &ledger
        )
        #expect(out.count == 1)
        #expect(out.first?.title.contains("60%") == true)
    }

    // MARK: Projection and surge

    @Test("projected overrun needs a well-supported trend")
    func projectionGating() {
        var ledger = NotificationLedger()
        let limit = makeLimit(percent: 60, resetsAt: reset)

        // A thin, noisy estimate must not produce an alert.
        let weak = UsageProjection(
            limitID: limit.id, currentPercent: 60,
            burnRate: BurnRate(perHour: 30, sampleCount: 3, span: 600, fitQuality: 0.2),
            projectedAtReset: 120, timeToExhaustion: 1_800,
            timeUntilReset: 7_200
        )
        let noAlert = NotificationPolicy.evaluate(
            context(limits: [limit], projections: [limit.id: weak]), ledger: &ledger
        )
        #expect(!noAlert.contains { $0.category == .projectedOverrun })

        // A solid one does.
        let strong = UsageProjection(
            limitID: limit.id, currentPercent: 60,
            burnRate: BurnRate(perHour: 30, sampleCount: 10, span: 3_600, fitQuality: 0.95),
            projectedAtReset: 120, timeToExhaustion: 1_800,
            timeUntilReset: 7_200
        )
        var freshLedger = NotificationLedger()
        let alert = NotificationPolicy.evaluate(
            context(limits: [limit], projections: [limit.id: strong]), ledger: &freshLedger
        )
        #expect(alert.contains { $0.category == .projectedOverrun })
    }

    @Test("surge alerts respect their cooldown")
    func surgeCooldown() {
        var ledger = NotificationLedger()
        let limit = makeLimit(percent: 55, resetsAt: reset)
        let first = NotificationPolicy.evaluate(
            context(limits: [limit], surging: [limit.id]), ledger: &ledger
        )
        #expect(first.contains { $0.category == .usageSurge })

        let tooSoon = NotificationPolicy.evaluate(
            context(limits: [limit], surging: [limit.id], now: Date.fixedNow.plus(minutes: 5)),
            ledger: &ledger
        )
        #expect(!tooSoon.contains { $0.category == .usageSurge })

        let later = NotificationPolicy.evaluate(
            context(limits: [limit], surging: [limit.id], now: Date.fixedNow.plus(minutes: 40)),
            ledger: &ledger
        )
        #expect(later.contains { $0.category == .usageSurge })
    }

    // MARK: API health

    @Test("a 401 is announced immediately")
    func authError() {
        var ledger = NotificationLedger()
        let out = NotificationPolicy.evaluate(
            context(limits: [], error: .unauthorized, healthy: false), ledger: &ledger
        )
        #expect(out.count == 1)
        #expect(out.first?.category == .apiAuth)
    }

    @Test("a transient failure stays quiet until it looks persistent")
    func transientFailuresAreQuiet() {
        var ledger = NotificationLedger()
        for attempt in 1...2 {
            let out = NotificationPolicy.evaluate(
                context(limits: [], error: .server(status: 503), healthy: false), ledger: &ledger
            )
            #expect(out.isEmpty, "spoke up on attempt \(attempt)")
        }
        let third = NotificationPolicy.evaluate(
            context(limits: [], error: .server(status: 503), healthy: false), ledger: &ledger
        )
        #expect(third.contains { $0.category == .apiUnavailable })
    }

    @Test("recovery resets the failure counter")
    func recoveryResets() {
        var ledger = NotificationLedger()
        for _ in 0..<3 {
            _ = NotificationPolicy.evaluate(
                context(limits: [], error: .offline, healthy: false), ledger: &ledger
            )
        }
        _ = NotificationPolicy.evaluate(context(limits: []), ledger: &ledger)
        #expect(ledger.consecutiveFailures == 0)
    }

    // MARK: Claude Code

    @Test("permission requests notify once per event")
    func attentionOnce() {
        var ledger = NotificationLedger()
        let session = makeSession(
            status: .permissionRequired, needsAttention: true,
            attentionReason: "Permission requested"
        )
        let activity = ActivityState(sessions: [session], hookInstalled: true, sampledAt: .fixedNow)

        let first = NotificationPolicy.evaluate(context(limits: [], activity: activity), ledger: &ledger)
        #expect(first.contains { $0.category == .claudeAttention })

        let repeated = NotificationPolicy.evaluate(
            context(limits: [], activity: activity, now: Date.fixedNow.plus(minutes: 10)),
            ledger: &ledger
        )
        #expect(!repeated.contains { $0.category == .claudeAttention })
    }

    @Test("only long turns produce a completion notification")
    func completionMinimumDuration() {
        var ledger = NotificationLedger()
        let quick = makeSession(
            status: .completed, lastTurnSeconds: 12, lastCompletedAt: .fixedNow
        )
        let quickState = ActivityState(sessions: [quick], hookInstalled: true, sampledAt: .fixedNow)
        #expect(
            !NotificationPolicy.evaluate(context(limits: [], activity: quickState), ledger: &ledger)
                .contains { $0.category == .claudeCompleted }
        )

        let long = makeSession(
            id: "s2", status: .completed, lastTurnSeconds: 240, lastCompletedAt: .fixedNow
        )
        let longState = ActivityState(sessions: [long], hookInstalled: true, sampledAt: .fixedNow)
        let out = NotificationPolicy.evaluate(context(limits: [], activity: longState), ledger: &ledger)
        #expect(out.contains { $0.category == .claudeCompleted })
        #expect(out.first { $0.category == .claudeCompleted }?.body.contains("4m") == true)
    }

    @Test("the same completed turn is never announced twice")
    func completionDedup() {
        var ledger = NotificationLedger()
        let session = makeSession(
            status: .completed, lastTurnSeconds: 300, lastCompletedAt: .fixedNow
        )
        let state = ActivityState(sessions: [session], hookInstalled: true, sampledAt: .fixedNow)
        let first = NotificationPolicy.evaluate(context(limits: [], activity: state), ledger: &ledger)
        #expect(first.count == 1)
        let second = NotificationPolicy.evaluate(
            context(limits: [], activity: state, now: Date.fixedNow.plus(minutes: 20)),
            ledger: &ledger
        )
        #expect(second.isEmpty)
    }

    @Test("nothing is said when the hook is not installed")
    func noHookNoNoise() {
        var ledger = NotificationLedger()
        let out = NotificationPolicy.evaluate(
            context(limits: [], activity: .unavailable), ledger: &ledger
        )
        #expect(out.isEmpty)
    }

    @Test("two sessions blocked at once are both announced")
    func multipleSessions() {
        var ledger = NotificationLedger()
        var settings = permissiveSettings
        settings.notifyClaudeCodeCompletion = false
        let sessions = [
            makeSession(id: "a", project: "one", status: .permissionRequired,
                        needsAttention: true, attentionReason: "Permission requested"),
            makeSession(id: "b", project: "two", status: .waitingForUser,
                        needsAttention: true, attentionReason: "Waiting for input"),
        ]
        let state = ActivityState(sessions: sessions, hookInstalled: true, sampledAt: .fixedNow)
        let out = NotificationPolicy.evaluate(
            context(limits: [], settings: settings, activity: state), ledger: &ledger
        )
        // The cooldown is per session, so project "two" is not silenced by project "one".
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.category == .claudeAttention })
        #expect(Set(out.compactMap(\.cooldownScope)) == ["a", "b"])
        #expect(out.contains { $0.title.contains("one") })
        #expect(out.contains { $0.title.contains("two") })
    }

    @Test("one session repeating itself is still throttled")
    func perSessionCooldownStillThrottles() {
        var ledger = NotificationLedger()
        var settings = permissiveSettings
        settings.notifyClaudeCodeCompletion = false

        func attention(at eventTime: Date) -> ActivityState {
            ActivityState(
                sessions: [makeSession(
                    id: "a", status: .permissionRequired, needsAttention: true,
                    attentionReason: "Permission requested", lastEventAt: eventTime
                )],
                hookInstalled: true, sampledAt: eventTime
            )
        }

        let first = NotificationPolicy.evaluate(
            context(limits: [], settings: settings, activity: attention(at: .fixedNow)),
            ledger: &ledger
        )
        #expect(first.count == 1)

        // A *new* event on the same session 30s later is inside the 2-minute cooldown.
        let soon = Date.fixedNow.plus(minutes: 0.5)
        let second = NotificationPolicy.evaluate(
            context(limits: [], settings: settings, activity: attention(at: soon), now: soon),
            ledger: &ledger
        )
        #expect(second.isEmpty)
    }

    // MARK: Quiet hours & master switch

    @Test("quiet hours suppress normal alerts but can let critical through")
    func quietHours() {
        var settings = permissiveSettings
        settings.quietHoursEnabled = true
        settings.quietHoursStart = 0
        settings.quietHoursEnd = 23 * 60 + 59
        settings.criticalBypassesQuietHours = true

        var ledger = NotificationLedger()
        let quiet = NotificationPolicy.evaluate(
            context(limits: [makeLimit(percent: 52, resetsAt: reset)], settings: settings),
            ledger: &ledger
        )
        #expect(quiet.isEmpty)

        var ledger2 = NotificationLedger()
        let critical = NotificationPolicy.evaluate(
            context(limits: [makeLimit(percent: 97, resetsAt: reset)], settings: settings),
            ledger: &ledger2
        )
        #expect(critical.count == 1)
        #expect(critical.first?.severity == .critical)
    }

    @Test("quiet hours wrapping midnight are evaluated correctly")
    func quietHoursWrap() {
        var settings = AppSettings()
        settings.quietHoursEnabled = true
        settings.quietHoursStart = 22 * 60
        settings.quietHoursEnd = 8 * 60

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(from: DateComponents(
                timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 8, day: 8,
                hour: hour, minute: minute
            ))!
        }
        #expect(settings.isWithinQuietHours(at(23), calendar: cal))
        #expect(settings.isWithinQuietHours(at(3), calendar: cal))
        #expect(!settings.isWithinQuietHours(at(9), calendar: cal))
        #expect(!settings.isWithinQuietHours(at(21, 59), calendar: cal))
        #expect(settings.isWithinQuietHours(at(22, 0), calendar: cal))
    }

    @Test("disabling notifications still tracks windows so re-enabling is quiet")
    func disabledStillTracks() {
        var settings = permissiveSettings
        settings.notificationsEnabled = false
        var ledger = NotificationLedger()

        let out = NotificationPolicy.evaluate(
            context(limits: [makeLimit(percent: 95, resetsAt: reset)], settings: settings),
            ledger: &ledger
        )
        #expect(out.isEmpty)
        #expect(ledger.lastPercent["claude#session"] == 95)
        #expect(ledger.lastResetSeen["claude#session"] == reset)
    }

    @Test("the ledger survives a round trip through disk")
    func ledgerCodable() throws {
        var ledger = NotificationLedger()
        _ = NotificationPolicy.evaluate(
            context(limits: [makeLimit(percent: 91, resetsAt: reset)]), ledger: &ledger
        )
        let data = try JSONEncoder.store.encode(ledger)
        let restored = try JSONDecoder.store.decode(NotificationLedger.self, from: data)
        #expect(restored == ledger)

        var reused = restored
        let out = NotificationPolicy.evaluate(
            context(limits: [makeLimit(percent: 91, resetsAt: reset)]), ledger: &reused
        )
        #expect(out.isEmpty, "restarting the app re-announced an old threshold")
    }
}
