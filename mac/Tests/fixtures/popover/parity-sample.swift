// parity-sample.swift: the design-parity check. Crops the popover out of a design render, puts it beside
// the build's capture in one image, and samples both in sRGB: the window background, the primary and
// secondary text, the search placeholder and a separator. Text is sampled as the extreme pixel of its box.
//
// Usage: swiftc -O parity-sample.swift -o parity-sample
//        parity-sample <design.png> <x> <y> <w> <h> <capture.png> <composite.png> <light|dark>
import AppKit

func load(_ path: String) -> NSBitmapImageRep {
    guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); exit(1)
    }
    return rep
}

func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [0, 0, 0] }
    return [Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())]
}

func luma(_ p: [Int]) -> Int { p[0] * 299 + p[1] * 587 + p[2] * 114 }

/// The pixel of the box farthest from the background: the ink at its full strength.
func ink(_ rep: NSBitmapImageRep, _ box: (Int, Int, Int, Int), bg: [Int]) -> [Int] {
    var best = bg, bestD = -1
    for y in box.1..<box.3 { for x in box.0..<box.2 {
        let p = rgb(rep, x, y)
        let d = abs(luma(p) - luma(bg))
        if d > bestD { bestD = d; best = p }
    } }
    return best
}

/// A sample the build leaves apart from the design on purpose, with the steps it may differ by.
/// The placeholder keeps the darkened tertiary (`#6b6b70`, dark `#919196`) where the design has
/// `#7a7a80` and `#8a8a8f`: 15 and 7 steps (`Tokens.swift`, contrast 4.5:1 against the window).
let deliberate: [String: Int] = ["search placeholder": 16]

func hex(_ p: [Int]) -> String { String(format: "#%02x%02x%02x", p[0], p[1], p[2]) }

let a = CommandLine.arguments
guard a.count == 9, let dx = Int(a[2]), let dy = Int(a[3]), let dw = Int(a[4]), let dh = Int(a[5]) else {
    FileHandle.standardError.write(Data("usage: parity-sample <design.png> x y w h <capture.png> <composite.png> <light|dark>\n".utf8)); exit(2)
}
let design = load(a[1]), mine = load(a[6]), dark = a[8] == "dark"

struct Probe { let name: String; let box: (Int, Int, Int, Int)? }
let bgPoint = (8, 300)
let boxes: [(String, (Int, Int, Int, Int))] = [
    ("primary text", (30, 28, 160, 58)),
    ("secondary text", (108, 204, 180, 224)),
    ("search placeholder", (78, 96, 222, 120)),
]

func samples(_ rep: NSBitmapImageRep, ox: Int, oy: Int) -> [(String, [Int])] {
    let bg = rgb(rep, ox + bgPoint.0, oy + bgPoint.1)
    var out: [(String, [Int])] = [("background", bg)]
    for (name, b) in boxes { out.append((name, ink(rep, (ox + b.0, oy + b.1, ox + b.2, oy + b.3), bg: bg))) }
    // The separator: the footer rule, a one-pixel line near y 452 across the popover's middle.
    var sep = bg, sepD = 0
    for y in 430..<475 {
        let p = rgb(rep, ox + 340, oy + y)
        let d = abs(luma(p) - luma(bg))
        if d > sepD { sepD = d; sep = p }
    }
    out.append(("separator", sep))
    return out
}

let d = samples(design, ox: dx, oy: dy)
let m = samples(mine, ox: 0, oy: 0)
print("sample              design   build    max step")
var failed = false
for (i, row) in d.enumerated() {
    let step = zip(row.1, m[i].1).map { abs($0 - $1) }.max() ?? 0
    print(row.0.padding(toLength: 19, withPad: " ", startingAt: 0), hex(row.1), hex(m[i].1), step)
    if step > (deliberate[row.0] ?? 6) { failed = true }
    if deliberate[row.0] != nil { print("  (deliberate darker tertiary, allowed \(deliberate[row.0]!) steps)") }
}
print(failed ? "VERDICT: gap above 6 steps" : "VERDICT: every sample within tolerance (6 steps, the deliberate placeholder 16)")

// Composite: design crop left, build right, 24 px gutter.
let h = max(dh, mine.pixelsHigh), w = dw + 24 + mine.pixelsWide
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.setFillColor(dark ? CGColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1) : CGColor(srgbRed: 0.8, green: 0.8, blue: 0.82, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
if let full = design.cgImage, let crop = full.cropping(to: CGRect(x: dx, y: dy, width: dw, height: dh)) {
    ctx.draw(crop, in: CGRect(x: 0, y: h - dh, width: dw, height: dh))
}
if let img = mine.cgImage { ctx.draw(img, in: CGRect(x: dw + 24, y: h - mine.pixelsHigh, width: mine.pixelsWide, height: mine.pixelsHigh)) }
if let out = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: a[7]))
}
exit(failed ? 1 : 0)
