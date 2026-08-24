import SwiftUI
import ClaudeUsageCore

/// "Is there room to start this?" — asked before a long agent run rather than discovered
/// forty minutes into one.
///
/// The durations are fixed chips rather than a free-text field: the answer is a coarse
/// go/tight/stop, so pretending to accept "37 minutes" would imply a precision the burn-rate
/// estimate does not have.
struct RunwayCheckView: View {
    let limit: LimitWindow
    let samples: [UsageSample]
    let now: Date
    @Binding var minutes: Double

    private static let choices: [(String, Double)] = [
        ("15m", 15), ("30m", 30), ("1h", 60), ("2h", 120),
    ]

    private var verdict: RunwayVerdict {
        UsageAnalytics.verdict(for: limit, taskMinutes: minutes, samples: samples, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("CAN I START A…")
                    .font(DS.eyebrow)
                    .kerning(DS.eyebrowKerning)
                    .foregroundStyle(DS.inkFaint)
                Spacer(minLength: 8)
                ForEach(Self.choices, id: \.0) { label, value in
                    Button { minutes = value } label: {
                        Text(label)
                            .font(DS.figure(9.5, weight: minutes == value ? .bold : .regular))
                            .foregroundStyle(minutes == value ? DS.ink : DS.inkFaint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(minutes == value ? DS.dim : .clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(headline)
                    .font(DS.label(12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(verdict.detail)
                    .font(DS.label(10.5))
                    .foregroundStyle(DS.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .panelRow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(verdict.detail)")
    }

    private var headline: String {
        switch verdict.call {
        case .go: return "Go"
        case .tight: return "Tight"
        case .stop: return "Not enough"
        case .unknown: return "Can't say yet"
        }
    }

    private var tint: Color {
        switch verdict.call {
        case .go: return DS.healthy
        case .tight: return DS.tight
        case .stop: return DS.spent
        case .unknown: return DS.inkFaint
        }
    }

    private var symbol: String {
        switch verdict.call {
        case .go: return "checkmark.circle.fill"
        case .tight: return "exclamationmark.circle.fill"
        case .stop: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}
