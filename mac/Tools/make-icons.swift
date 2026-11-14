// make-icons.swift: draws Share Bar's app icon and a contact sheet from the Mark geometry,
// no binary art. Not run directly: `mac/icons.sh <outdir>` compiles it together with
// `Sources/ShareBarCore/Mark.swift` and runs it, then builds the .icns with iconutil.
//
// Writes into <outdir>:
//   master-1024.png          the 1024 app icon master (macOS grid: 824 body on a 1024 canvas)
//   AppIcon.iconset/         the ten sizes iconutil wants; 16 and 32 px use the small cut
//   contact-sheet.png        app icon and menu bar glyph at true size and magnified
//
// The menu bar glyph is not written as art: the app draws it at runtime from the same
// Mark, and the sheet only previews it.

import AppKit
import CoreGraphics
import Foundation

let ink = CGColor(srgbRed: 0x0B / 255, green: 0x1B / 255, blue: 0x16 / 255, alpha: 1)
let cream = CGColor(srgbRed: 0xF4 / 255, green: 0xF1 / 255, blue: 0xEA / 255, alpha: 1)
let signal = CGColor(srgbRed: 0x18 / 255, green: 0xC3 / 255, blue: 0x7E / 255, alpha: 1)

/// App icon renders at or below this pixel size use the small cut.
let smallCutLimit = 32

// MARK: - Bitmap helpers

func makeContext(_ width: Int, _ height: Int) -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create a \(width)x\(height) bitmap") }
    return context
}

func finish(_ context: CGContext) -> CGImage {
    guard let image = context.makeImage() else { fatalError("could not read back a bitmap") }
    return image
}

func savePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(url.lastPathComponent)")
    }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do { try data.write(to: url) } catch { fatalError("could not write \(url.path): \(error)") }
}

// MARK: - App icon

/// The macOS grid: an 824 body centred on a 1024 canvas, corner radius 185.4.
func appIconBody(_ side: CGFloat) -> CGRect {
    let body = side * 824 / 1024
    let inset = (side - body) / 2
    return CGRect(x: inset, y: inset, width: body, height: body)
}

/// The app icon at `pixels`. `cut` nil picks by size: the small cut at or below 32 px.
/// The full cut is placed exactly as the master (docs/brand/share-mark.svg): ring centre
/// 491.6 across and 524.4 down a 1024 canvas, 2.55 canvas units per mark unit. The small
/// cut has no pixels to spare, so it is fitted to 70% of the body instead.
func renderAppIcon(pixels: Int, cut forced: Mark.Cut? = nil) -> CGImage {
    let side = CGFloat(pixels)
    let context = makeContext(pixels, pixels)
    let body = appIconBody(side)
    let radius = body.width * 185.4 / 824
    let cut = forced ?? (pixels <= smallCutLimit ? Mark.Cut.small : .full)

    context.setFillColor(ink)
    context.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()

    var transform: CGAffineTransform
    if cut == .small {
        let edge = body.width * 0.70
        let box = CGRect(x: (side - edge) / 2, y: (side - edge) / 2, width: edge, height: edge)
        transform = Mark.transform(cut: cut, fitting: box)
    } else {
        let k = side / 1024
        transform = CGAffineTransform(translationX: 491.6 * k, y: (1024 - 524.4) * k).scaledBy(x: 2.55 * k, y: 2.55 * k)
    }

    context.setFillColor(cream)
    if let ring = Mark.ringPath(serving: true, cut: cut).copy(using: &transform) {
        context.addPath(ring)
        context.fillPath()
    }
    context.setFillColor(signal)
    if let dot = Mark.dotPath(cut: cut).copy(using: &transform) {
        context.addPath(dot)
        context.fillPath()
    }
    return finish(context)
}

// MARK: - Menu bar glyph preview

/// One glyph render the way the app produces it: a template drawn in one colour on clear,
/// `points` square at `scale`, with `Mark.glyphBox` of padding.
func renderGlyph(serving: Bool, points: Int, scale: Int, cut: Mark.Cut, color: CGColor) -> CGImage {
    let pixels = points * scale
    let context = makeContext(pixels, pixels)
    context.setFillColor(color)
    Mark.fill(serving: serving, cut: cut, in: context, box: Mark.glyphBox(canvas: CGFloat(pixels)))
    return finish(context)
}

// MARK: - Contact sheet

struct Sheet {
    let width: Int
    let height: Int
    let context: CGContext

    init(width: Int, height: Int, background: CGColor) {
        self.width = width
        self.height = height
        context = makeContext(width, height)
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// `top` counts down from the top edge, like a layout does.
    func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: CGFloat(height) - top - h, width: w, height: h)
    }

    func fill(_ color: CGColor, _ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        context.setFillColor(color)
        context.fill(rect(x, top, w, h))
    }

    /// Draws `image` into a `w` by `h` box; `smooth: false` is nearest neighbour, so every
    /// source pixel stays a visible block.
    func draw(_ image: CGImage, _ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat, smooth: Bool) {
        context.saveGState()
        context.interpolationQuality = smooth ? .high : .none
        context.draw(image, in: rect(x, top, w, h))
        context.restoreGState()
    }

    func text(_ string: String, _ x: CGFloat, _ top: CGFloat, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor) {
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        NSAttributedString(string: string, attributes: attributes)
            .draw(at: CGPoint(x: x, y: CGFloat(height) - top - size - 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}

func renderContactSheet() -> CGImage {
    let paper = CGColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1)
    let night = CGColor(srgbRed: 0.13, green: 0.14, blue: 0.14, alpha: 1)
    let light = CGColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
    let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    let sheet = Sheet(width: 1600, height: 1580, background: paper)
    let pad: CGFloat = 40

    sheet.text("Share mark: open ring, one dot out", pad, 28, size: 22, weight: .semibold, color: .black)
    sheet.text("Serving = open ring plus dot. Not serving = closed ring, no dot. Pixel views are nearest-neighbour.", pad, 62, size: 13, color: .darkGray)

    // App icon: the master, the smooth ladder down, then 16 and 32 px at 8x, small cut
    // (shipped) beside the full cut (rejected).
    var top: CGFloat = 100
    sheet.text("App icon: master, 128 and 64 px; then 32 and 16 px at 8x, small cut (shipped) before full cut (rejected)", pad, top, size: 15, weight: .semibold, color: .black)
    top += 28
    sheet.draw(renderAppIcon(pixels: 1024), pad, top, 256, 256, smooth: true)
    var x = pad + 256 + 36
    for px in [128, 64] {
        sheet.draw(renderAppIcon(pixels: px), x, top + CGFloat(256 - px), CGFloat(px), CGFloat(px), smooth: true)
        sheet.text("\(px) px", x, top + 262, size: 12, color: .darkGray)
        x += CGFloat(px) + 36
    }
    x = 700
    let ladder: [(px: Int, cut: Mark.Cut)] = [(32, .small), (16, .small), (32, .full), (16, .full)]
    for entry in ladder {
        let image = renderAppIcon(pixels: entry.px, cut: entry.cut)
        let size = CGFloat(entry.px) * 8
        sheet.draw(image, x, top + (256 - size), size, size, smooth: false)
        sheet.text("\(entry.px) px, \(entry.cut == .small ? "small cut" : "full cut")", x, top + 262, size: 11, color: .darkGray)
        sheet.draw(image, x, top + 284, CGFloat(entry.px), CGFloat(entry.px), smooth: false)
        sheet.text("true size", x + CGFloat(entry.px) + 8, top + 288, size: 11, color: .darkGray)
        x += size + 24
    }
    top += 256 + 70

    // Menu bar glyph: each state at 16 and 18 pt, @1x and @2x, on light and dark.
    sheet.text("Menu bar glyph (template, drawn in code, small cut)", pad, top, size: 15, weight: .semibold, color: .black)
    top += 30
    let cells: [(points: Int, scale: Int, zoom: CGFloat)] = [(16, 1, 14), (18, 1, 12), (16, 2, 7), (18, 2, 6)]
    let cellSide: CGFloat = 250
    for (rowIndex, serving) in [true, false].enumerated() {
        for (bgIndex, bg) in [light, night].enumerated() {
            let fg = bgIndex == 0 ? black : white
            let rowTop = top + CGFloat(rowIndex * 2 + bgIndex) * (cellSide + 6)
            for (index, cell) in cells.enumerated() {
                let cx = pad + CGFloat(index) * (cellSide + 6)
                sheet.fill(bg, cx, rowTop, cellSide, cellSide)
                let image = renderGlyph(serving: serving, points: cell.points, scale: cell.scale, cut: .small, color: fg)
                let size = CGFloat(image.width) * cell.zoom
                sheet.draw(image, cx + (cellSide - size) / 2, rowTop + (cellSide - size) / 2 - 8, size, size, smooth: false)
                let tint = bgIndex == 0 ? NSColor.black : NSColor.white
                sheet.text("\(cell.points) pt @\(cell.scale)x = \(image.width) px, \(serving ? "serving" : "not serving")", cx + 8, rowTop + cellSide - 22, size: 11, color: tint)
            }
        }
    }

    // Right column: true size on a mock menu bar, then the cut comparison.
    let colX = pad + 4 * (cellSide + 6) + 20
    let colW = CGFloat(sheet.width) - colX - pad
    sheet.text("True size, 18 pt @2x, serving then not serving", colX, top, size: 12, color: .darkGray)
    for (index, bg) in [light, night].enumerated() {
        let barTop = top + 22 + CGFloat(index) * 56
        sheet.fill(bg, colX, barTop, colW, 44)
        let fg = index == 0 ? black : white
        var gx = colX + 20
        for serving in [true, false] {
            let image = renderGlyph(serving: serving, points: 18, scale: 2, cut: .small, color: fg)
            sheet.draw(image, gx, barTop + 13, 18, 18, smooth: true)
            gx += 40
        }
    }
    var compareTop = top + 150
    for (points, zoom) in [(16, CGFloat(12)), (18, CGFloat(11))] {
        sheet.text("\(points) pt @1x, \(Int(zoom))x: full cut, then small cut", colX, compareTop, size: 12, color: .darkGray)
        for (index, cut) in [Mark.Cut.full, .small].enumerated() {
            let cx = colX + CGFloat(index) * 232
            sheet.fill(light, cx, compareTop + 22, 226, 226)
            let image = renderGlyph(serving: true, points: points, scale: 1, cut: cut, color: black)
            let size = CGFloat(points) * zoom
            sheet.draw(image, cx + (226 - size) / 2, compareTop + 22 + (226 - size) / 2, size, size, smooth: false)
        }
        compareTop += 270
    }
    return finish(sheet.context)
}

// MARK: - Main

@main
enum MakeIcons {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: make-icons <outdir>\n".utf8))
            exit(2)
        }
        let out = URL(fileURLWithPath: arguments[1], isDirectory: true)

        savePNG(renderAppIcon(pixels: 1024), to: out.appendingPathComponent("master-1024.png"))

        let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        let sizes: [(name: String, pixels: Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for entry in sizes {
            savePNG(renderAppIcon(pixels: entry.pixels), to: iconset.appendingPathComponent("\(entry.name).png"))
        }

        savePNG(renderContactSheet(), to: out.appendingPathComponent("contact-sheet.png"))
        print("wrote master-1024.png, AppIcon.iconset (\(sizes.count) sizes) and contact-sheet.png to \(out.path)")
    }
}
