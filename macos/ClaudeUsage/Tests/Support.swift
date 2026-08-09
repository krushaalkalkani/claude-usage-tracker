import Foundation
import Testing
@testable import ClaudeUsageCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ) ?? Bundle.module.url(forResource: name, withExtension: "json") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> JSONValue {
        try JSONValue.parse(data(name))
    }

    static func snapshot(_ name: String, now: Date = .fixedNow) throws -> UsageSnapshot {
        UsageParser.parse(try json(name), now: now)
    }

    enum FixtureError: Error { case missing(String) }
}

extension Date {
    /// A fixed reference instant so nothing in the suite depends on the wall clock.
    /// 2026-08-08T17:30:00Z — 2h30m before the session reset in `usage-current.json`.
    static let fixedNow = ISO8601.parse("2026-08-08T17:30:00Z")!

    func plus(minutes: Double) -> Date { addingTimeInterval(minutes * 60) }
    func plus(hours: Double) -> Date { addingTimeInterval(hours * 3600) }
    func plus(days: Double) -> Date { addingTimeInterval(days * 86_400) }
}

/// Builds a sample series with a constant slope, for analytics tests.
func linearSamples(
    limitID: String,
    from start: Date,
    count: Int,
    everyMinutes: Double,
    startPercent: Double,
    perHour: Double
) -> [UsageSample] {
    (0..<count).map { i in
        let t = start.plus(minutes: Double(i) * everyMinutes)
        let hours = Double(i) * everyMinutes / 60
        return UsageSample(t: t, limits: [limitID: startPercent + perHour * hours])
    }
}

func makeLimit(
    id: String = "session",
    kind: String = "session",
    group: LimitGroup = .session,
    percent: Double,
    resetsAt: Date?,
    severity: Severity = .normal,
    isActive: Bool = false,
    model: String? = nil
) -> LimitWindow {
    LimitWindow(
        id: id, kind: kind, group: group,
        title: model.map { "\($0) · 7-day" } ?? "limit",
        shortTitle: model ?? (group == .session ? "Session" : "Weekly"),
        percent: percent, resetsAt: resetsAt, severity: severity,
        isActive: isActive, modelName: model
    )
}

func makeSnapshot(
    limits: [LimitWindow],
    spend: SpendInfo? = nil,
    at now: Date = .fixedNow
) -> UsageSnapshot {
    UsageSnapshot(fetchedAt: now, limits: limits, spend: spend)
}

func makeSession(
    id: String = "s1",
    project: String = "demo",
    status: ActivityStatus = .working,
    needsAttention: Bool = false,
    attentionReason: String? = nil,
    lastTurnSeconds: Double? = nil,
    lastCompletedAt: Date? = nil,
    updatedAt: Date = .fixedNow,
    lastEventAt: Date = .fixedNow,
    turnStartedAt: Date? = nil,
    pid: Int? = nil,
    agents: Int = 0
) -> ActivitySession {
    ActivitySession(
        sessionId: id, project: project, cwd: "/tmp/\(project)",
        status: status, activeAgents: agents,
        lastEvent: "PostToolUse", lastEventAt: lastEventAt,
        turnStartedAt: turnStartedAt,
        lastCompletedAt: lastCompletedAt, lastTurnSeconds: lastTurnSeconds,
        needsAttention: needsAttention, attentionReason: attentionReason,
        claudePid: pid, updatedAt: updatedAt
    )
}

var permissiveSettings: AppSettings {
    var s = AppSettings()
    s.notificationsEnabled = true
    s.quietHoursEnabled = false
    return s
}
