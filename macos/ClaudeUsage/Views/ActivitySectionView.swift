import SwiftUI
import ClaudeUsageCore

/// What Claude Code is doing. Renders a one-line explanation when the hook isn't installed —
/// an empty "Idle" would be a lie.
struct ActivitySectionView: View {
    let activity: ActivityState
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Eyebrow(text: "Claude Code", detail: summary).panelRow()

            if !activity.hookInstalled {
                Text("Not tracking — run macos/scripts/install-hooks.sh")
                    .font(DS.label(10))
                    .foregroundStyle(DS.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .panelRow()
            } else if activity.sessions.isEmpty {
                Text("No sessions running")
                    .font(DS.label(11))
                    .foregroundStyle(DS.inkMuted)
                    .panelRow()
            } else {
                ForEach(activity.sessions.prefix(4)) { session in
                    SessionRow(session: session, now: now).panelRow()
                }
                if activity.sessions.count > 4 {
                    Text("+\(activity.sessions.count - 4) more")
                        .font(DS.label(10))
                        .foregroundStyle(DS.inkFaint)
                        .panelRow()
                }
            }
        }
    }

    private var summary: String? {
        guard activity.hookInstalled, !activity.sessions.isEmpty else { return nil }
        var parts = ["\(activity.sessions.count) session\(activity.sessions.count == 1 ? "" : "s")"]
        if activity.totalAgents > 0 { parts.append("\(activity.totalAgents) agents") }
        return parts.joined(separator: " · ")
    }
}

private struct SessionRow: View {
    let session: ActivitySession
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.status.symbolName)
                .font(.system(size: 9.5, weight: .medium))
                .frame(width: 13)
                .foregroundStyle(iconColor)

            Text(session.displayName)
                .font(DS.label(11.5, weight: .medium))
                .foregroundStyle(DS.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Text(detail)
                .font(DS.label(10))
                .foregroundStyle(session.needsAttention ? DS.tight : DS.inkMuted)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let elapsed = timing {
                Text(elapsed)
                    .font(DS.figure(9.5))
                    .foregroundStyle(DS.inkFaint)
            }
        }
    }

    private var iconColor: Color {
        if session.needsAttention { return DS.tight }
        if session.status == .error || session.status == .rateLimited { return DS.spent }
        if session.status.isBusy { return DS.healthy }
        return DS.inkFaint
    }

    private var detail: String {
        if session.needsAttention, let reason = session.attentionReason { return reason }
        var text = session.status.displayName.lowercased()
        if let sub = session.statusDetail, !sub.isEmpty { text += " · \(sub)" }
        if session.activeAgents > 0 {
            text += " · \(session.activeAgents) agent\(session.activeAgents == 1 ? "" : "s")"
        }
        return text
    }

    private var timing: String? {
        if let running = session.turnDuration(now: now) { return Format.duration(running) }
        if session.status == .completed, let done = session.lastCompletedAt {
            return Format.relativeAge(now.timeIntervalSince(done))
        }
        if let updated = session.updatedAt {
            return Format.relativeAge(now.timeIntervalSince(updated))
        }
        return nil
    }
}
