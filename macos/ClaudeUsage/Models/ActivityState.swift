import Foundation

/// What a Claude Code session is doing right now, as inferred from hook events.
public enum ActivityStatus: String, Sendable, Codable, CaseIterable {
    case idle
    case working
    case thinking
    case runningTool = "running_tool"
    case runningAgents = "running_agents"
    case waitingForUser = "waiting_for_user"
    case permissionRequired = "permission_required"
    case compacting
    case completed
    case error
    case rateLimited = "rate_limited"
    /// The session file exists but has not been updated in a long time; we do not know.
    case stale

    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .thinking: return "Thinking"
        case .runningTool: return "Running tool"
        case .runningAgents: return "Running agents"
        case .waitingForUser: return "Waiting for you"
        case .permissionRequired: return "Needs permission"
        case .compacting: return "Compacting"
        case .completed: return "Completed"
        case .error: return "Error"
        case .rateLimited: return "Rate limited"
        case .stale: return "Unknown"
        }
    }

    /// Statuses that mean Claude Code is actively consuming quota.
    public var isBusy: Bool {
        switch self {
        case .working, .thinking, .runningTool, .runningAgents, .compacting: return true
        default: return false
        }
    }

    public var wantsAttention: Bool {
        switch self {
        case .permissionRequired, .waitingForUser, .error, .rateLimited: return true
        default: return false
        }
    }

    public var symbolName: String {
        switch self {
        case .idle: return "moon.zzz"
        case .working, .thinking: return "bolt.fill"
        case .runningTool: return "wrench.and.screwdriver.fill"
        case .runningAgents: return "person.3.fill"
        case .waitingForUser: return "hand.raised.fill"
        case .permissionRequired: return "lock.open.fill"
        case .compacting: return "arrow.down.right.and.arrow.up.left"
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .rateLimited: return "gauge.with.dots.needle.100percent"
        case .stale: return "questionmark.circle"
        }
    }
}

/// One Claude Code session, as written by the hook. Metadata only — no prompt or assistant
/// content is ever recorded.
public struct ActivitySession: Sendable, Codable, Equatable, Identifiable {
    public var schema: Int
    public var sessionId: String
    public var project: String?
    public var cwd: String?
    public var model: String?
    public var status: ActivityStatus
    public var statusDetail: String?
    public var activeAgents: Int
    public var openTasks: Int
    public var lastEvent: String?
    public var lastEventAt: Date?
    public var startedAt: Date?
    public var turnStartedAt: Date?
    public var lastCompletedAt: Date?
    public var lastTurnSeconds: Double?
    public var needsAttention: Bool
    public var attentionReason: String?
    public var permissionMode: String?
    public var effort: String?
    public var lastError: String?
    public var claudePid: Int?
    public var updatedAt: Date?

    public var id: String { sessionId }

    public init(
        schema: Int = 1,
        sessionId: String,
        project: String? = nil,
        cwd: String? = nil,
        model: String? = nil,
        status: ActivityStatus = .idle,
        statusDetail: String? = nil,
        activeAgents: Int = 0,
        openTasks: Int = 0,
        lastEvent: String? = nil,
        lastEventAt: Date? = nil,
        startedAt: Date? = nil,
        turnStartedAt: Date? = nil,
        lastCompletedAt: Date? = nil,
        lastTurnSeconds: Double? = nil,
        needsAttention: Bool = false,
        attentionReason: String? = nil,
        permissionMode: String? = nil,
        effort: String? = nil,
        lastError: String? = nil,
        claudePid: Int? = nil,
        updatedAt: Date? = nil
    ) {
        self.schema = schema
        self.sessionId = sessionId
        self.project = project
        self.cwd = cwd
        self.model = model
        self.status = status
        self.statusDetail = statusDetail
        self.activeAgents = activeAgents
        self.openTasks = openTasks
        self.lastEvent = lastEvent
        self.lastEventAt = lastEventAt
        self.startedAt = startedAt
        self.turnStartedAt = turnStartedAt
        self.lastCompletedAt = lastCompletedAt
        self.lastTurnSeconds = lastTurnSeconds
        self.needsAttention = needsAttention
        self.attentionReason = attentionReason
        self.permissionMode = permissionMode
        self.effort = effort
        self.lastError = lastError
        self.claudePid = claudePid
        self.updatedAt = updatedAt
    }

    /// A short project label: the recorded project name, else the last path component of cwd.
    public var displayName: String {
        if let project, !project.isEmpty { return project }
        if let cwd, let last = URL(fileURLWithPath: cwd).lastPathComponent as String?,
           !last.isEmpty, last != "/" {
            return last
        }
        return String(sessionId.prefix(8))
    }

    /// How long the current turn has been running.
    public func turnDuration(now: Date) -> TimeInterval? {
        guard status.isBusy, let turnStartedAt else { return nil }
        return max(0, now.timeIntervalSince(turnStartedAt))
    }

    /// A session whose status claims activity but which has not reported in a long while is
    /// reported as `.stale` rather than as a lie.
    public func resolvedStatus(now: Date, staleAfter: TimeInterval) -> ActivityStatus {
        guard let updatedAt else { return status }
        if status.isBusy && now.timeIntervalSince(updatedAt) > staleAfter { return .stale }
        return status
    }
}

/// The aggregate view the UI renders.
public struct ActivityState: Sendable, Equatable {
    public let sessions: [ActivitySession]
    /// True when the hook has never written anything — we say "not installed" rather than
    /// pretending Claude Code is idle.
    public let hookInstalled: Bool
    public let sampledAt: Date

    public init(sessions: [ActivitySession], hookInstalled: Bool, sampledAt: Date) {
        self.sessions = sessions
        self.hookInstalled = hookInstalled
        self.sampledAt = sampledAt
    }

    public static let unavailable = ActivityState(
        sessions: [], hookInstalled: false, sampledAt: .distantPast
    )

    public var activeSessions: [ActivitySession] {
        sessions.filter { $0.status != .idle }
    }

    public var attentionSessions: [ActivitySession] {
        sessions.filter(\.needsAttention)
    }

    public var totalAgents: Int {
        sessions.reduce(0) { $0 + max(0, $1.activeAgents) }
    }

    /// The session the header should describe: attention first, then busiest, then most
    /// recently touched.
    public func primarySession(now: Date, staleAfter: TimeInterval) -> ActivitySession? {
        if let attention = attentionSessions.first { return attention }
        let busy = sessions.filter { $0.resolvedStatus(now: now, staleAfter: staleAfter).isBusy }
        if let longest = busy.max(by: { ($0.turnStartedAt ?? .distantFuture) > ($1.turnStartedAt ?? .distantFuture) }) {
            return longest
        }
        return sessions.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
    }
}
