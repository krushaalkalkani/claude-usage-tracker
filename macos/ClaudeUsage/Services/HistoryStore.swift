import Foundation

/// Local, append-mostly store of usage samples. No cloud, no backend, no telemetry.
///
/// Kept deliberately dumb: an array of samples, pruned on write, rewritten atomically. A week
/// of 2-minute samples is about 5 000 entries — small enough that a full rewrite costs
/// microseconds and is far safer than incremental append with partial-line recovery.
public final class HistoryStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var samples: [UsageSample] = []
    private var loaded = false
    /// Rewriting on every poll is wasteful; batch to at most one write per this interval
    /// unless a flush is requested.
    private let minimumWriteInterval: TimeInterval
    private var lastWriteAt: Date?
    private var dirty = false

    public init(url: URL = AppPaths.historyFile, minimumWriteInterval: TimeInterval = 60) {
        self.url = url
        self.minimumWriteInterval = minimumWriteInterval
    }

    public func load() -> [UsageSample] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return samples
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = AtomicFile.read(url) else { return }
        // A corrupt history file is not worth failing over — start fresh rather than crash.
        samples = (try? JSONDecoder.store.decode([UsageSample].self, from: data)) ?? []
        samples.sort { $0.t < $1.t }
    }

    /// Records a sample and returns the pruned series.
    @discardableResult
    public func append(_ sample: UsageSample, retention: TimeInterval, now: Date = Date()) -> [UsageSample] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()

        // Guard against duplicate timestamps from a double-fire refresh.
        if let last = samples.last, abs(last.t.timeIntervalSince(sample.t)) < 1 {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
            if let last = samples.last, samples.count > 1, last.t < samples[samples.count - 2].t {
                samples.sort { $0.t < $1.t }
            }
        }

        prune(retention: retention, now: now)
        dirty = true
        persistIfDue(now: now)
        return samples
    }

    /// Forces a write. Called on quit and when settings change.
    public func flush(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard dirty else { return }
        persist()
        lastWriteAt = now
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        loaded = true
        samples = []
        dirty = false
        lastWriteAt = nil
        try? FileManager.default.removeItem(at: url)
    }

    public func applyRetention(_ retention: TimeInterval, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        let before = samples.count
        prune(retention: retention, now: now)
        if samples.count != before {
            dirty = true
            persist()
            lastWriteAt = now
        }
    }

    // MARK: private

    private func prune(retention: TimeInterval, now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        if let firstKept = samples.firstIndex(where: { $0.t >= cutoff }) {
            if firstKept > 0 { samples.removeFirst(firstKept) }
        } else if !samples.isEmpty, samples.last!.t < cutoff {
            // Everything is older than the cutoff; keep the newest so the UI is not blank.
            samples = [samples[samples.count - 1]]
        }
        // Hard ceiling as a belt-and-braces guard against unbounded growth if a clock jumps.
        let maxSamples = 20_000
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    private func persistIfDue(now: Date) {
        if let lastWriteAt, now.timeIntervalSince(lastWriteAt) < minimumWriteInterval { return }
        persist()
        lastWriteAt = now
    }

    private func persist() {
        guard let data = try? JSONEncoder.store.encode(samples) else { return }
        try? AtomicFile.write(data, to: url)
        dirty = false
    }
}

/// Persists the last successful snapshot so a cold launch shows real numbers, clearly
/// labelled with their age, instead of zeros.
public enum LastUsageCache {
    public static func save(_ snapshot: UsageSnapshot) {
        // `raw` is excluded by UsageSnapshot's CodingKeys, so the payload's workspace and
        // organization identifiers never reach disk.
        guard let data = try? JSONEncoder.store.encode(snapshot) else { return }
        try? AtomicFile.write(data, to: AppPaths.lastUsageFile)
    }

    public static func load() -> UsageSnapshot? {
        guard let data = AtomicFile.read(AppPaths.lastUsageFile) else { return nil }
        return try? JSONDecoder.store.decode(UsageSnapshot.self, from: data)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: AppPaths.lastUsageFile)
    }
}
