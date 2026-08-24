import AppKit
import ClaudeUsageCore

/// Draws candidate menu-bar treatments side by side so a design choice can be made from real
/// pixels at real size rather than from a description.
///
/// `ClaudeUsage --render-menubar <dir>` writes one comparison sheet. Nothing here is wired
/// into the running app; it exists purely to make the options reviewable.
enum MenuBarVariants {

    struct Variant {
        let name: String
        let note: String
        /// Draws into a 16pt-tall box and returns the width consumed.
        let draw: (_ claude: Double, _ chatgpt: Double, _ color: NSColor) -> NSImage
    }

    // MARK: Individual treatments

    /// Two upright bars, Claude then ChatGPT. Both providers, no digits.
    static func twinBars(_ a: Double, _ b: Double, _ color: NSColor) -> NSImage {
        image(width: 14) { rect in
            let w: CGFloat = 5, gap: CGFloat = 4, h = rect.height - 3
            for (i, v) in [a, b].enumerated() {
                let x = CGFloat(i) * (w + gap) + 1
                let base = NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: w, height: h),
                                        xRadius: 2, yRadius: 2)
                color.withAlphaComponent(0.30).setFill(); base.fill()
                let fh = max(2.5, h * min(v, 1))
                let fill = NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: w, height: fh),
                                        xRadius: 2, yRadius: 2)
                color.setFill(); fill.fill()
            }
        }
    }

    /// Concentric arcs — Claude outside, ChatGPT inside.
    static func dualRing(_ a: Double, _ b: Double, _ color: NSColor) -> NSImage {
        image(width: 16) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            for (r, v, lw) in [(6.0, a, 2.0), (3.2, b, 1.8)] {
                let track = NSBezierPath()
                track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
                track.lineWidth = lw
                color.withAlphaComponent(0.22).setStroke(); track.stroke()
                guard v > 0.001 else { continue }
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: r, startAngle: 90,
                              endAngle: 90 - CGFloat(min(v, 1)) * 360, clockwise: true)
                arc.lineWidth = lw
                arc.lineCapStyle = .round
                color.setStroke(); arc.stroke()
            }
        }
    }

    /// A single capsule split in two — left half Claude, right half ChatGPT.
    static func splitPill(_ a: Double, _ b: Double, _ color: NSColor) -> NSImage {
        image(width: 34) { rect in
            let h: CGFloat = 7, y = rect.midY - h / 2, half = (rect.width - 4) / 2
            for (i, v) in [a, b].enumerated() {
                let x = CGFloat(i) * (half + 4)
                let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: half, height: h),
                                         xRadius: h / 2, yRadius: h / 2)
                color.withAlphaComponent(0.20).setFill(); track.fill()
                let fw = max(h, half * min(v, 1))
                let fill = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: fw, height: h),
                                        xRadius: h / 2, yRadius: h / 2)
                color.setFill(); fill.fill()
            }
        }
    }

    /// Battery-style: one horizontal cell that drains. Shows the tightest limit only.
    static func gauge(_ a: Double, _ b: Double, _ color: NSColor) -> NSImage {
        image(width: 24) { rect in
            let worst = max(a, b)
            let h: CGFloat = 10, y = rect.midY - h / 2, w = rect.width - 4
            let body = NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: w, height: h),
                                    xRadius: 3, yRadius: 3)
            body.lineWidth = 1.2
            color.withAlphaComponent(0.5).setStroke(); body.stroke()
            let cap = NSBezierPath(roundedRect: NSRect(x: w + 1, y: y + 3, width: 2, height: h - 6),
                                   xRadius: 1, yRadius: 1)
            color.withAlphaComponent(0.5).setFill(); cap.fill()
            let inner = w - 4
            let fill = NSBezierPath(roundedRect: NSRect(x: 2, y: y + 2,
                                                       width: max(2, inner * min(worst, 1)),
                                                       height: h - 4),
                                    xRadius: 1.5, yRadius: 1.5)
            color.setFill(); fill.fill()
        }
    }

    /// Discrete ticks — the panel's own language, shrunk to menu-bar size.
    static func ticks(_ a: Double, _ b: Double, _ color: NSColor) -> NSImage {
        image(width: 20) { rect in
            let worst = max(a, b)
            let n = 7
            let tw: CGFloat = 1.8, gap = (rect.width - CGFloat(n) * tw) / CGFloat(n - 1)
            for i in 0..<n {
                let lit = Double(i) / Double(n - 1) <= worst
                let x = CGFloat(i) * (tw + gap)
                let h: CGFloat = lit ? 11 : 8
                let p = NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - h / 2,
                                                        width: tw, height: h),
                                     xRadius: 0.9, yRadius: 0.9)
                color.withAlphaComponent(lit ? 1 : 0.24).setFill(); p.fill()
            }
        }
    }

    /// A wedge that fills like a pie. Smallest footprint of the lot.
    static func wedge(_ a: Double, _ b: Double, _ color: NSColor) -> NSImage {
        image(width: 14) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY), r: CGFloat = 6
            let worst = max(a, b)
            let ring = NSBezierPath()
            ring.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            ring.lineWidth = 1.4
            color.withAlphaComponent(0.35).setStroke(); ring.stroke()
            guard worst > 0.001 else { return }
            let pie = NSBezierPath()
            pie.move(to: c)
            pie.appendArc(withCenter: c, radius: r - 1.4, startAngle: 90,
                          endAngle: 90 - CGFloat(min(worst, 1)) * 360, clockwise: true)
            pie.close()
            color.setFill(); pie.fill()
        }
    }

    /// Today's design, for reference: ring plus a percentage.
    static func ringAndNumber(_ a: Double, _ b: Double, _ color: NSColor) -> NSImage {
        let ring = wedgeRing(max(a, b), color)
        let text = "\(Int((max(a, b) * 100).rounded()))%"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        return image(width: 16 + 3 + size.width) { rect in
            ring.draw(in: NSRect(x: 0, y: 0, width: 16, height: rect.height))
            (text as NSString).draw(
                at: NSPoint(x: 19, y: rect.midY - size.height / 2 + 0.5), withAttributes: attrs
            )
        }
    }

    private static func wedgeRing(_ v: Double, _ color: NSColor) -> NSImage {
        image(width: 16) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY), r: CGFloat = 6
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = 2
            color.withAlphaComponent(0.28).setStroke(); track.stroke()
            guard v > 0.001 else { return }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: r, startAngle: 90,
                          endAngle: 90 - CGFloat(min(v, 1)) * 360, clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            color.setStroke(); arc.stroke()
        }
    }

    @MainActor static let all: [Variant] = [
        Variant(name: "A · Ring + number", note: "today's design", draw: ringAndNumber),
        Variant(name: "B · Twin bars", note: "both providers, no digits", draw: twinBars),
        Variant(name: "C · Dual ring", note: "Claude outer, ChatGPT inner", draw: dualRing),
        Variant(name: "D · Split pill", note: "two capsules side by side", draw: splitPill),
        Variant(name: "E · Battery gauge", note: "tightest limit, drains", draw: gauge),
        Variant(name: "F · Tick meter", note: "the panel's language, shrunk", draw: ticks),
        Variant(name: "G · Wedge", note: "smallest footprint", draw: wedge),
    ]

    // MARK: Sheet

    @MainActor
    static func renderIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--render-menubar"), args.count > flag + 1 else {
            return false
        }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let claude = 0.68, chatgpt = 0.49
        let rowH: CGFloat = 64, labelW: CGFloat = 200, zoom: CGFloat = 4
        let sheetW: CGFloat = 760
        let sheetH = rowH * CGFloat(all.count) + 46

        let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH), flipped: false) { rect in
            NSColor(hex: 0x1C1C1F).setFill(); rect.fill()

            let title = "Menu bar options — Claude 68%, ChatGPT 49%" as NSString
            title.draw(at: NSPoint(x: 18, y: sheetH - 28), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])

            for (i, v) in all.enumerated() {
                let y = sheetH - 46 - CGFloat(i + 1) * rowH + 10

                (v.name as NSString).draw(at: NSPoint(x: 18, y: y + 26), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.white,
                ])
                (v.note as NSString).draw(at: NSPoint(x: 18, y: y + 10), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor(white: 1, alpha: 0.45),
                ])

                // Actual size, on a dark bar and a light bar.
                for (j, bg) in [NSColor(hex: 0x2A2A2E), NSColor(hex: 0xEDEDF0)].enumerated() {
                    let strip = NSRect(x: labelW + CGFloat(j) * 130, y: y + 8, width: 120, height: 26)
                    bg.setFill(); NSBezierPath(roundedRect: strip, xRadius: 5, yRadius: 5).fill()
                    let ink = j == 0 ? NSColor.white : NSColor.black
                    let img = v.draw(claude, chatgpt, ink)
                    img.draw(in: NSRect(x: strip.midX - img.size.width / 2,
                                        y: strip.midY - 8, width: img.size.width, height: 16))
                }

                // Blown up, so the shape is judgeable.
                let img = v.draw(claude, chatgpt, .white)
                let zw = img.size.width * zoom
                NSGraphicsContext.current?.imageInterpolation = .none
                img.draw(in: NSRect(x: labelW + 275, y: y + 21 - 8 * zoom / 2 + 4,
                                    width: zw, height: 16 * zoom))
                NSGraphicsContext.current?.imageInterpolation = .default
            }
            return true
        }

        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return true }
        let url = dir.appendingPathComponent("menubar-options.png")
        try? png.write(to: url)
        print(url.path)
        return true
    }

    private static func image(width: CGFloat, _ draw: @escaping (NSRect) -> Void) -> NSImage {
        NSImage(size: NSSize(width: width, height: 16), flipped: false) { rect in
            draw(rect)
            return true
        }
    }
}
