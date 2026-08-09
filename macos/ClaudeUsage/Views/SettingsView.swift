import SwiftUI
import AppKit
import ClaudeUsageCore

/// Settings, as a sidebar window rather than a `TabView` of grouped forms.
///
/// Five tabs across the top of a 460pt window meant every pane was cramped and scrolling.
/// A sidebar is what macOS itself moved to, it scales to more sections, and it lets the
/// content pane breathe.
struct SettingsView: View {
    @Bindable var model: AppModel
    /// Which pane opens first. Only the preview renderer passes anything but the default.
    var startPane: Pane = .general
    @State private var selected: Pane?
    /// Preview renders bypass the ScrollView and the fixed height: `ImageRenderer` cannot
    /// lay out scrollable content, so a scrolled pane photographs as an empty rectangle.
    var rendersFlat: Bool = false

    private var pane: Pane { selected ?? startPane }

    enum Pane: String, CaseIterable, Identifiable {
        case general, menuBar, notifications, history, privacy
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .menuBar: return "Menu Bar"
            case .notifications: return "Notifications"
            case .history: return "History & Data"
            case .privacy: return "Privacy"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .menuBar: return "menubar.rectangle"
            case .notifications: return "bell"
            case .history: return "chart.xyaxis.line"
            case .privacy: return "hand.raised"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(DS.hairline).frame(width: 1)
            Group {
                if rendersFlat {
                    content
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        content
                            .padding(.horizontal, 20)
                            .padding(.vertical, 18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .background(DS.windowBG)
        }
        .frame(width: 660)
        .frame(height: rendersFlat ? nil : 500)
        .onAppear { model.refreshNotificationAvailability() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Pane.allCases) { item in
                Button {
                    selected = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 16)
                        Text(item.title)
                            .font(DS.label(12, weight: pane == item ? .medium : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(pane == item ? DS.ink : DS.inkMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(pane == item ? DS.dim : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 172, alignment: .top)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(pane.title)
                .font(DS.label(17, weight: .semibold))
                .foregroundStyle(DS.ink)

            switch pane {
            case .general: GeneralPane(model: model)
            case .menuBar: MenuBarPane(model: model)
            case .notifications: NotificationPane(model: model)
            case .history: HistoryPane(model: model)
            case .privacy: PrivacyPane(model: model)
            }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var model: AppModel
    @State private var token = ""
    @State private var saveResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Behaviour") {
                SettingsRow(title: "Refresh every") {
                    Picker("", selection: model.setting(\.refreshInterval)) {
                        ForEach(RefreshInterval.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 130)
                }
                RowRule()
                SettingsRow(
                    title: "Launch at login",
                    subtitle: launchSubtitle,
                    isEnabled: LaunchAtLogin.isAvailable
                ) {
                    Toggle("", isOn: model.setting(\.launchAtLogin))
                        .toggleStyle(.switch)
                }
                RowRule()
                SettingsRow(title: "Dashboard URL") {
                    TextField("", text: model.setting(\.dashboardURL))
                        .textFieldStyle(.roundedBorder)
                        .font(DS.label(11))
                        .frame(width: 240)
                }
            }

            SettingsSection(
                title: "Authentication",
                footnote: "The token is never written to disk in plain text, never logged, and never sent anywhere except api.anthropic.com."
            ) {
                SettingsValueRow(title: "Currently using", value: model.tokenSourceLabel)
                RowRule()
                SettingsValueRow(title: "Detected on this Mac", value: detectedSources)
                RowRule()
                SettingsRow(title: "Replace token", subtitle: "Stored in your login keychain.") {
                    SecureField("", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.label(11))
                        .frame(width: 200)
                }
                RowRule()
                HStack(spacing: 8) {
                    Button("Save to keychain") {
                        saveResult = model.saveToken(token) ? "Saved." : "Keychain write failed."
                        token = ""
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove stored token") {
                        model.disconnect()
                        saveResult = "Removed. Falling back to Claude Code credentials if present."
                    }
                    Spacer(minLength: 4)
                    if let saveResult {
                        Text(saveResult)
                            .font(DS.label(10.5))
                            .foregroundStyle(DS.inkFaint)
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
            }
        }
    }

    private var launchSubtitle: String? {
        if !LaunchAtLogin.isAvailable { return "Available once the app is in /Applications." }
        if model.launchAtLoginState == .requiresApproval {
            return "Approve “ClaudeUsage” in System Settings › General › Login Items."
        }
        return nil
    }

    private var detectedSources: String {
        let sources = model.availableTokenSources()
        return sources.isEmpty ? "None" : sources.map(\.label).joined(separator: ", ")
    }
}

// MARK: - Menu bar

private struct MenuBarPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Appearance") {
                SettingsRow(title: "Show") {
                    Picker("", selection: model.setting(\.displayMode)) {
                        ForEach(MenuBarDisplayMode.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 160)
                }
                RowRule()
                SettingsRow(title: "Percentage represents") {
                    Picker("", selection: model.setting(\.primaryMetric)) {
                        ForEach(PrimaryMetric.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 180)
                }
                RowRule()
                SettingsRow(
                    title: "Tag non-session limits",
                    subtitle: "Adds W, M, or $ after the number, so a high weekly limit cannot be mistaken for a comfortable session."
                ) {
                    Toggle("", isOn: model.setting(\.showMetricTag)).toggleStyle(.switch)
                }
                RowRule()
                SettingsRow(
                    title: "Tint at warning and critical",
                    subtitle: "Off keeps a monochrome template icon at all times."
                ) {
                    Toggle("", isOn: model.setting(\.tintIconOnAlert)).toggleStyle(.switch)
                }
            }

            SettingsSection(
                title: "Local thresholds",
                footnote: "Used only when the API does not send its own severity for a limit."
            ) {
                SettingsRow(title: "Warning at \(Int(model.settings.warningThreshold))%") {
                    Stepper("", value: model.setting(\.warningThreshold), in: 10...99, step: 5)
                }
                RowRule()
                SettingsRow(title: "Critical at \(Int(model.settings.criticalThreshold))%") {
                    Stepper("", value: model.setting(\.criticalThreshold), in: 20...100, step: 5)
                }
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationPane: View {
    @Bindable var model: AppModel

    private var on: Bool { model.settings.notificationsEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Delivery") {
                SettingsRow(title: "Enable notifications") {
                    Toggle("", isOn: model.setting(\.notificationsEnabled)).toggleStyle(.switch)
                }
                RowRule()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("System permission")
                        .font(DS.label(12))
                        .foregroundStyle(DS.ink)
                    Spacer(minLength: 8)
                    Text(model.notificationAvailability.label)
                        .font(DS.figure(11))
                        .foregroundStyle(
                            model.notificationAvailability == .authorized ? DS.inkMuted : DS.tight
                        )
                    if model.notificationAvailability == .denied {
                        Button("Open") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
            }

            SettingsSection(
                title: "Usage alerts",
                footnote: "Each threshold fires at most once per quota window, and re-arms only when utilisation actually drops."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Alert at")
                        .font(DS.label(12))
                        .foregroundStyle(on ? DS.ink : DS.inkFaint)
                    ThresholdPicker(
                        thresholds: Binding(
                            get: { model.settings.usageThresholds },
                            set: { new in model.updateSettings { $0.usageThresholds = new } }
                        )
                    )
                    .disabled(!on)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)

                RowRule()
                toggle("Quota reset", \.notifyOnReset)
                RowRule()
                toggle("Projected to run out before reset", \.notifyOnProjectedOverrun)
                RowRule()
                toggle("Usage suddenly accelerating", \.notifyOnSurge)
                RowRule()
                toggle("API errors and rate limits", \.notifyOnAPIError)
            }

            SettingsSection(title: "Claude Code") {
                toggle("Needs attention (permission, waiting)", \.notifyClaudeCodeAttention)
                RowRule()
                toggle("Long task finished", \.notifyClaudeCodeCompletion)
                RowRule()
                SettingsRow(
                    title: "Only if the turn ran ≥ \(Int(model.settings.longTaskSeconds))s",
                    isEnabled: on && model.settings.notifyClaudeCodeCompletion
                ) {
                    Stepper("", value: model.setting(\.longTaskSeconds), in: 10...600, step: 10)
                }
                RowRule()
                toggle("Errors and rate limits", \.notifyClaudeCodeError)
            }

            SettingsSection(title: "Quiet hours") {
                toggle("Enable quiet hours", \.quietHoursEnabled)
                RowRule()
                SettingsRow(title: "From", isEnabled: on && model.settings.quietHoursEnabled) {
                    TimePicker(minutes: model.setting(\.quietHoursStart))
                }
                RowRule()
                SettingsRow(title: "Until", isEnabled: on && model.settings.quietHoursEnabled) {
                    TimePicker(minutes: model.setting(\.quietHoursEnd))
                }
                RowRule()
                SettingsRow(
                    title: "Still allow critical alerts",
                    isEnabled: on && model.settings.quietHoursEnabled
                ) {
                    Toggle("", isOn: model.setting(\.criticalBypassesQuietHours))
                        .toggleStyle(.switch)
                }
            }
        }
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<AppSettings, Bool>) -> some View {
        SettingsRow(title: title, isEnabled: on) {
            Toggle("", isOn: model.setting(key)).toggleStyle(.switch)
        }
    }
}

private struct ThresholdPicker: View {
    @Binding var thresholds: [Int]
    private let options = [25, 50, 75, 90, 95, 100]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(options, id: \.self) { value in
                let isOn = thresholds.contains(value)
                Button {
                    var set = Set(thresholds)
                    if isOn { set.remove(value) } else { set.insert(value) }
                    thresholds = set.sorted()
                } label: {
                    Text("\(value)%")
                        .font(DS.figure(10.5, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? DS.ink : DS.inkFaint)
                        .frame(width: 40, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isOn ? DS.dim : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isOn ? .clear : DS.hairline, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct TimePicker: View {
    @Binding var minutes: Int

    var body: some View {
        DatePicker(
            "",
            selection: Binding(
                get: {
                    Calendar.current.date(
                        bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()
                    ) ?? Date()
                },
                set: { date in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                    minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .frame(width: 90)
    }
}

// MARK: - History & data

private struct HistoryPane: View {
    @Bindable var model: AppModel
    @State private var cleared = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Local history") {
                SettingsRow(title: "Keep samples for") {
                    Picker("", selection: model.setting(\.historyRetention)) {
                        ForEach(HistoryRetention.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 130)
                }
                RowRule()
                SettingsValueRow(title: "Samples retained", value: "\(model.samples.count)")
                RowRule()
                HStack(spacing: 8) {
                    Button("Clear local history") {
                        model.clearHistory()
                        cleared = true
                    }
                    Spacer(minLength: 4)
                    if cleared {
                        Text("Cleared.").font(DS.label(10.5)).foregroundStyle(DS.inkFaint)
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
            }

            SettingsSection(title: "Claude Code activity") {
                SettingsRow(title: "Track Claude Code activity") {
                    Toggle("", isOn: model.setting(\.activityEnabled)).toggleStyle(.switch)
                }
                RowRule()
                SettingsValueRow(
                    title: "Hook",
                    value: model.activity.hookInstalled ? "Installed" : "Not installed",
                    tint: model.activity.hookInstalled ? DS.healthy : DS.inkFaint
                )
                RowRule()
                SettingsRow(
                    title: "Call a silent session unknown after",
                    subtitle: "\(Int(model.settings.activityStaleSeconds / 60)) minutes",
                    isEnabled: model.settings.activityEnabled
                ) {
                    Stepper(
                        "",
                        value: Binding(
                            get: { model.settings.activityStaleSeconds / 60 },
                            set: { newMinutes in
                                model.updateSettings { $0.activityStaleSeconds = newMinutes * 60 }
                            }
                        ),
                        in: 1...60, step: 1
                    )
                }
                RowRule()
                HStack {
                    Button("Reveal state folder") {
                        NSWorkspace.shared.selectFile(
                            nil, inFileViewerRootedAtPath: AppPaths.root.path
                        )
                    }
                    Spacer()
                }
                .controlSize(.small)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
            }

            SettingsSection(
                title: "Debug",
                footnote: "The report contains the usage response with account identifiers redacted. It never contains your token."
            ) {
                SettingsRow(title: "Show schema notes in the panel") {
                    Toggle("", isOn: model.setting(\.debugMode)).toggleStyle(.switch)
                }
                RowRule()
                HStack(spacing: 8) {
                    Button("Copy sanitized debug report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.debugExport(), forType: .string)
                        copied = true
                    }
                    Spacer(minLength: 4)
                    if copied {
                        Text("Copied.").font(DS.label(10.5)).foregroundStyle(DS.inkFaint)
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "What leaves this Mac") {
                paragraph("Exactly one thing: an HTTPS request to api.anthropic.com carrying your OAuth token, every \(model.settings.refreshInterval.label.lowercased()). There is no analytics endpoint, no crash reporter, and no server belonging to this project.")
            }

            SettingsSection(title: "Where your token lives") {
                paragraph("In your login keychain. If you have not added one, the app reads Claude Code's own credentials from the keychain instead — macOS asks your permission the first time. The token is never written to a file, never logged, and never included in the debug report.")
            }

            SettingsSection(title: "Stored locally") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(files, id: \.0) { name, purpose in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(name)
                                .font(DS.figure(10.5))
                                .foregroundStyle(DS.ink)
                                .frame(width: 132, alignment: .leading)
                            Text(purpose)
                                .font(DS.label(10.5))
                                .foregroundStyle(DS.inkMuted)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)

                RowRule()
                HStack {
                    Button("Reveal folder") {
                        NSWorkspace.shared.selectFile(
                            nil, inFileViewerRootedAtPath: AppPaths.root.path
                        )
                    }
                    Spacer()
                }
                .controlSize(.small)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
            }

            SettingsSection(title: "The Claude Code hook") {
                paragraph("Records: session id, working directory, project folder name, event name, tool name, permission mode, effort level, agent type, and counters.")
                RowRule()
                paragraph("Never records: your prompts, Claude's replies, tool arguments, or tool output. There is no setting to enable that — the code to write it does not exist, and the hook test suite asserts as much.")
            }
        }
    }

    private var files: [(String, String)] {
        [
            ("history.json", "usage percentages and timestamps"),
            ("last-usage.json", "the most recent parsed snapshot"),
            ("sessions/", "Claude Code session metadata"),
            ("events.jsonl", "the last 200 hook event names"),
            ("notifications.json", "which alerts have already fired"),
        ]
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(DS.label(11))
            .foregroundStyle(DS.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
    }
}

// MARK: - Binding helper

extension AppModel {
    /// A two-way binding straight onto a settings field. Defined once here rather than
    /// copy-pasted into every pane.
    func setting<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in self.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
    }

    var tokenSourceLabel: String {
        tokenSource?.label ?? "None detected"
    }
}
