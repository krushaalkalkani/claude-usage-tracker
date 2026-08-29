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
        renderStatusItem(into: outDir)
        return true
    }

    /// The status-item glyph at the sizes it is actually drawn, blown up so the shapes are
    /// reviewable. It had no preview at all, which is why a hardcoded two-provider icon
    /// survived the arrival of a third and a fourth.
    @MainActor
    private static func renderStatusItem(into dir: URL) {
        // One row per style; within a row, a full account down to an empty one, then the
        // multi-provider case and the no-data case.
        let cases: [(String, MenuBarIcon.Input)] = [
            ("full", .init(levels: [1.0], labels: ["Claude"])),
            ("half", .init(levels: [0.5], severity: .warning, labels: ["Claude"])),
            ("low", .init(levels: [0.08], severity: .critical, labels: ["Claude"])),
            ("empty", .init(levels: [0.0], severity: .critical, labels: ["Claude"])),
            ("four", .init(
                levels: [0.47, 0.36, 0.38, nil],
                labels: UsageProvider.allCases.map(\.displayName)
            )),
            ("attention", .init(levels: [0.62], attention: true, labels: ["Claude"])),
            ("unknown", .init(levels: [nil], labels: ["Claude"])),
        ]
        let scale: CGFloat = 6
        let rowH = 16 * scale + 8

        for style in MenuBarIcon.Style.allCases {
            var x: CGFloat = 4
            var images: [(NSImage, CGFloat)] = []
            for (_, input) in cases {
                let image = MenuBarIcon.image(style: style, input)
                images.append((image, x))
                x += image.size.width * scale + 16
            }
            let sheet = NSImage(size: NSSize(width: x, height: rowH), flipped: false) { _ in
                // A light menu bar: template glyphs are drawn as black with real alpha, so
                // they read directly here without any tinting pass. (Tinting them would mean
                // compositing over this backdrop, which paints the whole box, not the glyph.)
                NSColor(hex: 0xF3F3F5).setFill()
                NSRect(x: 0, y: 0, width: x, height: rowH).fill()
                for (image, ox) in images {
                    image.draw(in: NSRect(
                        x: ox, y: 4,
                        width: image.size.width * scale, height: 16 * scale
                    ))
                }
                return true
            }
            guard let tiff = sheet.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { continue }
            let url = dir.appendingPathComponent("statusitem-\(style.rawValue).png")
            try? png.write(to: url)
            print(url.path)
        }
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
        let model = pane == .providers
            ? Scenario.all.first { $0.name == "both-providers" }!.makeModel()
            : Scenario.all[1].makeModel()
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
            Scenario(name: "chatgpt-healthy") {
                chatGPTModel(session: 24, weekly: 18, additional: 12)
            },
            Scenario(name: "chatgpt-session-close") {
                chatGPTModel(session: 94, weekly: 42, additional: 20)
            },
            Scenario(name: "chatgpt-weekly-bottleneck") {
                chatGPTModel(session: 37, weekly: 92, additional: 54)
            },
            Scenario(name: "chatgpt-disconnected") {
                let m = model(percent: 53, weekly: 32, model: 18, burning: 2)
                m.previewApply(
                    provider: .chatgpt, error: .codexAuthenticationRequired,
                    cliDetected: true
                )
                return m
            },
            Scenario(name: "provider-failure-chatgpt") {
                let m = model(percent: 53, weekly: 32, model: 18, burning: 2)
                let fixture = chatGPTFixture(session: 24, weekly: 64, additional: 31)
                m.previewApply(
                    snapshot: fixture.snapshot, samples: fixture.samples,
                    plan: "Pro", error: .offline, select: true
                )
                return m
            },
            Scenario(name: "both-providers") {
                let m = model(percent: 53, weekly: 32, model: 18, burning: 2)
                let fixture = chatGPTFixture(session: 24, weekly: 64, additional: 31)
                m.previewApply(
                    snapshot: fixture.snapshot, samples: fixture.samples,
                    plan: "Pro", select: true
                )
                return m
            },
            // Cursor had no scenario of its own, which is how a hero eyebrow reading
            // "Cursor Models · cursor models included" shipped unnoticed: every window it
            // reports is `.other`, a group no other provider uses.
            Scenario(name: "cursor-healthy") { cursorModel() },
            Scenario(name: "cursor-included-spent") {
                cursorModel(cursorModels: 100, otherModels: 46, grokBot: 61)
            },
            Scenario(name: "grok-healthy") { grokModel(percent: 38) },
            Scenario(name: "grok-exhausted") { grokModel(percent: 100) },
            Scenario(name: "grok-disconnected") {
                let m = model(percent: 53, weekly: 32, model: 18, burning: 2)
                m.previewApply(provider: .grok, error: .missingGrokSession, cliDetected: false)
                return m
            },
            // Every tab populated at once: the case that decides whether four tabs fit.
            Scenario(name: "all-providers") {
                let m = model(percent: 53, weekly: 32, model: 18, burning: 2)
                let chatgpt = chatGPTFixture(session: 24, weekly: 64, additional: 31)
                m.previewApply(
                    snapshot: chatgpt.snapshot, samples: chatgpt.samples, plan: "Pro"
                )
                m.previewApply(snapshot: cursorFixture(), plan: "Pro+")
                let grok = grokFixture(percent: 100)
                m.previewApply(
                    snapshot: grok.snapshot, samples: grok.samples,
                    plan: "SuperGrok", select: true
                )
                return m
            },
        ]
    }

    @MainActor
    private static func cursorModel(
        cursorModels: Double = 62, otherModels: Double = 8, grokBot: Double = 24
    ) -> AppModel {
        let snapshot = cursorFixture(
            cursorModels: cursorModels, otherModels: otherModels, grokBot: grokBot
        )
        return AppModel.preview(
            snapshot: snapshot,
            activity: .unavailable,
            samples: [],
            plan: "Pro+",
            now: snapshot.fetchedAt
        )
    }

    @MainActor
    private static func grokModel(percent: Double) -> AppModel {
        let fixture = grokFixture(percent: percent)
        return AppModel.preview(
            snapshot: fixture.snapshot,
            activity: .unavailable,
            samples: fixture.samples,
            plan: "SuperGrok",
            now: fixture.snapshot.fetchedAt
        )
    }

    /// Mirrors the real `/rest/grok/credits` shape by going through the parser, so the
    /// screenshots cannot drift from what the app actually renders for a live account.
    private static func grokFixture(
        percent: Double
    ) -> (snapshot: UsageSnapshot, samples: [UsageSample]) {
        let now = Date()
        let periodEnd = now.addingTimeInterval(3 * 86_400 + 5 * 3_600)
        let credits = JSONValue.object([
            "config": .object([
                "creditUsagePercent": .number(percent),
                "onDemandCap": .object(["val": .string("0")]),
                "onDemandUsed": .object(["val": .string("0")]),
                "prepaidBalance": .object(["val": .string("0")]),
                "currentPeriod": .object([
                    "type": .string("USAGE_PERIOD_TYPE_WEEKLY"),
                    "start": .string(ISO8601.string(from: periodEnd.addingTimeInterval(-7 * 86_400))),
                    "end": .string(ISO8601.string(from: periodEnd)),
                ]),
                "productUsage": .array([
                    .object([
                        "product": .string("PRODUCT_GROK_TASKS"),
                        "usagePercent": .number(percent * 0.97),
                    ]),
                    .object([
                        "product": .string("PRODUCT_GROK_CHAT"),
                        "usagePercent": .number(percent * 0.02),
                    ]),
                    .object([
                        "product": .string("PRODUCT_GROK_IMAGINE"),
                        "usagePercent": .number(percent * 0.01),
                    ]),
                ]),
            ]),
        ])
        let snapshot = GrokUsageParser.parse(
            credits: credits, subscriptions: nil, now: now, keepRaw: false
        ).snapshot
        let samples = (0...24).map { index in
            let hoursAgo = Double(24 - index) / 6
            return UsageSample(
                t: now.addingTimeInterval(-hoursAgo * 3_600),
                limits: ["grok_allowance": max(0, percent - hoursAgo * 1.4)],
                provider: .grok
            )
        }
        return (snapshot, samples)
    }

    /// Mirrors the real `dashboard/*` shapes by going through the parser, for the same reason
    /// the Grok fixture does: hand-built `LimitWindow`s drift from what the app actually
    /// renders. This one used to omit `windowDuration` — which no real payload does — and so
    /// the preview never showed the "Cursor Models · cursor models included" eyebrow that a
    /// live account got.
    private static func cursorFixture(
        cursorModels: Double = 62, otherModels: Double = 8, grokBot: Double = 24
    ) -> UsageSnapshot {
        let now = Date()
        let cycleEnd = now.addingTimeInterval(12 * 86_400)
        let cycleStart = cycleEnd.addingTimeInterval(-31 * 86_400)
        let millis: (Date) -> JSONValue = {
            .string(String(Int($0.timeIntervalSince1970 * 1000)))
        }
        return CursorUsageParser.parse(
            planInfo: .object(["planInfo": .object(["planName": .string("Pro+")])]),
            currentPeriodUsage: .object([
                "billingCycleStart": millis(cycleStart),
                "billingCycleEnd": millis(cycleEnd),
                "planUsage": .object([
                    "autoPercentUsed": .number(cursorModels),
                    "apiPercentUsed": .number(otherModels),
                ]),
            ]),
            sandUsageStatus: .object([
                "usagePercent": .number(grokBot),
                "nextResetTimestampUtc": .string(
                    ISO8601.string(from: now.addingTimeInterval(4 * 86_400))
                ),
            ]),
            now: now,
            keepRaw: false
        ).snapshot
    }

    @MainActor
    private static func chatGPTModel(
        session: Double, weekly: Double, additional: Double
    ) -> AppModel {
        let fixture = chatGPTFixture(
            session: session, weekly: weekly, additional: additional
        )
        return AppModel.preview(
            snapshot: fixture.snapshot,
            activity: .unavailable,
            samples: fixture.samples,
            plan: "Pro",
            now: fixture.snapshot.fetchedAt
        )
    }

    private static func chatGPTFixture(
        session: Double, weekly: Double, additional: Double
    ) -> (snapshot: UsageSnapshot, samples: [UsageSample]) {
        let now = Date()
        let sessionReset = now.addingTimeInterval(97 * 60)
        let weeklyReset = now.addingTimeInterval(4 * 86_400 + 8 * 3_600)
        let severity: (Double) -> Severity = { Severity.from(percent: $0) }
        let limits = [
            LimitWindow(
                id: "session", kind: "primary", group: .session,
                title: "5-hour limit", shortTitle: "Session",
                percent: session, resetsAt: sessionReset, severity: severity(session),
                isActive: true, provider: .chatgpt, windowDuration: 5 * 3_600
            ),
            LimitWindow(
                id: "weekly_all", kind: "secondary", group: .weekly,
                title: "7-day limit", shortTitle: "Weekly",
                percent: weekly, resetsAt: weeklyReset, severity: severity(weekly),
                provider: .chatgpt, windowDuration: 7 * 86_400
            ),
            LimitWindow(
                id: "model|gpt-5.2-codex", kind: "model", group: .weekly,
                title: "GPT-5.2-Codex · 7-day", shortTitle: "GPT-5.2-Codex",
                percent: additional, resetsAt: weeklyReset, severity: severity(additional),
                modelName: "GPT-5.2-Codex", provider: .chatgpt,
                windowDuration: 7 * 86_400
            ),
        ]
        let snapshot = UsageSnapshot(
            fetchedAt: now,
            limits: limits,
            spend: nil,
            provider: .chatgpt,
            credits: UsageCredits(hasCredits: true, unlimited: false, balance: "18.50")
        )
        let samples = (0...24).map { index in
            let hoursAgo = Double(24 - index) / 12
            return UsageSample(
                t: now.addingTimeInterval(-hoursAgo * 3_600),
                limits: [
                    "session": max(0, session - hoursAgo * 4),
                    "weekly_all": max(0, weekly - hoursAgo * 0.5),
                    "model|gpt-5.2-codex": max(0, additional - hoursAgo * 0.7),
                ],
                provider: .chatgpt
            )
        }
        return (snapshot, samples)
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
