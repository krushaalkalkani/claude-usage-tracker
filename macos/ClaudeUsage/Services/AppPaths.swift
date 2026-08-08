import Foundation

/// Every file this app touches lives under one directory the user can inspect or delete.
public enum AppPaths {
    public static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude-usage-tracker", isDirectory: true)
    }

    public static var sessionsDirectory: URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }

    public static var historyFile: URL { root.appendingPathComponent("history.json") }
    public static var activityRollupFile: URL { root.appendingPathComponent("activity.json") }
    public static var eventsFile: URL { root.appendingPathComponent("events.jsonl") }
    public static var notificationLedgerFile: URL { root.appendingPathComponent("notifications.json") }
    public static var lastUsageFile: URL { root.appendingPathComponent("last-usage.json") }

    @discardableResult
    public static func ensureRoot() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            return false
        }
    }
}

/// Small helpers shared by every on-disk store.
enum AtomicFile {
    /// Writes via a temp file + replace so a crash mid-write cannot leave a truncated file.
    static func write(_ data: Data, to url: URL) throws {
        AppPaths.ensureRoot()
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        // `replaceItemAt` fails when there is nothing to replace, so fall back to a move.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }

    static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}

extension JSONEncoder {
    static let store: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let store: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            guard let date = ISO8601.parse(raw) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date: \(raw)")
            }
            return date
        }
        return d
    }()
}
