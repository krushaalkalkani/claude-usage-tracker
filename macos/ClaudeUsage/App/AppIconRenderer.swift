import AppKit
import ClaudeUsageCore

/// Draws the application icon.
///
/// `ClaudeUsage --render-appicon <dir>` writes a complete `AppIcon.iconset`, which
/// `build-app.sh` feeds to `iconutil`. Generated rather than checked in as a binary for the
/// same reason `MenuBarIcon` is: every size is drawn at its own pixel dimensions instead of
/// being downscaled from one master, and the design lives in reviewable code.
///
/// Until this existed the bundle had no icon at all, so every notification the app posted
/// carried the generic placeholder document glyph — the single most obvious thing wrong with
/// how the alerts looked.
///
/// The motif is a ring gauge: a faint full track with the spent portion filled in, clockwise
/// from twelve. A segmented dial was tried first and read as a loading spinner — a contiguous
/// arc against a visible track cannot be mistaken for one.
enum AppIconRenderer {

    /// Filenames `iconutil` expects, and the pixel size each one is drawn at.
    static let variants: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    @MainActor
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--render-appicon"), args.count > flag + 1 else {
            return false
        }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for variant in variants {
            guard let png = png(pixels: variant.pixels) else {
                FileHandle.standardError.write(Data("icon render failed: \(variant.name)\n".utf8))
                continue
            }
            try? png.write(to: dir.appendingPathComponent("\(variant.name).png"))
        }
        return true
    }

    static func png(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(side: CGFloat(pixels))
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// Everything is expressed as a fraction of the canvas, so one routine covers 16px and
    /// 1024px without a table of per-size tweaks.
    private static func draw(side: CGFloat) {
        // Apple's grid: the body of a macOS icon fills ~80.5% of the canvas, leaving room for
        // the shadow the system expects to be baked in.
        let bodyInset = side * 0.0977
        let body = NSRect(
            x: bodyInset, y: bodyInset,
            width: side - bodyInset * 2, height: side - bodyInset * 2
        )
        let radius = body.width * 0.225
        let tile = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        NSGraphicsContext.current?.saveGraphicsState()
        tile.addClip()
        NSGradient(
            starting: NSColor(hex: 0x2A2D35), ending: NSColor(hex: 0x121419)
        )?.draw(in: body, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()

        // A hairline edge keeps the tile from dissolving into a dark Dock or a dark
        // notification banner.
        NSColor.white.withAlphaComponent(0.10).setStroke()
        tile.lineWidth = max(0.5, side * 0.006)
        tile.stroke()

        drawGauge(side: side, filled: 0.68)
    }

    private static func drawGauge(side: CGFloat, filled: Double) {
        let centre = CGPoint(x: side / 2, y: side / 2)
        let radius = side * 0.268
        let width = max(1.5, side * 0.105)

        let track = NSBezierPath()
        track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = width
        NSColor.white.withAlphaComponent(0.13).setStroke()
        track.stroke()

        // Twelve o'clock, clockwise: the direction every dial in the app turns.
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: centre, radius: radius, startAngle: 90,
            endAngle: 90 - CGFloat(filled) * 360, clockwise: true
        )
        arc.lineWidth = width
        arc.lineCapStyle = .round
        NSColor(hex: 0x35D07F).setStroke()
        arc.stroke()
    }
}
