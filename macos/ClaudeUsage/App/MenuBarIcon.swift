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
    /// renders both providers at once without digits: two upright bars where height is
    /// quantity, which is the one visual metaphor nobody has to be taught.
    enum Style: String, Sendable, Codable, CaseIterable, Identifiable {
        case twinBars, ring, tickMeter, wedge
        public var id: String { rawValue }

        var label: String {
            switch self {
            case .twinBars: return "Twin bars (both providers)"
            case .ring: return "Ring"
            case .tickMeter: return "Tick meter"
            case .wedge: return "Wedge"
            }
        }

        /// Only twin bars can express two providers; the rest show the tightest limit.
        var showsBothProviders: Bool { self == .twinBars }
    }

    struct Input {
        /// 0...1, or nil when that provider has no current data.
        var claude: Double?
        var chatgpt: Double?
        var severity: Severity = .normal
        var tint: Bool = true
        /// Claude Code needs the user — drawn as a notch, never as a fill level.
        var attention: Bool = false

        var worst: Double? {
            [claude, chatgpt].compactMap { $0 }.max()
        }
    }

    static func image(style: Style, _ input: Input) -> NSImage {
        let useColor = input.tint && input.severity != .normal
        let ink: NSColor = useColor
            ? (input.severity == .critical ? .systemRed : .systemOrange)
            // Template images are recoloured by AppKit; the drawn colour only needs to be
            // opaque black so the alpha mask comes out right.
            : .black

        let width = self.width(for: style, attention: input.attention)
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { rect in
            switch style {
            case .twinBars: drawTwinBars(rect, input, ink)
            case .ring: drawRing(rect, input.worst, ink)
            case .tickMeter: drawTicks(rect, input.worst, ink)
            case .wedge: drawWedge(rect, input.worst, ink)
            }
            if input.attention { drawAttention(rect, ink) }
            return true
        }

        image.isTemplate = !useColor
        image.accessibilityDescription = describe(input)
        return image
    }

    private static func width(for style: Style, attention: Bool) -> CGFloat {
        let base: CGFloat
        switch style {
        case .twinBars: base = 14
        case .ring: base = 16
        case .tickMeter: base = 20
        case .wedge: base = 14
        }
        return attention ? base + 6 : base
    }

    // MARK: Styles

    /// Left bar Claude, right bar ChatGPT. Both slots are always drawn, so position keeps its
    /// meaning even when one provider has no data — an absent provider is an empty track
    /// rather than a missing bar that would shift the other one.
    private static func drawTwinBars(_ rect: NSRect, _ input: Input, _ ink: NSColor) {
        let w: CGFloat = 5, gap: CGFloat = 4, h = rect.height - 3
        for (i, value) in [input.claude, input.chatgpt].enumerated() {
            let x = CGFloat(i) * (w + gap) + 0.5
            let track = NSBezierPath(
                roundedRect: NSRect(x: x, y: 2, width: w, height: h), xRadius: 2, yRadius: 2
            )
            ink.withAlphaComponent(0.30).setFill()
            track.fill()

            guard let value else { continue }
            let fh = max(2.5, h * min(max(value, 0), 1))
            let fill = NSBezierPath(
                roundedRect: NSRect(x: x, y: 2, width: w, height: fh), xRadius: 2, yRadius: 2
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
        if let c = input.claude { parts.append("Claude \(Int((c * 100).rounded())) percent") }
        if let g = input.chatgpt { parts.append("ChatGPT \(Int((g * 100).rounded())) percent") }
        if parts.isEmpty { return "Usage unknown" }
        if input.attention { parts.append("Claude Code needs attention") }
        return parts.joined(separator: ", ")
    }

    /// Shown when there is no data at all — empty tracks, no alarm.
    static func unknown(style: Style) -> NSImage {
        image(style: style, Input(claude: nil, chatgpt: nil, tint: false))
    }
}
