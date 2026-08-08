import SwiftUI
import AppKit
import ClaudeUsageCore

/// The panel's visual language.
///
/// Three rules:
///
/// 1. **Monochrome base, one accent.** The previous pass tinted the whole panel with the
///    severity colour, which made a perfectly healthy account look like a pastel warning.
///    Colour now appears in exactly two places — the hero figure and its meter — so when it
///    does appear it means something.
/// 2. **Real depth or none.** A 6% fill that barely separates from its parent reads as
///    unfinished. The hero sits on a genuine surface: scrim, inner stroke, and a shadow.
/// 3. **Never `.secondary`/`.tertiary` for meaning.** They collapse to mud on a translucent
///    dark backdrop. Every token here is an explicit per-appearance value.
enum DS {
    static let panelWidth: CGFloat = 380
    static let hInset: CGFloat = 16

    /// Strict 4pt rhythm. Everything vertical snaps to these.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
    }

    // MARK: Surfaces

    /// Deepens the system material so the panel reads as one considered surface instead of a
    /// washed-out blur. Kept partial — killing the translucency entirely is what makes a Mac
    /// app look like a web page in a box.
    static let scrim = dynamicAlpha(light: (0xFFFFFF, 0.46), dark: (0x0B0B0E, 0.40))
    /// The hero card.
    static let surface = dynamicAlpha(light: (0xFFFFFF, 0.78), dark: (0xFFFFFF, 0.055))
    static let surfaceStroke = dynamicAlpha(light: (0x000000, 0.07), dark: (0xFFFFFF, 0.10))
    static let hairline = dynamicAlpha(light: (0x000000, 0.07), dark: (0xFFFFFF, 0.075))

    // MARK: Ink

    static let ink = dynamic(light: 0x111114, dark: 0xF4F4F7)
    static let inkMuted = dynamic(light: 0x5A5A63, dark: 0x9A9AA4)
    static let inkFaint = dynamic(light: 0x8E8E98, dark: 0x65656E)

    /// Unlit tick / empty track.
    static let dim = dynamicAlpha(light: (0x000000, 0.13), dark: (0xFFFFFF, 0.15))

    // MARK: Accent
    //
    // Bespoke and slightly desaturated. `.systemGreen`/`.systemRed` are mixed for opaque
    // surfaces and go garish over a blur.

    static let healthy = dynamic(light: 0x1E9E58, dark: 0x5BD98A)
    static let tight = dynamic(light: 0xB87400, dark: 0xFFB84D)
    static let spent = dynamic(light: 0xC4342E, dark: 0xFF7A70)

    static func accent(_ severity: Severity) -> Color {
        switch severity {
        case .normal: return healthy
        case .warning: return tight
        case .critical: return spent
        }
    }

    // MARK: Type
    //
    // SF Pro Display with negative tracking for figures. Rounded reads friendly — Fitness,
    // Reminders — where this wants to read precise. Mono only for values that change in
    // place, so nothing twitches on refresh.

    static func hero(_ size: CGFloat = 46) -> Font {
        .system(size: size, weight: .semibold)
    }

    static func figure(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func label(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Section marker. Carries the window length ("5-HOUR", "7-DAY"), so it is information.
    static let eyebrow = Font.system(size: 9, weight: .semibold)
    static let eyebrowKerning: CGFloat = 0.8

    // MARK: Dynamic colour helpers

    static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(hex: dark) : NSColor(hex: light) })
    }

    static func dynamicAlpha(light: (Int, Double), dark: (Int, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let spec = appearance.isDark ? dark : light
            return NSColor(hex: spec.0).withAlphaComponent(spec.1)
        })
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Tick meter

/// The panel's signature. Discrete ticks rather than a capsule bar — the language of light
/// meters and studio gear. It is countable at a glance, it degrades honestly (an unknown
/// value shows an unlit scale rather than an empty bar that looks like zero), and it can
/// carry a breakpoint, which a solid bar cannot.
struct TickMeter: View {
    /// 0...1 of the scale that is lit.
    let fraction: Double
    let color: Color
    /// Optional 0...1 position of a marker — used for "you run dry here".
    var breakpoint: Double?
    var tickCount: Int = 30
    var height: CGFloat = 12
    var tickWidth: CGFloat = 2
    /// Unlit ticks past the breakpoint render hollow to read as "nothing here".
    var dimPastBreakpoint: Bool = false

    var body: some View {
        GeometryReader { geo in
            let spacing = max(1, (geo.size.width - CGFloat(tickCount) * tickWidth)
                                 / CGFloat(max(1, tickCount - 1)))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<tickCount, id: \.self) { i in
                    let position = Double(i) / Double(max(1, tickCount - 1))
                    Capsule()
                        .fill(tint(at: position, index: i))
                        .frame(width: tickWidth, height: tickHeight(at: position))
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .leading)
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: fraction)
        .accessibilityHidden(true)
    }

    private func tint(at position: Double, index: Int) -> Color {
        // Always light at least the first tick, so a non-zero value is never invisible.
        let lit = fraction > 0 && (position <= fraction || index == 0)
        if lit { return color }
        if let breakpoint, dimPastBreakpoint, position > breakpoint {
            return DS.spent.opacity(0.28)
        }
        return DS.dim
    }

    /// The breakpoint tick stands proud of the scale.
    private func tickHeight(at position: Double) -> CGFloat {
        guard let breakpoint else { return height }
        let step = 1.0 / Double(max(1, tickCount - 1))
        return abs(position - breakpoint) < step * 0.5 ? height : height * 0.72
    }
}

// MARK: - Shared components

struct Eyebrow: View {
    let text: String
    var detail: String?
    var accent: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(text.uppercased())
                .font(DS.eyebrow)
                .kerning(DS.eyebrowKerning)
                .foregroundStyle(accent ?? DS.inkFaint)
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(DS.label(10, weight: .medium))
                    .foregroundStyle(DS.inkFaint)
            }
        }
    }
}

/// A 5pt status dot. Replaces the old full-bleed severity rail — same information, a
/// hundredth of the visual weight.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .overlay(Circle().strokeBorder(color.opacity(0.28), lineWidth: 3).blur(radius: 1))
    }
}

struct Chip: View {
    let text: String
    var color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.13), in: Capsule())
    }
}

/// Icon-only with a tooltip. Text labels were truncating to "Refr…", "Das…", "Sett…".
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? DS.dim : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? DS.inkMuted)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

extension View {
    func panelRow() -> some View { padding(.horizontal, DS.hInset) }
}

/// Full-bleed hairline between sections.
struct SectionRule: View {
    var body: some View {
        Rectangle().fill(DS.hairline).frame(height: 1)
    }
}
