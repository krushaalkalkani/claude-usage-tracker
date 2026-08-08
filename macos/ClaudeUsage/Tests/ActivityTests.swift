import Foundation
import Testing
@testable import ClaudeUsageCore

@Suite("Claude Code activity", .serialized)
struct ActivityTests {

    /// Each test gets its own sessions directory so nothing touches the real home folder.
    private func withTempSessions(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cut-tests-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(sessions)
    }

    private func write(_ json: String, named: String, in dir: URL) throws {
        try json.write(
            to: dir.appendingPathComponent("\(named).json"), atomically: true, encoding: .utf8
        )
    }

    @Test("no sessions directory means the hook is not installed, not that Claude is idle")
    func hookNotInstalled() {
        let monitor = ActivityMonitor(
            sessionsDirectory: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"),
            now: { .fixedNow }
        )
        let state = monitor.read(staleAfter: 600)
        #expect(!state.hookInstalled)
        #expect(state.sessions.isEmpty)
    }

    @Test("an empty sessions directory means installed but nothing running")
    func installedButIdle() throws {
        try withTempSessions { dir in
            let monitor = ActivityMonitor(sessionsDirectory: dir, now: { .fixedNow })
            let state = monitor.read(staleAfter: 600)
            #expect(state.hookInstalled)
            #expect(state.sessions.isEmpty)
        }
    }

    @Test("session metadata is decoded")
    func decodesSession() throws {
        try withTempSessions { dir in
            try write("""
            {"schema":1,"sessionId":"abc","project":"claude-usage-tracker",
             "cwd":"/Users/x/claude-usage-tracker","status":"running_tool",
             "statusDetail":"Bash","activeAgents":2,"openTasks":1,
             "lastEvent":"PreToolUse","lastEventAt":"2026-08-08T17:29:00Z",
             "turnStartedAt":"2026-08-08T17:20:00Z","needsAttention":false,
             "permissionMode":"default","effort":"high",
             "updatedAt":"2026-08-08T17:29:30Z"}
            """, named: "abc", in: dir)

            let monitor = ActivityMonitor(
                sessionsDirectory: dir, now: { .fixedNow }, processIsAlive: { _ in true }
            )
            let state = monitor.read(staleAfter: 600)
            let session = try #require(state.sessions.first)
            #expect(session.sessionId == "abc")
            #expect(session.status == .runningTool)
            #expect(session.statusDetail == "Bash")
            #expect(session.activeAgents == 2)
            #expect(session.displayName == "claude-usage-tracker")
            #expect(state.totalAgents == 2)
            // 17:30 now minus a 17:20 turn start.
            #expect(session.turnDuration(now: .fixedNow) == 600)
        }
    }

    @Test("a session whose Claude Code process is gone is reaped")
    func reapsDeadSessions() throws {
        try withTempSessions { dir in
            try write("""
            {"sessionId":"dead","status":"working","claudePid":424242,
             "updatedAt":"2026-08-08T17:29:00Z"}
            """, named: "dead", in: dir)
            try write("""
            {"sessionId":"live","status":"working","claudePid":1,
             "updatedAt":"2026-08-08T17:29:00Z"}
            """, named: "live", in: dir)

            let monitor = ActivityMonitor(
                sessionsDirectory: dir, now: { .fixedNow },
                processIsAlive: { pid in pid == 1 }
            )
            let state = monitor.read(staleAfter: 600)
            #expect(state.sessions.map(\.sessionId) == ["live"])
            // And the stale file is gone from disk, not just filtered from the view.
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("dead.json").path))
        }
    }

    @Test("a busy session that stopped reporting becomes unknown, not 'working'")
    func staleBecomesUnknown() throws {
        try withTempSessions { dir in
            try write("""
            {"sessionId":"quiet","status":"working","needsAttention":true,
             "updatedAt":"2026-08-08T16:00:00Z"}
            """, named: "quiet", in: dir)

            let monitor = ActivityMonitor(
                sessionsDirectory: dir, now: { .fixedNow }, processIsAlive: { _ in true }
            )
            let state = monitor.read(staleAfter: 600)
            let session = try #require(state.sessions.first)
            #expect(session.status == .stale)
            // A stale record's attention flag is no more trustworthy than its status.
            #expect(!session.needsAttention)
        }
    }

    @Test("a recently-updated session is not marked stale")
    func freshStaysFresh() throws {
        try withTempSessions { dir in
            try write("""
            {"sessionId":"fresh","status":"working","updatedAt":"2026-08-08T17:29:00Z"}
            """, named: "fresh", in: dir)
            let monitor = ActivityMonitor(
                sessionsDirectory: dir, now: { .fixedNow }, processIsAlive: { _ in true }
            )
            #expect(monitor.read(staleAfter: 600).sessions.first?.status == .working)
        }
    }

    @Test("sessions needing attention sort first")
    func attentionSortsFirst() throws {
        try withTempSessions { dir in
            try write("""
            {"sessionId":"busy","project":"b","status":"working","updatedAt":"2026-08-08T17:29:50Z"}
            """, named: "busy", in: dir)
            try write("""
            {"sessionId":"blocked","project":"a","status":"permission_required",
             "needsAttention":true,"attentionReason":"Permission requested",
             "updatedAt":"2026-08-08T17:25:00Z"}
            """, named: "blocked", in: dir)

            let monitor = ActivityMonitor(
                sessionsDirectory: dir, now: { .fixedNow }, processIsAlive: { _ in true }
            )
            let state = monitor.read(staleAfter: 600)
            #expect(state.sessions.first?.sessionId == "blocked")
            #expect(state.attentionSessions.count == 1)
            #expect(state.primarySession(now: .fixedNow, staleAfter: 600)?.sessionId == "blocked")
        }
    }

    @Test("corrupt and partial session files are skipped, not fatal")
    func corruptFilesSkipped() throws {
        try withTempSessions { dir in
            try write("{ this is not json", named: "broken", in: dir)
            try write("""
            {"noSessionIdHere": true}
            """, named: "incomplete", in: dir)
            try write("""
            {"sessionId":"ok","status":"idle","updatedAt":"2026-08-08T17:29:00Z"}
            """, named: "ok", in: dir)

            let monitor = ActivityMonitor(
                sessionsDirectory: dir, now: { .fixedNow }, processIsAlive: { _ in true }
            )
            let state = monitor.read(staleAfter: 600)
            #expect(state.sessions.map(\.sessionId) == ["ok"])
        }
    }

    @Test("a record written by a newer hook version still decodes")
    func forwardCompatibleRecord() throws {
        try withTempSessions { dir in
            try write("""
            {"schema":9,"sessionId":"future","status":"working",
             "brandNewField":{"a":1},"activeAgents":3,
             "updatedAt":"2026-08-08T17:29:00Z"}
            """, named: "future", in: dir)
            let monitor = ActivityMonitor(
                sessionsDirectory: dir, now: { .fixedNow }, processIsAlive: { _ in true }
            )
            let session = try #require(monitor.read(staleAfter: 600).sessions.first)
            #expect(session.activeAgents == 3)
            #expect(session.schema == 9)
        }
    }

    @Test("an unrecognized status falls back to idle rather than failing")
    func unknownStatus() throws {
        try withTempSessions { dir in
            try write("""
            {"sessionId":"weird","status":"transcendent","updatedAt":"2026-08-08T17:29:00Z"}
            """, named: "weird", in: dir)
            let monitor = ActivityMonitor(
                sessionsDirectory: dir, now: { .fixedNow }, processIsAlive: { _ in true }
            )
            #expect(monitor.read(staleAfter: 600).sessions.first?.status == .idle)
        }
    }

    @Test("display name falls back to the cwd, then the session id")
    func displayNameFallbacks() {
        #expect(makeSession(project: "proj").displayName == "proj")
        var noProject = makeSession()
        noProject.project = nil
        noProject.cwd = "/Users/x/some-repo"
        #expect(noProject.displayName == "some-repo")
        noProject.cwd = nil
        noProject.sessionId = "0123456789abcdef"
        #expect(noProject.displayName == "01234567")
    }
}
