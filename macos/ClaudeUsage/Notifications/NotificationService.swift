import Foundation
import UniformTypeIdentifiers
import UserNotifications

/// Delivers what `NotificationPolicy` decided.
///
/// `UNUserNotificationCenter` is the right API, but it only works from a properly bundled
/// application. When the app runs unbundled (e.g. `swift run` during development) or the user
/// has denied permission, we fall back to macOS's own notification mechanism rather than
/// failing silently — an alert the user never sees is worse than an ugly one.
public final class NotificationService: @unchecked Sendable {
    public enum Availability: Equatable, Sendable {
        case authorized
        case denied
        case notDetermined
        /// No bundle identifier — `UNUserNotificationCenter` cannot be used at all.
        case unavailable

        /// `.denied` is not only "the user said no". An ad-hoc-signed build is refused by
        /// the system outright — requestAuthorization fails with "Notifications are not
        /// allowed for this application" — and lands here too. Either way the consequence is
        /// the same and worth stating, because the fallback banner looks like it came from
        /// Script Editor rather than from this app.
        public var label: String {
            switch self {
            case .authorized: return "Allowed"
            case .denied: return "Not allowed — using the plain fallback banner"
            case .notDetermined: return "Not requested yet"
            case .unavailable: return "Unavailable (app not bundled)"
            }
        }
    }

    private let center: UNUserNotificationCenter?
    private let lock = NSLock()
    private var availability: Availability
    /// Used when UNUserNotificationCenter is unusable.
    private let fallbackEnabled: Bool

    public init(fallbackEnabled: Bool = true) {
        // Touching UNUserNotificationCenter.current() without a bundle identifier throws an
        // uncatchable Objective-C exception, so gate on the bundle id first.
        if Bundle.main.bundleIdentifier != nil {
            self.center = UNUserNotificationCenter.current()
            self.availability = .notDetermined
        } else {
            self.center = nil
            self.availability = .unavailable
        }
        self.fallbackEnabled = fallbackEnabled
    }

    public var currentAvailability: Availability {
        lock.lock()
        defer { lock.unlock() }
        return availability
    }

    /// Asks for permission once. Safe to call on every launch.
    public func requestAuthorization() async {
        guard let center else { return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            setAvailability(.authorized)
            return
        case .denied:
            setAvailability(.denied)
            return
        default:
            break
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            setAvailability(granted ? .authorized : .denied)
        } catch {
            setAvailability(.unavailable)
        }
    }

    public func refreshAvailability() async {
        guard let center else { return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: setAvailability(.authorized)
        case .denied: setAvailability(.denied)
        default: setAvailability(.notDetermined)
        }
    }

    public func deliver(_ notifications: [PendingNotification]) async {
        for note in notifications {
            await deliver(note)
        }
    }

    public func deliver(_ note: PendingNotification) async {
        if let center, currentAvailability == .authorized {
            let content = UNMutableNotificationContent()
            content.title = note.title
            if let subtitle = note.subtitle { content.subtitle = subtitle }
            content.body = note.body
            content.sound = note.severity == .critical ? .defaultCritical : .default
            content.interruptionLevel = note.severity == .critical ? .timeSensitive : .active
            if let attachment = makeAttachment(for: note) {
                content.attachments = [attachment]
            }
            // A stable identifier means a repeat of the same alert replaces rather than
            // stacks in Notification Center.
            let request = UNNotificationRequest(
                identifier: note.id, content: content, trigger: nil
            )
            do {
                try await center.add(request)
                return
            } catch {
                // Fall through to the fallback below.
            }
        }
        if fallbackEnabled { deliverViaFallback(note) }
    }

    /// Renders the notification's thumbnail to a temp PNG and wraps it for UserNotifications.
    ///
    /// The system *moves* the file into its own store on success, so nothing needs cleaning
    /// up afterwards — but it leaves the file where it is on failure, hence the unlink.
    /// Artwork is never load-bearing: if any of this fails the notification still goes out,
    /// just without a picture.
    private func makeAttachment(for note: PendingNotification) -> UNNotificationAttachment? {
        guard let artwork = note.artwork,
              let url = NotificationArtworkRenderer.write(artwork)
        else { return nil }
        do {
            return try UNNotificationAttachment(
                identifier: "artwork", url: url,
                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier]
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// `display notification` via osascript. Only reached when the modern API is unusable.
    private func deliverViaFallback(_ note: PendingNotification) {
        var script = """
        display notification \(appleScriptString(note.body)) \
        with title \(appleScriptString(note.title))
        """
        // No attachment support here, but the subtitle survives — worth keeping, since this
        // path is what unsigned development builds actually see.
        if let subtitle = note.subtitle {
            script += " subtitle \(appleScriptString(subtitle))"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Escapes text for embedding in an AppleScript literal. Notification bodies are built
    /// from our own strings plus API values, so this must be airtight.
    private func appleScriptString(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private func setAvailability(_ value: Availability) {
        lock.lock()
        availability = value
        lock.unlock()
    }
}
