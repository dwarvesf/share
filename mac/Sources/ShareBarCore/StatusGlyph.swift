import AppKit

/// The menu bar glyph as an `NSImage`: the `Mark`, small cut, drawn black on clear into
/// bitmaps at 1x, 2x and 3x, and flagged as a template so macOS tints it for light, dark
/// and the pressed state. Bitmaps rather than a drawing handler so a failure to draw is a
/// `nil` the caller can answer with a text title, never a silently blank status item.
public enum StatusGlyph {
    /// The canvas, in points. The glyph fills 16 of the 18 (`Mark.glyphBox`).
    public static let points: CGFloat = 18
    static let scales = [1, 2, 3]

    /// The glyph for a state: the open ring plus dot while `serving`, the closed ring
    /// otherwise. `nil` when a bitmap could not be created.
    public static func image(serving: Bool) -> NSImage? {
        let image = NSImage(size: NSSize(width: points, height: points))
        for scale in scales {
            guard let rep = bitmap(serving: serving, scale: scale) else { return nil }
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    static func bitmap(serving: Bool, scale: Int) -> NSBitmapImageRep? {
        let pixels = Int(points) * scale
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ),
            let graphics = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.clear(canvas)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        Mark.fill(serving: serving, cut: .small, in: context, box: Mark.glyphBox(canvas: CGFloat(pixels)))
        // Drawn in pixels; report the rep in points so AppKit picks it by backing scale.
        rep.size = NSSize(width: points, height: points)
        return rep
    }
}
