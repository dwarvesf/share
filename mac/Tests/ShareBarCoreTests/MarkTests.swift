import AppKit
import XCTest
@testable import ShareBarCore

/// The Share mark and its menu bar glyph: at every size a menu bar uses, serving reads as
/// two separate shapes (open ring, dot) and not serving as one (closed ring), and the
/// image is a template that is never blank.
final class MarkTests: XCTestCase {
    /// A render of the glyph box: alpha per pixel, row 0 at the top.
    private struct Raster {
        let side: Int
        let alpha: [UInt8]

        func ink(_ x: Int, _ y: Int) -> UInt8 { alpha[y * side + x] }

        /// The pixel under a mark-space point, y up.
        func pixel(_ point: CGPoint, cut: Mark.Cut) -> (x: Int, y: Int) {
            let mapped = point.applying(Mark.transform(cut: cut, fitting: Mark.glyphBox(canvas: CGFloat(side))))
            return (Int(mapped.x.rounded(.down)), side - 1 - Int(mapped.y.rounded(.down)))
        }

        /// 4-connected groups of pixels at least `threshold` opaque.
        func components(threshold: UInt8 = 96) -> Int {
            var seen = [Bool](repeating: false, count: side * side)
            var count = 0
            for start in 0 ..< side * side where alpha[start] >= threshold && !seen[start] {
                count += 1
                var stack = [start]
                seen[start] = true
                while let index = stack.popLast() {
                    let x = index % side, y = index / side
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
                        let next = ny * side + nx
                        if alpha[next] >= threshold, !seen[next] {
                            seen[next] = true
                            stack.append(next)
                        }
                    }
                }
            }
            return count
        }
    }

    private func raster(serving: Bool, cut: Mark.Cut = .small, side: Int) -> Raster {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        Mark.fill(serving: serving, cut: cut, in: context, box: Mark.glyphBox(canvas: CGFloat(side)))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var alpha = [UInt8](repeating: 0, count: side * side)
        for y in 0 ..< side {
            for x in 0 ..< side {
                alpha[y * side + x] = bytes[y * context.bytesPerRow + x * 4 + 3]
            }
        }
        return Raster(side: side, alpha: alpha)
    }

    /// 16 and 18 pt at 1x, 32 and 36 px for 2x, 54 for 3x.
    private let menuBarSides = [16, 18, 32, 36, 54]

    func testServingIsTwoSeparateShapesAtEveryMenuBarSize() {
        for side in menuBarSides {
            XCTAssertEqual(raster(serving: true, side: side).components(), 2, "open ring and dot at \(side) px")
        }
    }

    func testNotServingIsOneClosedRingAtEveryMenuBarSize() {
        for side in menuBarSides {
            let ring = raster(serving: false, side: side)
            XCTAssertEqual(ring.components(), 1, "closed ring at \(side) px")
            let centre = ring.pixel(.zero, cut: .small)
            XCTAssertEqual(ring.ink(centre.x, centre.y), 0, "the ring is hollow at \(side) px")
        }
    }

    func testTheDotAndTheOpeningTellTheStatesApart() {
        let dot = Mark.dotCenter(cut: .small)
        let opening = CGPoint(x: 69 * cos(Mark.axisDegrees * .pi / 180), y: 69 * sin(Mark.axisDegrees * .pi / 180))
        for side in menuBarSides {
            let serving = raster(serving: true, side: side)
            let stopped = raster(serving: false, side: side)

            let dotPixel = serving.pixel(dot, cut: .small)
            XCTAssertGreaterThanOrEqual(serving.ink(dotPixel.x, dotPixel.y), 200, "dot present while serving at \(side) px")
            XCTAssertEqual(stopped.ink(dotPixel.x, dotPixel.y), 0, "no dot when not serving at \(side) px")

            let gap = serving.pixel(opening, cut: .small)
            XCTAssertEqual(serving.ink(gap.x, gap.y), 0, "ring open at the top right at \(side) px")
            XCTAssertGreaterThanOrEqual(stopped.ink(gap.x, gap.y), 200, "ring closed when not serving at \(side) px")
        }
    }

    func testEveryCutKeepsTheDotClearOfTheRing() {
        // Geometry, not pixels: the nearest ring corner to the dot is further than the
        // dot's radius, by at least two thirds of the ring's thickness for the small cut.
        for cut in [Mark.Cut.full, .small] {
            let spec = Mark.spec(cut)
            let dot = Mark.dotCenter(cut: cut)
            let edge = (Mark.axisDegrees + spec.halfGap) * .pi / 180
            let corner = CGPoint(x: spec.outer * cos(edge), y: spec.outer * sin(edge))
            let clearance = hypot(dot.x - corner.x, dot.y - corner.y) - spec.dotRadius
            XCTAssertGreaterThan(clearance, 0, "\(cut)")
            if cut == .small {
                XCTAssertGreaterThan(clearance, (spec.outer - spec.inner) * 2 / 3, "small cut gap")
            }
        }
    }

    func testStatusGlyphIsATemplateWithARepForEachScale() throws {
        for serving in [true, false] {
            let image = try XCTUnwrap(StatusGlyph.image(serving: serving))
            XCTAssertTrue(image.isTemplate, "template: macOS tints it")
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            let pixels = image.representations.compactMap { ($0 as? NSBitmapImageRep)?.pixelsWide }
            XCTAssertEqual(pixels, [18, 36, 54])
        }
    }

    func testStatusGlyphIsNeverBlankAndTheStatesDiffer() throws {
        func inkTotal(_ serving: Bool) throws -> Int {
            let image = try XCTUnwrap(StatusGlyph.image(serving: serving))
            let rep = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.last)
            var total = 0
            for y in 0 ..< rep.pixelsHigh {
                for x in 0 ..< rep.pixelsWide {
                    total += Int((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255)
                }
            }
            return total
        }
        let serving = try inkTotal(true)
        let stopped = try inkTotal(false)
        XCTAssertGreaterThan(serving, 0)
        XCTAssertGreaterThan(stopped, 0)
        XCTAssertNotEqual(serving, stopped)
    }
}
