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
        // Claude has more sections than ChatGPT, so the ideal height changes when the
        // provider changes. The default content-minimum policy can retain the taller frame
        // and bottom-align the shorter view, leaving an empty strip above it.
        .windowResizability(.contentSize)

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
        let metric = model.menuBarMetric
        return MenuBarIcon.image(
            fraction: metric.map { min($0.percent / 100, 1) },
            severity: metric?.severity ?? .normal,
            tint: model.settings.tintIconOnAlert,
            attention: metric?.provider == .claude && !model.activity.attentionSessions.isEmpty
        )
    }

    private var percentText: String {
        guard let metric = model.menuBarMetric else { return "—" }
        let provider = showProviderTag(for: metric) ? "\(metric.provider.compactTag) " : ""
        let limit = model.settings.showMetricTag ? (metric.limitTag ?? "") : ""
        return "\(provider)\(Int(metric.percent.rounded()))%\(limit)"
    }

    private var accessibilityText: String {
        guard let metric = model.menuBarMetric else {
            return "Claude and ChatGPT usage unavailable"
        }
        let name = metric.limit?.title ?? "usage"
        return "\(metric.provider.displayName) \(name) \(Int(metric.percent.rounded())) percent used"
    }

    private func showProviderTag(for metric: MenuBarUsageMetric) -> Bool {
        metric.provider == .chatgpt || model.liveProviderCount > 1
    }
}
