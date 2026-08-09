import SwiftUI
import AppKit
import ClaudeUsageCore

/// Renders the popover to PNGs without launching the menu bar app.
///
/// `ClaudeUsage --render-preview <dir>` writes one image per scenario in both appearances.
/// It exists so layout changes can be reviewed as pictures rather than described, and so the
/// README screenshots are reproducible instead of hand-captured.
enum PreviewRenderer {

    @MainActor
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--render-preview"), args.count > flag + 1 else {
            return false
        }
        let outDir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for scenario in Scenario.all {
            for dark in [false, true] {
                render(scenario, dark: dark, into: outDir)
            }
        }
        for pane in SettingsView.Pane.allCases {
            for dark in [false, true] {
                renderSettings(pane, dark: dark, into: outDir)
            }
        }
        return true
    }

    @MainActor
    private static func render(_ scenario: Scenario, dark: Bool, into dir: URL) {
        let model = scenario.makeModel()
        // The real panel sits on a translucent system material, which renders as nothing in
        // an offscreen pass. Compositing over a representative backdrop keeps the preview
        // honest about contrast.
        let backdrop = dark
            ? Color(nsColor: NSColor(hex: 0x2B2B30))
            : Color(nsColor: NSColor(hex: 0xF3F3F5))

        let view = PopoverView(model: model)
            .background(backdrop)
            .environment(\.colorScheme, dark ? .dark : .light)

        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write(Data("render failed: \(scenario.name)\n".utf8))
                return
            }
            let url = dir.appendingPathComponent("\(scenario.name)-\(dark ? "dark" : "light").png")
            try? png.write(to: url)
            print(url.path)
        }
    }

    @MainActor
    private static func renderSettings(_ pane: SettingsView.Pane, dark: Bool, into dir: URL) {
        let model = Scenario.all[1].makeModel()
        let view = SettingsView(model: model, startPane: pane, rendersFlat: true)
            .environment(\.colorScheme, dark ? .dark : .light)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { return }
            let url = dir.appendingPathComponent(
                "settings-\(pane.rawValue)-\(dark ? "dark" : "light").png"
            )
            try? png.write(to: url)
            print(url.path)
        }
    }

    // MARK: Scenarios

    struct Scenario {
        let name: String
        let makeModel: @MainActor () -> AppModel

        static let all: [Scenario] = [
            Scenario(name: "healthy") { model(percent: 22, weekly: 14, model: 9, burning: 4) },
            Scenario(name: "critical") { model(percent: 88, weekly: 36, model: 51, burning: 44) },
            Scenario(name: "weekly-bottleneck") { model(percent: 25, weekly: 91, model: 44, burning: 6) },
            Scenario(name: "error") {
                let m = model(percent: 67, weekly: 36, model: 51, burning: 44)
                m.previewApply(error: .unauthorized)
                return m
            },
        ]
    }

    @MainActor
    private static func model(
        percent: Double, weekly: Double, model modelPct: Double, burning: Double
    ) -> AppModel {
        let now = Date()
        let sessionReset = now.addingTimeInterval(64 * 60)
        let weeklyReset = now.addingTimeInterval(5 * 86_400 + 3_600)

        let severity: (Double) -> Severity = { Severity.from(percent: $0) }

        let limits = [
            LimitWindow(
                id: "session", kind: "session", group: .session,
                title: "5-hour limit", shortTitle: "Session",
                percent: percent, resetsAt: sessionReset, severity: severity(percent),
                isActive: true
            ),
            LimitWindow(
                id: "weekly_all", kind: "weekly_all", group: .weekly,
                title: "7-day limit", shortTitle: "Weekly",
                percent: weekly, resetsAt: weeklyReset, severity: severity(weekly)
            ),
            LimitWindow(
                id: "weekly_scoped|m:fable", kind: "weekly_scoped", group: .weekly,
                title: "Fable · 7-day", shortTitle: "Fable",
                percent: modelPct, resetsAt: weeklyReset, severity: severity(modelPct),
                isActive: true, modelName: "Fable"
            ),
        ]

        let spend = SpendInfo(
            enabled: false,
            used: Money(amountMinor: 3303), limit: Money(amountMinor: 3000),
            percent: 100, severity: .critical,
            disabledReason: "org_level_disabled_until", userDisabled: false,
            limitReached: true, everEnabled: true, balance: nil,
            disclaimer: "Amounts are estimates and may lag actual billing."
        )

        // Two hours of samples climbing at `burning` %/h — enough evidence for the session
        // window's proportional guard, and enough to draw a trend line.
        var samples: [UsageSample] = []
        let steps = 24
        for i in 0...steps {
            let t = now.addingTimeInterval(-Double(steps - i) * 300)
            let elapsedHours = Double(steps - i) * 300 / 3600
            samples.append(UsageSample(t: t, limits: [
                "session": max(0, percent - burning * elapsedHours),
                "weekly_all": max(0, weekly - 0.4 * elapsedHours),
                "weekly_scoped|m:fable": max(0, modelPct - 1.2 * elapsedHours),
            ], spend: 100))
        }

        let activity = ActivityState(
            sessions: [
                ActivitySession(
                    sessionId: "a", project: "finance-app", cwd: "/Users/x/finance-app",
                    status: .runningTool, statusDetail: "Bash", activeAgents: 2,
                    lastEventAt: now, startedAt: now.addingTimeInterval(-1_200),
                    turnStartedAt: now.addingTimeInterval(-186),
                    claudePid: 1, updatedAt: now
                ),
                ActivitySession(
                    sessionId: "b", project: "claude-usage-tracker",
                    cwd: "/Users/x/claude-usage-tracker",
                    status: .permissionRequired, lastEventAt: now,
                    needsAttention: true, attentionReason: "Permission requested",
                    claudePid: 1, updatedAt: now.addingTimeInterval(-40)
                ),
            ],
            hookInstalled: true, sampledAt: now
        )

        return AppModel.preview(
            snapshot: UsageSnapshot(fetchedAt: now, limits: limits, spend: spend),
            activity: activity,
            samples: samples,
            now: now
        )
    }
}
