import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The picture that rides along with a notification.
///
/// A banner that is only words makes the reader parse a sentence to learn one thing: how bad
/// is it. The thumbnail answers that before the text is read — colour for severity, a filled
/// arc for position in the window, and the figure itself in the middle.
///
/// Deliberately tiny in scope: a tinted tile, an optional ring, and one short caption. Every
/// notification we send fits that shape, so there is one renderer rather than one per
/// category, and nothing here can drift out of sync with the copy.
public struct NotificationArtwork: Sendable, Equatable {
    /// Drives the tile colour.
    public let tint: Severity
    /// 0...1 of the ring to fill. `nil` draws no ring — used when there is no number to show,
    /// e.g. an auth failure.
    public let ring: Double?
    /// Centred label. Two or three glyphs at most: "90%", "!", "↻".
    public let caption: String

    public init(tint: Severity, ring: Double?, caption: String) {
        self.tint = tint
        self.ring = ring
        self.caption = caption
    }

    /// A figure in percent, drawn as a filled ring with the number inside it.
    public static func percent(_ value: Double, tint: Severity) -> NotificationArtwork {
        NotificationArtwork(
            tint: tint,
            ring: min(max(value / 100, 0), 1),
            caption: "\(Int(value.rounded()))%"
        )
    }

    /// The common case: how much of a limit is left.
    ///
    /// Separate from `percent` so the caller states which of the two it means. A banner
    /// captioned "90%" beside a panel headlined "10%" is the same confusion the rest of the
    /// app was just cured of, and utilisation is what these call sites naturally hold.
    public static func remaining(of limit: LimitWindow, tint: Severity) -> NotificationArtwork {
        percent(limit.remainingPercent, tint: tint)
    }
}

/// Draws `NotificationArtwork` to a PNG on disk.
///
/// CoreGraphics rather than AppKit on purpose — this target is meant to stay free of UI
/// frameworks, and an image encoder is not UI. It also means the renderer is testable without
/// a running app.
public enum NotificationArtworkRenderer {

    /// Rendered well above the ~64pt macOS shows it at, so it stays crisp on any display.
    static let side = 256

    /// Writes a PNG into `directory` and returns its URL, or nil if anything failed.
    /// The caller owns the file; `UNNotificationAttachment` moves it into the system store.
    public static func write(
        _ artwork: NotificationArtwork,
        into directory: URL = FileManager.default.temporaryDirectory,
        name: String = UUID().uuidString
    ) -> URL? {
        guard let image = render(artwork) else { return nil }
        let url = directory.appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    public static func render(_ artwork: NotificationArtwork) -> CGImage? {
        let side = CGFloat(Self.side)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: Self.side, height: Self.side,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        // The tile. Opaque and saturated so the thumbnail reads the same over a light banner,
        // a dark banner, and the grey of Notification Center — an alpha-blended tint does not.
        let inset: CGFloat = 8
        let tile = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        ctx.addPath(CGPath(
            roundedRect: tile, cornerWidth: 54, cornerHeight: 54, transform: nil
        ))
        ctx.setFillColor(fill(for: artwork.tint))
        ctx.fillPath()

        let centre = CGPoint(x: side / 2, y: side / 2)
        if let ring = artwork.ring {
            let radius: CGFloat = 88
            ctx.setLineWidth(16)
            ctx.setLineCap(.round)

            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.26))
            ctx.addArc(
                center: centre, radius: radius,
                startAngle: 0, endAngle: .pi * 2, clockwise: false
            )
            ctx.strokePath()

            // Clockwise from twelve o'clock, the direction every dial in the app turns.
            if ring > 0.004 {
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.addArc(
                    center: centre, radius: radius,
                    startAngle: .pi / 2,
                    endAngle: .pi / 2 - CGFloat(min(ring, 1)) * .pi * 2,
                    clockwise: true
                )
                ctx.strokePath()
            }
        }

        if !artwork.caption.isEmpty {
            // Sized to the inner disc: four glyphs ("100%") have to fit where one ("!") can
            // afford to be huge.
            let size: CGFloat = artwork.caption.count >= 4 ? 50
                : artwork.caption.count >= 2 ? 68 : 112
            draw(artwork.caption, size: size, centre: centre, in: ctx)
        }

        return ctx.makeImage()
    }

    // MARK: drawing helpers

    private static func fill(for severity: Severity) -> CGColor {
        switch severity {
        case .normal: return CGColor(srgbRed: 0.09, green: 0.62, blue: 0.36, alpha: 1)
        case .warning: return CGColor(srgbRed: 0.85, green: 0.53, blue: 0.02, alpha: 1)
        case .critical: return CGColor(srgbRed: 0.80, green: 0.20, blue: 0.17, alpha: 1)
        }
    }

    private static func draw(
        _ text: String, size: CGFloat, centre: CGPoint, in ctx: CGContext
    ) {
        guard let font = boldSystemFont(size: size) else { return }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            // Figures at display size need pulling together or they read as loose.
            kCTKernAttributeName: -size * 0.02,
        ]
        guard let attributed = CFAttributedStringCreate(
            nil, text as CFString, attributes as CFDictionary
        ) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        // Optical bounds centre the glyphs themselves rather than the font's line box, which
        // is what stops "90%" from sitting visibly high inside the ring.
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(
            x: centre.x - bounds.width / 2 - bounds.origin.x,
            y: centre.y - bounds.height / 2 - bounds.origin.y
        )
        CTLineDraw(line, ctx)
    }

    private static func boldSystemFont(size: CGFloat) -> CTFont? {
        guard let base = CTFontCreateUIFontForLanguage(.system, size, nil) else { return nil }
        let traits: [CFString: Any] = [
            kCTFontSymbolicTrait: CTFontSymbolicTraits.traitBold.rawValue
        ]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base),
            [kCTFontTraitsAttribute: traits] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}
