import AppKit
import ClaudeUsageCore

/// Draws the menu-bar glyph.
///
/// The icon is generated, not shipped as a bitmap: `NSImage(size:flipped:drawingHandler:)`
/// re-runs the handler for every backing scale factor, so the result is crisp on Retina and
/// non-Retina displays alike with no `@2x` assets to keep in sync.
///
/// At normal severity the image is a **template**, which is what makes it correct in light and
/// dark menu bars automatically — AppKit tints it. Alpha survives that tinting, so the
/// unfilled part of the ring is drawn at low alpha and still reads as "empty".
enum MenuBarIcon {
    /// 16 pt is the conventional menu-bar glyph size on macOS.
    static let size = NSSize(width: 16, height: 16)

    /// - Parameters:
    ///   - fraction: 0...1 of the ring to fill. Values above 1 are clamped.
    ///   - severity: drives tinting, only when `tint` is true.
    ///   - tint: when false the icon is always a monochrome template.
    ///   - attention: draws a small notch dot for "Claude Code needs you".
    static func image(
        fraction: Double?,
        severity: Severity,
        tint: Bool,
        attention: Bool
    ) -> NSImage {
        let clamped = min(max(fraction ?? 0, 0), 1)
        let useColor = tint && severity != .normal

        let image = NSImage(size: size, flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let lineWidth: CGFloat = 2
            let radius = min(rect.width, rect.height) / 2 - lineWidth / 2 - 1.5

            let strokeColor: NSColor = useColor
                ? (severity == .critical ? .systemRed : .systemOrange)
                // Template images are recolored by AppKit; the drawn color only needs to be
                // opaque black so the alpha mask comes out right.
                : .black

            // Track.
            let track = NSBezierPath()
            track.appendArc(
                withCenter: center, radius: radius, startAngle: 0, endAngle: 360
            )
            track.lineWidth = lineWidth
            strokeColor.withAlphaComponent(useColor ? 0.25 : 0.3).setStroke()
            track.stroke()

            // Filled arc, clockwise from 12 o'clock.
            if clamped > 0.001 {
                let start: CGFloat = 90
                let end = start - CGFloat(clamped) * 360
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: center, radius: radius,
                    startAngle: start, endAngle: end, clockwise: true
                )
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                strokeColor.setStroke()
                arc.stroke()
            }

            // Attention notch: a filled dot in the middle, distinct from any fill level.
            if attention {
                let dot = NSBezierPath(
                    ovalIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)
                )
                strokeColor.setFill()
                dot.fill()
            }

            return true
        }

        image.isTemplate = !useColor
        // Accessibility label; VoiceOver reads this for the status item.
        image.accessibilityDescription = fraction
            .map { "Claude usage \(Int(($0 * 100).rounded())) percent" }
            ?? "Claude usage unknown"
        return image
    }

    /// Shown when there is no data at all — a plain ring, no fill, no alarm.
    static var unknown: NSImage {
        image(fraction: nil, severity: .normal, tint: false, attention: false)
    }
}
