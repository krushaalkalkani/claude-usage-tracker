import SwiftUI
import AppKit
import ClaudeUsageCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettings(model: model)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            NotificationSettings(model: model)
                .tabItem { Label("Notifications", systemImage: "bell") }
            HistorySettings(model: model)
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
            PrivacySettings(model: model)
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 460, height: 400)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var token = ""
    @State private var saveResult: String?

    var body: some View {
        Form {
            Section {
                Picker("Refresh every", selection: model.setting(\.refreshInterval)) {
                    ForEach(RefreshInterval.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Launch at login", isOn: model.setting(\.launchAtLogin))
                    .disabled(!LaunchAtLogin.isAvailable)
                if !LaunchAtLogin.isAvailable {
                    Text("Available once the app is installed to /Applications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.launchAtLoginState == .requiresApproval {
                    Text("Approve “ClaudeUsage” in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                TextField("Dashboard URL", text: model.setting(\.dashboardURL))
            }

            Section("Authentication") {
                LabeledContent("Currently using") {
                    Text(model.tokenSourceLabel)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Detected") {
                    Text(detectedSources)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                SecureField("Replace token", text: $token)
                HStack {
                    Button("Save to keychain") {
                        saveResult = model.saveToken(token)
                            ? "Saved." : "Keychain write failed."
                        token = ""
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove stored token", role: .destructive) {
                        model.disconnect()
                        saveResult = "Removed. Falling back to Claude Code credentials if present."
                    }
                    Spacer()
                }
                if let saveResult {
                    Text(saveResult).font(.caption).foregroundStyle(.secondary)
                }
                Text("The token is never written to disk in plain text, never logged, and never sent anywhere except api.anthropic.com.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var detectedSources: String {
        let sources = model.availableTokenSources()
        return sources.isEmpty ? "None" : sources.map(\.label).joined(separator: ", ")
    }
}

// MARK: - Menu bar

private struct MenuBarSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Show", selection: model.setting(\.displayMode)) {
                    ForEach(MenuBarDisplayMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Percentage represents", selection: model.setting(\.primaryMetric)) {
                    ForEach(PrimaryMetric.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Tag the number when it is not the session limit", isOn: model.setting(\.showMetricTag))
                Text("Adds W, M, or $ after the percentage so a high weekly limit cannot be mistaken for a comfortable session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Tint the icon at warning and critical", isOn: model.setting(\.tintIconOnAlert))
                Text("Off keeps a monochrome template icon at all times.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local thresholds") {
                Stepper(
                    "Warning at \(Int(model.settings.warningThreshold))%",
                    value: model.setting(\.warningThreshold), in: 10...99, step: 5
                )
                Stepper(
                    "Critical at \(Int(model.settings.criticalThreshold))%",
                    value: model.setting(\.criticalThreshold), in: 20...100, step: 5
                )
                Text("Used only when the API does not send its own severity for a limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notifications

private struct NotificationSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Enable notifications", isOn: model.setting(\.notificationsEnabled))
                LabeledContent("System permission") {
                    HStack(spacing: 6) {
                        Text(model.notificationAvailability.label)
                            .foregroundStyle(.secondary)
                        if model.notificationAvailability == .denied {
                            Button("Open Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section("Usage") {
                ThresholdEditor(
                    thresholds: Binding(
                        get: { model.settings.usageThresholds },
                        set: { new in model.updateSettings { $0.usageThresholds = new } }
                    )
                )
                Toggle("Quota reset", isOn: model.setting(\.notifyOnReset))
                Toggle("Projected to run out before reset", isOn: model.setting(\.notifyOnProjectedOverrun))
                Toggle("Usage suddenly accelerating", isOn: model.setting(\.notifyOnSurge))
                Toggle("API errors and rate limits", isOn: model.setting(\.notifyOnAPIError))
            }

            Section("Claude Code") {
                Toggle("Needs attention (permission, waiting)", isOn: model.setting(\.notifyClaudeCodeAttention))
                Toggle("Long task finished", isOn: model.setting(\.notifyClaudeCodeCompletion))
                Stepper(
                    "Only if it ran ≥ \(Int(model.settings.longTaskSeconds))s",
                    value: model.setting(\.longTaskSeconds), in: 10...600, step: 10
                )
                .disabled(!model.settings.notifyClaudeCodeCompletion)
                Toggle("Errors and rate limits", isOn: model.setting(\.notifyClaudeCodeError))
            }

            Section("Quiet hours") {
                Toggle("Enable quiet hours", isOn: model.setting(\.quietHoursEnabled))
                HStack {
                    TimeOfDayPicker(label: "From", minutes: model.setting(\.quietHoursStart))
                    TimeOfDayPicker(label: "To", minutes: model.setting(\.quietHoursEnd))
                }
                .disabled(!model.settings.quietHoursEnabled)
                Toggle("Still allow critical alerts", isOn: model.setting(\.criticalBypassesQuietHours))
                    .disabled(!model.settings.quietHoursEnabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshNotificationAvailability() }
    }
}

private struct ThresholdEditor: View {
    @Binding var thresholds: [Int]
    private let options = [25, 50, 75, 90, 95, 100]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Alert at").font(.callout)
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { value in
                    Toggle("\(value)%", isOn: Binding(
                        get: { thresholds.contains(value) },
                        set: { on in
                            var set = Set(thresholds)
                            if on { set.insert(value) } else { set.remove(value) }
                            thresholds = set.sorted()
                        }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
            }
            Text("Each threshold fires at most once per quota window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TimeOfDayPicker: View {
    let label: String
    @Binding var minutes: Int

    var body: some View {
        DatePicker(
            label,
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
        .overlay(alignment: .leading) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .offset(x: -34)
        }
    }
}

// MARK: - History

private struct HistorySettings: View {
    @Bindable var model: AppModel
    @State private var cleared = false

    var body: some View {
        Form {
            Section {
                Picker("Keep samples for", selection: model.setting(\.historyRetention)) {
                    ForEach(HistoryRetention.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Samples retained") {
                    Text("\(model.samples.count)").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Clear local history", role: .destructive) {
                        model.clearHistory()
                        cleared = true
                    }
                    if cleared {
                        Text("Cleared.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            Section("Claude Code activity") {
                Toggle("Track Claude Code activity", isOn: model.setting(\.activityEnabled))
                LabeledContent("Hook") {
                    Text(model.activity.hookInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(.secondary)
                }
                Stepper(
                    "Treat a silent session as unknown after \(Int(model.settings.activityStaleSeconds / 60))m",
                    value: Binding(
                        get: { model.settings.activityStaleSeconds / 60 },
                        set: { newMinutes in
                            model.updateSettings { $0.activityStaleSeconds = newMinutes * 60 }
                        }
                    ),
                    in: 1...60, step: 1
                )
                Button("Reveal state folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppPaths.root.path)
                }
            }

            Section("Debug") {
                Toggle("Show schema notes in the panel", isOn: model.setting(\.debugMode))
                Button("Copy sanitized debug report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.debugExport(), forType: .string)
                }
                Text("Contains the usage response with account identifiers redacted. Never contains your token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    head("What leaves this Mac")
                    body("Exactly one thing: an HTTPS request to api.anthropic.com carrying your OAuth token, every \(model.settings.refreshInterval.label.lowercased()). There is no analytics endpoint, no crash reporter, and no server belonging to this project.")

                    head("Where your token lives")
                    body("In your login keychain. If you have not added one, the app reads Claude Code's own credentials from the keychain instead — macOS asks your permission the first time. The token is never written to a file, never logged, and never included in the debug report.")

                    head("What is stored locally")
                    body("""
                    ~/.claude-usage-tracker/
                      history.json      usage percentages and timestamps
                      last-usage.json   the most recent parsed snapshot
                      sessions/         Claude Code session metadata
                      events.jsonl      the last 200 hook event names
                      notifications.json  which alerts have already fired
                    """)

                    head("What the Claude Code hook records")
                    body("Session id, working directory, project folder name, event name, tool name, permission mode, effort level, agent type, and counters.")

                    head("What it never records")
                    body("Your prompts, Claude's replies, tool arguments, and tool output. There is no setting to enable that — the code to write it does not exist.")
                }
                HStack {
                    Button("Reveal folder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppPaths.root.path)
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func head(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold))
    }

    private func body(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension AppModel {
    /// A two-way binding straight onto a settings field. Defined once here rather than
    /// copy-pasted into every settings tab.
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
