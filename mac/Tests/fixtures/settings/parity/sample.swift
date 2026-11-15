// sample.swift: the objective design-parity tool (owner, 2026-11-15).
//
//   sample mode <png>                          most common sRGB color of the image
//   sample region <png> <x> <y> <w> <h>        in sRGB: the most common color, the darkest and the lightest
//   sample rule <png> <x> <y0> <y1>            first pixel that differs from the ground in a column (the header rule)
//   sample content <png> <magenta hex>         height in px of the rows above the first all-magenta row (design render)
//   sample side <reference.png> <capture.png> <out.png> <label> [refHeightPx]
//                                              the two images side by side on one sheet, reference left
//
// Every image is drawn into an sRGB bitmap first, so a capture in the display's color space and a
// Chrome render both read in the same space. Coordinates are pixels of the image as stored.
import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

struct Bitmap {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(path: String) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(path)") }
        let w = image.width
        let h = image.height
        width = w
        height = h
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        data = pixels
    }

    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
}

func hex(_ c: (Int, Int, Int)) -> String { String(format: "#%02x%02x%02x", c.0, c.1, c.2) }

func luminance(_ c: (Int, Int, Int)) -> Double { 0.2126 * Double(c.0) + 0.7152 * Double(c.1) + 0.0722 * Double(c.2) }

func region(_ b: Bitmap, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> (mode: (Int, Int, Int), dark: (Int, Int, Int), light: (Int, Int, Int)) {
    var counts: [Int: Int] = [:]
    var dark = (255, 255, 255)
    var light = (0, 0, 0)
    for yy in max(0, y)..<min(b.height, y + h) {
        for xx in max(0, x)..<min(b.width, x + w) {
            let p = b.pixel(xx, yy)
            counts[(p.0 << 16) | (p.1 << 8) | p.2, default: 0] += 1
            if luminance(p) < luminance(dark) { dark = p }
            if luminance(p) > luminance(light) { light = p }
        }
    }
    let top = counts.max { $0.value < $1.value }?.key ?? 0
    return ((top >> 16, (top >> 8) & 255, top & 255), dark, light)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: sample mode|region|content|side ...") }

switch args[1] {
case "mode":
    let b = Bitmap(path: args[2])
    print(hex(region(b, 0, 0, b.width, b.height).mode))
case "region":
    guard args.count == 7, let x = Int(args[3]), let y = Int(args[4]), let w = Int(args[5]), let h = Int(args[6]) else { fail("usage: sample region <png> x y w h") }
    let r = region(Bitmap(path: args[2]), x, y, w, h)
    print("mode=\(hex(r.mode)) darkest=\(hex(r.dark)) lightest=\(hex(r.light))")
case "rule":
    // sample rule <png> <x> <y0> <y1>: the first pixel below the ground color in a column (the header rule)
    guard args.count == 6, let x = Int(args[3]), let y0 = Int(args[4]), let y1 = Int(args[5]) else { fail("usage: sample rule <png> x y0 y1") }
    let b = Bitmap(path: args[2])
    let ground = hex(b.pixel(x, y0))
    var found = "none"
    for y in y0..<min(y1, b.height) where hex(b.pixel(x, y)) != ground { found = hex(b.pixel(x, y)) + "@\(y)"; break }
    print(found)
case "content":
    guard args.count == 4 else { fail("usage: sample content <png> <magenta hex>") }
    let b = Bitmap(path: args[2])
    let want = args[3].hasPrefix("#") ? args[3].lowercased() : "#" + args[3].lowercased()
    var rows = 0
    for y in 0..<b.height {
        let p = b.pixel(b.width / 2, y)
        if hex(p) == want { break }
        rows = y + 1
    }
    print(rows)
case "side":
    guard args.count >= 6 else { fail("usage: sample side <ref> <capture> <out> <label> [refHeightPx]") }
    let ref = Bitmap(path: args[2])
    let cap = Bitmap(path: args[3])
    let refHeight = args.count > 6 ? (Int(args[6]) ?? ref.height) : ref.height
    let gap = 24
    let titleHeight = 44
    let height = max(refHeight, cap.height) + titleHeight
    let width = ref.width + cap.width + gap * 3
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    func draw(_ path: String, x: Int, rows: Int) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let crop = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: min(rows, image.height)))!
        context.draw(crop, in: CGRect(x: x, y: height - titleHeight - crop.height, width: crop.width, height: crop.height))
    }
    draw(args[2], x: gap, rows: refHeight)
    draw(args[3], x: ref.width + gap * 2, rows: cap.height)
    let label = "reference (revision 8)   |   Share Bar capture, \(args[5])"
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.current = graphics
    (label as NSString).draw(at: CGPoint(x: gap, y: height - 32), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.white])
    guard let out = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[4]) as CFURL, "public.png" as CFString, 1, nil) else { fail("cannot write \(args[4])") }
    CGImageDestinationAddImage(destination, out, nil)
    CGImageDestinationFinalize(destination)
default:
    fail("unknown command \(args[1])")
}
