import SwiftUI
import ClaudeUsageCore

/// A thin history band at the foot of the panel. It answers one question — "was I climbing or
/// flat?" — so it gets one band and no chrome. The old version had its own heading, its own
/// min/max labels and its own padding, which made a footnote look like a section.
struct SparklineSection: View {
    let samples: [UsageSample]
    let limitID: String?
    let severity: Severity
    @Binding var range: SparklineRange
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("TREND")
                    .font(DS.eyebrow)
                    .kerning(DS.eyebrowKerning)
                    .foregroundStyle(DS.inkFaint)
                Text("% left")
                    .font(DS.label(9.5))
                    .foregroundStyle(DS.inkFaint)
                Spacer(minLength: 8)
                // Plain text toggles rather than a segmented control: the control's own
                // chrome was heavier than the chart it filtered.
                ForEach(SparklineRange.allCases) { option in
                    Button {
                        range = option
                    } label: {
                        Text(option.rawValue)
                            .font(DS.figure(9.5, weight: option == range ? .bold : .regular))
                            .foregroundStyle(option == range ? DS.ink : DS.inkFaint)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(option == range ? DS.dim : .clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .panelRow()

            if points.count >= 2 {
                Sparkline(points: points, severity: severity)
                    .frame(height: 28)
                    .panelRow()
            } else {
                Text("Collecting samples")
                    .font(DS.label(10))
                    .foregroundStyle(DS.inkFaint)
                    .frame(height: 28, alignment: .leading)
                    .panelRow()
            }
        }
    }

    private var points: [(Date, Double)] {
        guard let limitID else { return [] }
        let cutoff = now.addingTimeInterval(-range.duration)
        // `samples` is already chronological, so this is a single linear pass — no sort on a
        // view that redraws every second.
        return samples.compactMap { s in
            guard s.t >= cutoff, let value = s.limits[limitID] else { return nil }
            // Plotted as headroom, like every other figure in the panel: the line falls as
            // you spend and jumps back up at a reset. Samples are stored as utilisation, so
            // the flip happens here rather than in history.
            return (s.t, max(0, 100 - value))
        }
    }
}

private struct Sparkline: View {
    let points: [(Date, Double)]
    let severity: Severity

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2 else { return }

            let times = points.map(\.0.timeIntervalSince1970)
            let values = points.map(\.1)
            let tMin = times.min()!, tMax = times.max()!
            let vMin = values.min()!, vMax = values.max()!
            // A flat series would divide by zero; a 1-point band keeps the line centred
            // rather than pinned to an edge.
            let tSpan = max(tMax - tMin, 1)
            let vSpan = max(vMax - vMin, 1)

            func point(_ i: Int) -> CGPoint {
                let x = CGFloat((times[i] - tMin) / tSpan) * size.width
                let normalized = CGFloat((values[i] - vMin) / vSpan)
                let y = size.height - normalized * (size.height - 4) - 2
                return CGPoint(x: x, y: y)
            }

            var line = Path()
            line.move(to: point(0))
            for i in 1..<points.count { line.addLine(to: point(i)) }

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()

            let color = DS.accent(severity)
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.24), color.opacity(0.01)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(color), lineWidth: 1.4)

            // Mark the latest reading so the eye lands on "now".
            let last = point(points.count - 1)
            context.fill(
                Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)),
                with: .color(color)
            )
        }
        .accessibilityLabel("Remaining allowance trend, \(points.count) samples")
    }
}
