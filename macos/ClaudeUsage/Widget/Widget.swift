import WidgetKit
import SwiftUI
import ClaudeUsageCore

/// Notification Centre widget.
///
/// Reads the same `~/.claude-usage-tracker/last-usage*.json` the app writes, rather than
/// talking to the API itself: the widget must not hold a credential, must not add a second
/// poller against a rate-limited endpoint, and has no business fetching on a timeline the user
/// cannot see.
///
/// It therefore shows whatever the app last saw, and says how old that is instead of implying
/// it is live.
struct UsageEntry: TimelineEntry {
    let date: Date
    let limits: [LimitWindow]
    let lastUpdated: Date?

    var tightest: LimitWindow? { limits.max { $0.percent < $1.percent } }
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, limits: [], lastUpdated: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // The app refreshes on its own schedule; re-reading every 5 minutes is enough to keep
        // the widget close without waking anything up.
        completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(300))))
    }

    private func load() -> UsageEntry {
        var limits: [LimitWindow] = []
        var newest: Date?
        for file in ["last-usage.json", "last-usage-chatgpt.json"] {
            let url = AppPaths.root.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder.store.decode(UsageSnapshot.self, from: data)
            else { continue }
            limits += snapshot.limits
            if newest == nil || snapshot.fetchedAt > newest! { newest = snapshot.fetchedAt }
        }
        return UsageEntry(
            date: .now,
            limits: limits.sorted { $0.percent > $1.percent },
            lastUpdated: newest
        )
    }
}

struct UsageWidgetView: View {
    var entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("Usage").font(.system(size: 12, weight: .semibold))
                // The unit, stated once. Every figure below is headroom, matching the panel
                // and the menu bar — and matching what this widget's own description has
                // always claimed it showed.
                Text("% left")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                if let updated = entry.lastUpdated {
                    Text(updated, style: .relative)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            if entry.limits.isEmpty {
                Text("Open Claude Usage to sync")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.rowKey) { limit in
                    HStack(spacing: 6) {
                        Text(limit.provider.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(limit.shortTitle)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(Int(limit.remainingPercent.rounded()))%")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                    }
                    // Drains as the allowance is spent, like the bar next to the number
                    // rather than against it.
                    ProgressView(value: min(limit.remainingPercent / 100, 1))
                        .progressViewStyle(.linear)
                        .tint(tint(limit.severity))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var rows: [LimitWindow] {
        Array(entry.limits.prefix(family == .systemSmall ? 2 : 4))
    }

    private func tint(_ severity: Severity) -> Color {
        switch severity {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

struct ClaudeUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.krushal.claude-usage-tracker.widget",
                            provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        // Named for what it tracks now. "Claude & ChatGPT" stopped being the whole list once
        // Cursor and Grok became tabs, and a widget that omits two of them from its own name
        // reads as though it cannot show them.
        .configurationDisplayName("AI Usage")
        .description("How much of each plan's allowance is left, as last seen by the menu bar app.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ClaudeUsageWidgetBundle: WidgetBundle {
    var body: some Widget { ClaudeUsageWidget() }
}
