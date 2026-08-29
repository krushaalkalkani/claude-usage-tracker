import AppKit
import ClaudeUsageCore

/// Draws the menu-bar glyph.
///
/// Generated rather than shipped as a bitmap: `NSImage(size:flipped:drawingHandler:)` re-runs
/// the handler for every backing scale factor, so it is crisp on Retina and non-Retina alike
/// with no `@2x` assets to keep in sync.
///
/// At normal severity the image is a **template**, which is what makes it correct in light and
/// dark menu bars automatically — AppKit tints it. Alpha survives that tinting, so unfilled
/// parts are drawn at low alpha and still read as "empty".
enum MenuBarIcon {

    /// What the glyph shows. `twinBars` is the default because it is the only style that
    /// renders every connected provider at once without digits: upright bars where height is
    /// quantity, which is the one visual metaphor nobody has to be taught.
    ///
    /// Every style draws **what is left**, so the glyph drains as you spend, exactly like a
    /// battery and exactly like the number beside it. It used to fill as you spent, which put
    /// a full bar next to "45%" and made a nearly-exhausted account look like a healthy one.
    enum Style: String, Sendable, Codable, CaseIterable, Identifiable {
        case twinBars, ring, tickMeter, wedge
        public var id: String { rawValue }

        var label: String {
            switch self {
            case .twinBars: return "Bars (every provider)"
            case .ring: return "Ring"
            case .tickMeter: return "Tick meter"
            case .wedge: return "Wedge"
            }
        }

        /// Only the bars can express more than one provider; the rest show the binding limit.
        var showsBothProviders: Bool { self == .twinBars }
    }

    struct Input {
        /// One slot per provider the user has actually connected, in a stable order, so a
        /// bar keeps its meaning between refreshes. The value is 0...1 of the allowance
        /// **still available**, or nil when that provider currently has no usable data.
        ///
        /// This was two fixed fields, `claude` and `chatgpt`, which meant a tracked Cursor or
        /// Grok subscription had no way to appear in the menu bar at all.
        var levels: [Double?] = []
        var severity: Severity = .normal
        var tint: Bool = true
        /// Claude Code needs the user — drawn as a notch, never as a fill level.
        var attention: Bool = false
        /// Names for the accessibility description, parallel to `levels`.
        var labels: [String] = []

        /// The least headroom anyone reported — what the single-value styles draw.
        var lowest: Double? { levels.compactMap { $0 }.min() }
    }

    static func image(style: Style, _ input: Input) -> NSImage {
        let useColor = input.tint && input.severity != .normal
        let ink: NSColor = useColor
            ? (input.severity == .critical ? .systemRed : .systemOrange)
            // Template images are recoloured by AppKit; the drawn colour only needs to be
            // opaque black so the alpha mask comes out right.
            : .black

        let width = self.width(for: style, attention: input.attention, slots: input.levels.count)
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { rect in
            switch style {
            case .twinBars: drawBars(rect, input, ink)
            case .ring: drawRing(rect, input.lowest, ink)
            case .tickMeter: drawTicks(rect, input.lowest, ink)
            case .wedge: drawWedge(rect, input.lowest, ink)
            }
            if input.attention { drawAttention(rect, ink) }
            return true
        }

        image.isTemplate = !useColor
        image.accessibilityDescription = describe(input)
        return image
    }

    /// Bar geometry, shared by the width calculation and the drawing so they cannot drift.
    private static let barWidth: CGFloat = 4
    private static let barGap: CGFloat = 3

    private static func width(for style: Style, attention: Bool, slots: Int) -> CGFloat {
        let base: CGFloat
        switch style {
        case .twinBars:
            let n = CGFloat(max(1, slots))
            base = n * barWidth + (n - 1) * barGap + 1
        case .ring: base = 16
        case .tickMeter: base = 20
        case .wedge: base = 14
        }
        return attention ? base + 6 : base
    }

    // MARK: Styles

    /// One bar per connected provider, in a fixed order, so a bar's position keeps its
    /// meaning between refreshes. A provider with no usable data right now is an empty track
    /// rather than a missing bar that would shift its neighbours along.
    ///
    /// Height is what is **left**: a full bar means plenty of headroom and the bar drains as
    /// the allowance is spent.
    private static func drawBars(_ rect: NSRect, _ input: Input, _ ink: NSColor) {
        let h = rect.height - 3
        let slots = input.levels.isEmpty ? [nil] : input.levels
        for (i, value) in slots.enumerated() {
            let x = CGFloat(i) * (barWidth + barGap) + 0.5
            let track = NSBezierPath(
                roundedRect: NSRect(x: x, y: 2, width: barWidth, height: h),
                xRadius: 1.6, yRadius: 1.6
            )
            ink.withAlphaComponent(0.30).setFill()
            track.fill()

            guard let value else { continue }
            // A provider that is genuinely empty draws nothing rather than a 2.5pt stub that
            // would read as "a little left".
            let level = min(max(value, 0), 1)
            guard level > 0.001 else { continue }
            let fh = max(2, h * level)
            let fill = NSBezierPath(
                roundedRect: NSRect(x: x, y: 2, width: barWidth, height: fh),
                xRadius: 1.6, yRadius: 1.6
            )
            ink.setFill()
            fill.fill()
        }
    }

    private static func drawRing(_ rect: NSRect, _ value: Double?, _ ink: NSColor) {
        let c = CGPoint(x: 8, y: rect.midY), r: CGFloat = 6
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
        track.lineWidth = 2
        ink.withAlphaComponent(0.28).setStroke()
        track.stroke()

        guard let value, value > 0.001 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: r, startAngle: 90,
                      endAngle: 90 - CGFloat(min(value, 1)) * 360, clockwise: true)
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        ink.setStroke()
        arc.stroke()
    }

    private static func drawTicks(_ rect: NSRect, _ value: Double?, _ ink: NSColor) {
        let n = 7, tw: CGFloat = 1.8
        let span: CGFloat = 20
        let gap = (span - CGFloat(n) * tw) / CGFloat(n - 1)
        for i in 0..<n {
            let position = Double(i) / Double(n - 1)
            let lit = (value ?? -1) >= position
            let x = CGFloat(i) * (tw + gap)
            let h: CGFloat = lit ? 11 : 8
            let p = NSBezierPath(
                roundedRect: NSRect(x: x, y: rect.midY - h / 2, width: tw, height: h),
                xRadius: 0.9, yRadius: 0.9
            )
            ink.withAlphaComponent(lit ? 1 : 0.24).setFill()
            p.fill()
        }
    }

    private static func drawWedge(_ rect: NSRect, _ value: Double?, _ ink: NSColor) {
        let c = CGPoint(x: 7, y: rect.midY), r: CGFloat = 6
        let ring = NSBezierPath()
        ring.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
        ring.lineWidth = 1.4
        ink.withAlphaComponent(0.35).setStroke()
        ring.stroke()

        guard let value, value > 0.001 else { return }
        let pie = NSBezierPath()
        pie.move(to: c)
        pie.appendArc(withCenter: c, radius: r - 1.4, startAngle: 90,
                      endAngle: 90 - CGFloat(min(value, 1)) * 360, clockwise: true)
        pie.close()
        ink.setFill()
        pie.fill()
    }

    /// A separate dot at the trailing edge — never mixed into the fill, so "needs you" can
    /// never be misread as "more quota used".
    private static func drawAttention(_ rect: NSRect, _ ink: NSColor) {
        let d: CGFloat = 4
        let dot = NSBezierPath(
            ovalIn: CGRect(x: rect.maxX - d - 0.5, y: rect.maxY - d - 1, width: d, height: d)
        )
        ink.setFill()
        dot.fill()
    }

    private static func describe(_ input: Input) -> String {
        var parts: [String] = []
        for (i, value) in input.levels.enumerated() {
            guard let value else { continue }
            let name = i < input.labels.count ? input.labels[i] : "Provider \(i + 1)"
            parts.append("\(name) \(Int((value * 100).rounded())) percent left")
        }
        if parts.isEmpty { return "Usage unknown" }
        if input.attention { parts.append("Claude Code needs attention") }
        return parts.joined(separator: ", ")
    }

    /// Shown when there is no data at all — empty tracks, no alarm.
    static func unknown(style: Style) -> NSImage {
        image(style: style, Input(levels: [nil], tint: false))
    }
}
