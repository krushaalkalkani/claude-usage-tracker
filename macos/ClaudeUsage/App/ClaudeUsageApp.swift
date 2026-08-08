import SwiftUI
import AppKit
import ClaudeUsageCore

// Entry point lives in `main.swift` so `--render-preview` can short-circuit before any
// scene is created. See that file.
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
                // The panel owns the 1 Hz clock only while it is on screen.
                .onAppear { model.isPopoverOpen = true }
                .onDisappear { model.isPopoverOpen = false }
        } label: {
            MenuBarLabel(model: model)
        }
        // `.window` gives a real SwiftUI panel rather than an NSMenu, which is what a custom
        // layout needs.
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// A menu-bar-only app: no Dock icon, no main window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModelRegistry.shared.model?.stop()
    }
}

/// The `App` struct's `@State` is not reachable from `AppDelegate`, so the model registers
/// itself here for the terminate hook.
@MainActor
final class AppModelRegistry {
    static let shared = AppModelRegistry()
    weak var model: AppModel?
}

/// The status-item content.
struct MenuBarLabel: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            if model.settings.displayMode != .percentOnly {
                Image(nsImage: icon)
            }
            if model.settings.displayMode != .iconOnly {
                Text(percentText)
                    // Monospaced digits stop the whole menu bar shuffling as the number
                    // changes width.
                    .monospacedDigit()
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .task {
            AppModelRegistry.shared.model = model
            model.start()
        }
        // A menu-bar item cannot show a tooltip, so the accessibility label carries the
        // detail for VoiceOver users.
        .accessibilityLabel(accessibilityText)
    }

    private var icon: NSImage {
        MenuBarIcon.image(
            fraction: model.primaryPercent.map { min($0 / 100, 1) },
            severity: model.overallSeverity,
            tint: model.settings.tintIconOnAlert,
            attention: !model.activity.attentionSessions.isEmpty
        )
    }

    private var percentText: String {
        guard let percent = model.primaryPercent else { return "—" }
        let base = "\(Int(percent.rounded()))%"
        if let tag = model.primaryTag { return base + tag }
        return base
    }

    private var accessibilityText: String {
        guard let percent = model.primaryPercent else { return "Claude usage unavailable" }
        let name = model.primaryLimit?.shortTitle ?? "usage"
        return "Claude \(name) \(Int(percent.rounded())) percent"
    }
}
