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

    public func load(provider: UsageProvider) -> [UsageSample] {
        load().filter { $0.provider == provider }
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
        if let duplicate = samples.lastIndex(where: {
            $0.provider == sample.provider && abs($0.t.timeIntervalSince(sample.t)) < 1
        }) {
            samples[duplicate] = sample
        } else {
            samples.append(sample)
            if let last = samples.last, samples.count > 1, last.t < samples[samples.count - 2].t {
                samples.sort { $0.t < $1.t }
            }
        }

        prune(retention: retention, now: now)
        dirty = true
        persistIfDue(now: now)
        return samples.filter { $0.provider == sample.provider }
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
            // Everything is older than the cutoff; keep the newest for each provider so
            // pruning one provider can never make the other provider's trend disappear.
            samples = UsageProvider.allCases.compactMap { provider in
                samples.last { $0.provider == provider }
            }.sorted { $0.t < $1.t }
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
    public static func save(
        _ snapshot: UsageSnapshot,
        provider: UsageProvider? = nil,
        url: URL? = nil
    ) {
        // `raw` is excluded by UsageSnapshot's CodingKeys, so the payload's workspace and
        // organization identifiers never reach disk.
        guard let data = try? JSONEncoder.store.encode(snapshot) else { return }
        let owner = provider ?? snapshot.provider
        try? AtomicFile.write(data, to: url ?? AppPaths.lastUsageFile(for: owner))
    }

    public static func load(
        provider: UsageProvider = .claude,
        url: URL? = nil
    ) -> UsageSnapshot? {
        guard let data = AtomicFile.read(url ?? AppPaths.lastUsageFile(for: provider)),
              let decoded = try? JSONDecoder.store.decode(UsageSnapshot.self, from: data)
        else { return nil }
        // A legacy file has no provider and therefore decodes as Claude. Never allow a cache
        // passed under the wrong provider to cross-contaminate state.
        guard decoded.provider == provider else { return nil }
        return decoded
    }

    public static func clear(provider: UsageProvider = .claude, url: URL? = nil) {
        try? FileManager.default.removeItem(at: url ?? AppPaths.lastUsageFile(for: provider))
    }
}
