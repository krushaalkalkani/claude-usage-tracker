import SwiftUI
import ClaudeUsageCore

/// Which projects spent this window's quota.
///
/// The share bars are deliberately plain and the caveat line is always present when the split
/// involved guesswork — the numbers are inferred from overlapping timing, not measured, and a
/// breakdown that looked authoritative would invite more trust than it has earned.
struct AttributionView: View {
    let breakdown: UsageAttribution.Breakdown
    let limitTitle: String

    private var rows: [UsageAttribution.Share] { Array(breakdown.shares.prefix(4)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Eyebrow(
                text: "Where it went",
                detail: "\(Int(breakdown.total.rounded()))% this window"
            )
            .panelRow()

            if breakdown.isEmpty {
                Text("No measurable usage in this window yet")
                    .font(DS.label(10.5))
                    .foregroundStyle(DS.inkFaint)
                    .panelRow()
            } else {
                ForEach(rows) { share in
                    row(name: share.project, points: share.points, tint: DS.ink)
                }
                if breakdown.unattributed > 0.5 {
                    row(
                        name: "Outside Claude Code",
                        points: breakdown.unattributed,
                        tint: DS.inkFaint
                    )
                }
                if breakdown.isApproximate {
                    Text("Split evenly where projects overlapped — approximate")
                        .font(DS.label(9.5))
                        .foregroundStyle(DS.inkFaint)
                        .panelRow()
                }
            }
        }
    }

    private func row(name: String, points: Double, tint: Color) -> some View {
        let fraction = breakdown.total > 0 ? points / breakdown.total : 0
        return HStack(spacing: DS.Space.s) {
            Text(name)
                .font(DS.label(11.5, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: DS.Space.s)

            TickMeter(
                fraction: fraction, color: tint == DS.ink ? DS.healthy : DS.dim,
                tickCount: 14, height: 8, tickWidth: 1.5
            )
            .frame(width: 68)

            Text("\(points, specifier: "%.1f")%")
                .font(DS.figure(10.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 42, alignment: .trailing)
        }
        .panelRow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(String(format: "%.1f", points)) percent of \(limitTitle)")
    }
}
