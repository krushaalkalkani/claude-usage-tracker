import Foundation

/// Reads the metadata files the Claude Code hook writes and turns them into an
/// `ActivityState`.
///
/// The app is the aggregator, not the hook: each hook invocation only ever writes its own
/// session file, so two Claude Code sessions can never race each other, and a crashed hook
/// can only ever corrupt one session's record.
public final class ActivityMonitor: @unchecked Sendable {
    private let sessionsDirectory: URL
    private let now: @Sendable () -> Date
    private let processIsAlive: @Sendable (Int) -> Bool

    public init(
        sessionsDirectory: URL = AppPaths.sessionsDirectory,
        now: @escaping @Sendable () -> Date = { Date() },
        processIsAlive: @escaping @Sendable (Int) -> Bool = ActivityMonitor.defaultProcessCheck
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.now = now
        self.processIsAlive = processIsAlive
    }

    /// `kill(pid, 0)` succeeds when the process exists and we may signal it, and sets EPERM
    /// when it exists but belongs to someone else. Only ESRCH means "gone".
    public static let defaultProcessCheck: @Sendable (Int) -> Bool = { pid in
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// Reads the current state. Also reaps records belonging to dead Claude Code processes.
    public func read(staleAfter: TimeInterval, reapDead: Bool = true) -> ActivityState {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            // No directory at all means the hook has never run here.
            return ActivityState(sessions: [], hookInstalled: false, sampledAt: now())
        }

        let files = entries.filter { $0.pathExtension == "json" }
        var sessions: [ActivitySession] = []

        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let session = decode(data)
            else { continue }

            // A record whose Claude Code process is gone is history, not activity.
            if reapDead, let pid = session.claudePid, !processIsAlive(pid) {
                try? fm.removeItem(at: file)
                continue
            }
            sessions.append(session)
        }

        // Newest first; a session needing attention always sorts to the top.
        sessions.sort { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
        }

        let resolved = sessions.map { session -> ActivitySession in
            var copy = session
            copy.status = session.resolvedStatus(now: now(), staleAfter: staleAfter)
            // A stale record's attention flag is no more trustworthy than its status.
            if copy.status == .stale { copy.needsAttention = false }
            return copy
        }

        return ActivityState(sessions: resolved, hookInstalled: true, sampledAt: now())
    }

    /// Tolerant decoding: a session file written by a newer hook version must not break an
    /// older app, and vice versa.
    private func decode(_ data: Data) -> ActivitySession? {
        guard let json = try? JSONValue.parse(data),
              let sessionId = json["sessionId"]?.stringValue
        else { return nil }

        return ActivitySession(
            schema: json["schema"]?.intValue ?? 1,
            sessionId: sessionId,
            project: json["project"]?.stringValue,
            cwd: json["cwd"]?.stringValue,
            model: json["model"]?.stringValue,
            status: json["status"]?.stringValue.flatMap(ActivityStatus.init(rawValue:)) ?? .idle,
            statusDetail: json["statusDetail"]?.stringValue,
            activeAgents: json["activeAgents"]?.intValue ?? 0,
            openTasks: json["openTasks"]?.intValue ?? 0,
            lastEvent: json["lastEvent"]?.stringValue,
            lastEventAt: json["lastEventAt"]?.dateValue,
            startedAt: json["startedAt"]?.dateValue,
            turnStartedAt: json["turnStartedAt"]?.dateValue,
            lastCompletedAt: json["lastCompletedAt"]?.dateValue,
            lastTurnSeconds: json["lastTurnSeconds"]?.doubleValue,
            needsAttention: json["needsAttention"]?.boolValue ?? false,
            attentionReason: json["attentionReason"]?.stringValue,
            permissionMode: json["permissionMode"]?.stringValue,
            effort: json["effort"]?.stringValue,
            lastError: json["lastError"]?.stringValue,
            claudePid: json["claudePid"]?.intValue,
            updatedAt: json["updatedAt"]?.dateValue
        )
    }
}

/// Watches the sessions directory and calls back when anything changes, so the UI updates the
/// instant Claude Code needs attention rather than on the next poll.
///
/// A directory-level `DispatchSource` costs nothing while idle — no timer, no polling — which
/// matters for an app meant to run all day on battery.
public final class ActivityWatcher: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.krushal.claude-usage-tracker.activity-watch")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private let onChange: @Sendable () -> Void
    /// Bursty hook writes (one per tool call) are collapsed into a single callback.
    private var pendingWork: DispatchWorkItem?
    private let debounce: TimeInterval

    /// - Parameter debounce: a busy Claude Code session writes a file per tool call, so this
    ///   collapses bursts. One second keeps "needs permission" feeling immediate while
    ///   keeping the directory scan off the hot path.
    public init(
        url: URL = AppPaths.sessionsDirectory,
        debounce: TimeInterval = 1.0,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.source == nil else { return }
            try? FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true)

            let fd = open(self.url.path, O_EVTONLY)
            guard fd >= 0 else { return }
            self.descriptor = fd

            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .extend],
                queue: self.queue
            )
            src.setEventHandler { [weak self] in self?.scheduleCallback() }
            src.setCancelHandler { [fd] in close(fd) }
            self.source = src
            src.resume()
        }
    }

    private func scheduleCallback() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingWork?.cancel()
            self.pendingWork = nil
            self.source?.cancel()
            self.source = nil
            self.descriptor = -1
        }
    }

    deinit {
        pendingWork?.cancel()
        source?.cancel()
    }
}
