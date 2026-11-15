import CoreGraphics
import Foundation

/// The Share mark: an open ring (your Mac) with one dot leaving through the opening at
/// the top right (the link going out to the world). Serving is the open ring plus the
/// dot; not serving is the closed ring with no dot.
///
/// This is the only place the shapes live. The menu bar glyph (`StatusIcon`) and the app
/// icon tool (`mac/Tools/make-icons.swift`, compiled together with this file) both draw
/// from it, so the two cannot drift. Coordinates are mark units, y up, the ring centre
/// at the origin; the numbers are the 256-unit shapes of `docs/brand/share-mark.svg`.
public enum Mark {
    /// `full` is the master mark. `small` is the cut for 16 to 36 px renders, where the
    /// full cut's dot merged into the ring: a thicker ring, a wider opening, and the dot
    /// pushed further out, so the three gaps stay at least two device pixels wide.
    public enum Cut: Sendable {
        case full
        case small
    }

    struct Spec {
        let outer: CGFloat
        let inner: CGFloat
        /// Half the opening's angle, in degrees, either side of the 45 degree axis.
        let halfGap: CGFloat
        /// Distance from the ring centre to the dot centre.
        let dotDistance: CGFloat
        let dotRadius: CGFloat
    }

    static let axisDegrees: CGFloat = 45

    static func spec(_ cut: Cut) -> Spec {
        switch cut {
        case .full:
            return Spec(outer: 92, inner: 52, halfGap: 30, dotDistance: 116, dotRadius: 30)
        case .small:
            return Spec(outer: 92, inner: 46, halfGap: 34, dotDistance: 126, dotRadius: 31)
        }
    }

    private static func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

    /// The ring: an annulus with a radial-edged opening when `serving`, a closed annulus
    /// otherwise. Fill it with the even-odd rule (the closed ring is two circles).
    public static func ringPath(serving: Bool, cut: Cut) -> CGPath {
        let s = spec(cut)
        let path = CGMutablePath()
        if serving {
            let start = radians(axisDegrees + s.halfGap)
            let end = radians(axisDegrees - s.halfGap) + 2 * .pi
            path.addArc(center: .zero, radius: s.outer, startAngle: start, endAngle: end, clockwise: false)
            path.addArc(center: .zero, radius: s.inner, startAngle: end, endAngle: start, clockwise: true)
            path.closeSubpath()
        } else {
            path.addEllipse(in: CGRect(x: -s.outer, y: -s.outer, width: 2 * s.outer, height: 2 * s.outer))
            path.addEllipse(in: CGRect(x: -s.inner, y: -s.inner, width: 2 * s.inner, height: 2 * s.inner))
        }
        return path
    }

    public static func dotCenter(cut: Cut) -> CGPoint {
        let s = spec(cut)
        let angle = radians(axisDegrees)
        return CGPoint(x: s.dotDistance * cos(angle), y: s.dotDistance * sin(angle))
    }

    public static func dotRadius(cut: Cut) -> CGFloat { spec(cut).dotRadius }

    public static func dotPath(cut: Cut) -> CGPath {
        let c = dotCenter(cut: cut)
        let r = spec(cut).dotRadius
        return CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
    }

    /// The square that holds the serving mark. The not-serving ring is drawn inside the
    /// same square, so the ring does not move when the dot appears.
    public static func bounds(cut: Cut) -> CGRect {
        let s = spec(cut)
        let dot = dotCenter(cut: cut)
        let high = max(s.outer, dot.x + s.dotRadius, dot.y + s.dotRadius)
        return CGRect(x: -s.outer, y: -s.outer, width: s.outer + high, height: s.outer + high)
    }

    /// The transform that fits `bounds(cut:)` into `box`, centred, y up.
    public static func transform(cut: Cut, fitting box: CGRect) -> CGAffineTransform {
        let source = bounds(cut: cut)
        let scale = min(box.width, box.height) / source.width
        return CGAffineTransform(translationX: box.midX, y: box.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -source.midX, y: -source.midY)
    }

    /// Where the menu bar glyph sits in its square canvas: one eighteenth of the canvas of
    /// padding on each side, so an 18 pt canvas holds a 16 pt glyph.
    public static func glyphBox(canvas: CGFloat) -> CGRect {
        let inset = canvas / 18
        return CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    }

    /// Fills the whole mark (ring and dot) with the context's current fill colour.
    public static func fill(serving: Bool, cut: Cut, in context: CGContext, box: CGRect) {
        var transform = transform(cut: cut, fitting: box)
        context.saveGState()
        if let ring = ringPath(serving: serving, cut: cut).copy(using: &transform) {
            context.addPath(ring)
        }
        if serving, let dot = dotPath(cut: cut).copy(using: &transform) {
            context.addPath(dot)
        }
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }
}
