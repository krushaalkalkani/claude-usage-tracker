import Foundation

/// `AppSettings` persisted in `UserDefaults` as one JSON blob.
///
/// Storing the whole struct means adding a setting never needs a migration: a field absent
/// from the stored JSON simply keeps its default.
public final class SettingsStore: @unchecked Sendable {
    private static let key = "settings.v2"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: AppSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cached = Self.read(from: defaults) ?? AppSettings()
    }

    public var current: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    public func update(_ mutate: (inout AppSettings) -> Void) -> AppSettings {
        lock.lock()
        var copy = cached
        mutate(&copy)
        cached = copy
        lock.unlock()
        write(copy)
        return copy
    }

    public func replace(with settings: AppSettings) {
        lock.lock()
        cached = settings
        lock.unlock()
        write(settings)
    }

    public func resetToDefaults() -> AppSettings {
        let fresh = AppSettings()
        replace(with: fresh)
        return fresh
    }

    private func write(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func read(from defaults: UserDefaults) -> AppSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }
}
