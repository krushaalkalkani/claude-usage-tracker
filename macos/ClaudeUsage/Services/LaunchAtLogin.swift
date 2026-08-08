import Foundation
import ServiceManagement

/// Wraps `SMAppService` so the rest of the app can treat "launch at login" as a plain Bool.
///
/// Only works for a registered `.app` bundle; running unbundled reports `.unavailable` rather
/// than throwing, so the Settings toggle can explain itself instead of silently doing nothing.
public enum LaunchAtLogin {
    public enum State: Equatable, Sendable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable

        public var isOn: Bool { self == .enabled }
    }

    public static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    public static var state: State {
        guard isAvailable else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Returns the state after the attempt, so callers can reflect reality rather than intent.
    @discardableResult
    public static func set(_ enabled: Bool) -> State {
        guard isAvailable else { return .unavailable }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            // Registration can fail when the bundle is unsigned or quarantined. Report the
            // real state rather than pretending the toggle worked.
            return state
        }
        return state
    }
}
