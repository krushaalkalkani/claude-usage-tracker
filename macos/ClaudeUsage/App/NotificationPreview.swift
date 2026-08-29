import AppKit
import ClaudeUsageCore

/// `ClaudeUsage --notify-sample [threshold|projected|surge|error|done]` posts one alert of
/// each shape and exits.
///
/// The Settings pane has a Preview button for the same purpose, but a flag is what makes the
/// banners checkable without a running app and a mouse — the notification is the app's main
/// output, and until this existed the only way to see one was to wait for a quota threshold.
enum NotificationPreview {

    @MainActor
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--notify-sample") else { return false }
        let which = args.count > flag + 1 && !args[flag + 1].hasPrefix("-")
            ? args[flag + 1] : "all"

        // UNUserNotificationCenter answers on the main run loop, so this needs a real
        // NSApplication rather than a semaphore — blocking the main thread here deadlocks
        // against the very callback it is waiting for.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let service = NotificationService()
        Task {
            await service.requestAuthorization()
            FileHandle.standardError.write(
                Data("notifications: \(service.currentAvailability.label)\n".utf8)
            )
            for note in samples where which == "all" || which == shortName(note) {
                await service.deliver(note)
                FileHandle.standardError.write(Data("posted: \(note.id)\n".utf8))
                // Banners posted in the same instant collapse into a stack; a beat apart
                // means each one is actually visible.
                try? await Task.sleep(for: .seconds(2))
            }
            exit(0)
        }
        app.run()
        return true
    }

    private static func shortName(_ note: PendingNotification) -> String {
        switch note.category {
        case .usageThreshold: return "threshold"
        case .projectedOverrun: return "projected"
        case .usageSurge: return "surge"
        case .apiAuth: return "error"
        case .claudeCompleted: return "done"
        default: return note.category.rawValue
        }
    }

    /// One of each shape the policy can produce, with the wording it really uses.
    private static var samples: [PendingNotification] {
        [
            PendingNotification(
                id: "sample-threshold",
                category: .usageThreshold,
                title: "Cursor · Grok Bot at 90% used",
                body: "10% left · 1.8%/h · resets in 6h 12m",
                severity: .warning,
                artwork: .percent(10, tint: .warning)
            ),
            PendingNotification(
                id: "sample-projected",
                category: .projectedOverrun,
                title: "Cursor · Grok Bot",
                subtitle: "Empty in 4h 28m at this pace",
                body: "10% left at 1.8%/h — that is 2h 41m short of the reset.",
                severity: .warning,
                artwork: .percent(10, tint: .warning)
            ),
            PendingNotification(
                id: "sample-surge",
                category: .usageSurge,
                title: "Claude · Session",
                subtitle: "Climbing fast — 38% left",
                body: "38% left · 14%/h · resets in 2h 40m",
                severity: .warning,
                artwork: .percent(38, tint: .warning)
            ),
            PendingNotification(
                id: "sample-error",
                category: .apiAuth,
                title: "Cursor",
                subtitle: "Cursor session expired",
                body: "Your Cursor session expired. Reconnect in Settings.",
                severity: .warning,
                artwork: NotificationArtwork(tint: .warning, ring: nil, caption: "!")
            ),
            PendingNotification(
                id: "sample-done",
                category: .claudeCompleted,
                title: "Claude Code · claude-usage-tracker",
                subtitle: "Done",
                body: "Finished after 6m 12s · 2 task(s) open",
                severity: .normal,
                artwork: NotificationArtwork(tint: .normal, ring: nil, caption: "✓")
            ),
        ]
    }
}
