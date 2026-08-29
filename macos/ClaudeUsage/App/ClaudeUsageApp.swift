import SwiftUI
import AppKit
import ClaudeUsageCore

// Entry point lives in `main.swift` so `--render-preview` can short-circuit before any
// scene is created. See that file.
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra(isInserted: Binding<Bool>(
            get: { model.shouldAppearInMenuBar }, set: { _ in }
        )) {
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

    /// Launching the app again while it is already running (`open -a ClaudeUsage`, or
    /// double-clicking it in Finder) fires this. It is the escape hatch for "hide when
    /// healthy": the icon comes back for a grace period so Settings is reachable.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppModelRegistry.shared.model?.revealMenuBarTemporarily()
        return true
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
        let now = Date()
        let style = MenuBarIcon.Style(rawValue: model.settings.menuBarIconStyle) ?? .twinBars
        let metric = model.menuBarMetric

        // The bars show every connected provider, so they read them directly rather than
        // going through the single "selected metric" the other styles use.
        let connected = model.connectedProviders
        let input = MenuBarIcon.Input(
            levels: style.showsBothProviders
                ? connected.map { model.providerRemainingPercent($0, now: now).map { $0 / 100 } }
                : [metric.map { min($0.remainingPercent / 100, 1) }],
            severity: metric?.severity ?? .normal,
            tint: model.settings.tintIconOnAlert,
            attention: !model.activity.attentionSessions.isEmpty,
            labels: style.showsBothProviders
                ? connected.map(\.displayName)
                : [metric?.provider.displayName ?? "Usage"]
        )
        return MenuBarIcon.image(style: style, input)
    }

    private var percentText: String {
        guard let metric = model.menuBarMetric else { return "—" }
        let provider = showProviderTag(for: metric) ? "\(metric.provider.compactTag) " : ""
        let limit = model.settings.showMetricTag ? (metric.limitTag ?? "") : ""
        // What is left, matching the panel this item opens. It read utilisation before, so
        // clicking a menu bar showing "55%" opened a panel headlined "45%".
        return "\(provider)\(Int(metric.remainingPercent.rounded()))%\(limit)"
    }

    private var accessibilityText: String {
        guard let metric = model.menuBarMetric else {
            return "Usage unavailable"
        }
        let name = metric.limit?.title ?? "usage"
        return "\(metric.provider.displayName) \(name), \(Int(metric.remainingPercent.rounded())) percent left"
    }

    /// Claude keeps its historical tag-free look when it is the only live provider; every
    /// other provider always shows its tag so it is never mistaken for Claude.
    private func showProviderTag(for metric: MenuBarUsageMetric) -> Bool {
        metric.provider != .claude || model.liveProviderCount > 1
    }
}
