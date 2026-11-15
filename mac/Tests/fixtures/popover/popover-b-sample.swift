// popover-b-sample.swift: the design-parity check of one popover B screen. Crops the design render,
// puts it beside the build's capture in one image, and samples both in sRGB. A text sample is the
// pixel of its box farthest from the background (the ink at full strength).
//
// Usage: swiftc -O popover-b-sample.swift -o popover-b-sample
//        popover-b-sample <design.png> <x> <y> <w> <h> <capture.png> <composite.png> <light|dark> <probe>...
// Probes (coordinates in the 2x crop; a negative y counts from the bottom of that image):
//   bg:<name>:<x>,<y>               the color at a point
//   ink:<name>:<x0>,<y0>,<x1>,<y1>[:<allowed steps>]   the extreme pixel of a box
//   line:<name>:<x>,<y0>,<y1>[:<allowed steps>]        the strongest rule on a column, against the first probe's bg
// A sample passes within 6 sRGB steps unless a probe names its own allowance (a deliberate deviation).
import AppKit

func load(_ path: String) -> NSBitmapImageRep {
    guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); exit(1)
    }
    return rep
}

func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
    guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [0, 0, 0] }
    return [Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())]
}

func luma(_ p: [Int]) -> Int { p[0] * 299 + p[1] * 587 + p[2] * 114 }
func hex(_ p: [Int]) -> String { String(format: "#%02x%02x%02x", p[0], p[1], p[2]) }

let a = CommandLine.arguments
guard a.count >= 10, var dx = Int(a[2]), var dy = Int(a[3]), let dw = Int(a[4]), var dh = Int(a[5]) else {
    FileHandle.standardError.write(Data("usage: popover-b-sample <design.png> x y w h <capture.png> <composite.png> <light|dark> <probe>...\n".utf8)); exit(2)
}
let design = load(a[1]), mine = load(a[6]), dark = a[8] == "dark"
if dx < 0 {
    // Detect the panel from the two magenta marks design-scene.py adds (inside the panel: 6 css px from the left and top, 8 css px above the bottom).
    var first: (Int, Int)?, last: (Int, Int)?
    for yy in 0..<design.pixelsHigh { for xx in 0..<design.pixelsWide {
        let p = rgb(design, xx, yy)
        if p[0] > 200, p[2] > 200, p[1] < 110 { if first == nil { first = (xx, yy) }; last = (xx, yy) }
    } }
    guard let f = first, let l = last, l.1 > f.1 else { FileHandle.standardError.write(Data("no corner marks in the design render\n".utf8)); exit(1) }
    dx = f.0 - 12; dy = f.1 - 12; dh = l.1 - f.1 + 25
    print("panel found at \(dx),\(dy) height \(dh) (marks \(f), \(l))")
}
let probes = Array(a.dropFirst(9))

struct Probe { let kind: String; let name: String; let nums: [Int]; let allow: Int }
func parse(_ spec: String) -> Probe {
    let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 3 else { fatalError("bad probe \(spec)") }
    return Probe(kind: parts[0], name: parts[1], nums: parts[2].split(separator: ",").compactMap { Int($0) }, allow: parts.count > 3 ? Int(parts[3]) ?? 6 : 6)
}
let specs = probes.map(parse)

/// One image's samples: `ox, oy` the crop origin, `height` the crop's height (for a negative y).
func sample(_ rep: NSBitmapImageRep, ox: Int, oy: Int, height: Int) -> [[Int]] {
    func y(_ v: Int) -> Int { v < 0 ? oy + height + v : oy + v }
    var bg = [0, 0, 0]
    var out: [[Int]] = []
    for p in specs {
        switch p.kind {
        case "bg":
            bg = rgb(rep, ox + p.nums[0], y(p.nums[1]))
            out.append(bg)
        case "ink":
            var best = bg, bestD = -1
            for yy in y(p.nums[1])..<y(p.nums[3]) { for xx in (ox + p.nums[0])..<(ox + p.nums[2]) {
                let px = rgb(rep, xx, yy)
                let d = abs(luma(px) - luma(bg))
                if d > bestD { bestD = d; best = px }
            } }
            out.append(best)
        default:
            var best = bg, bestD = 0
            for yy in y(p.nums[1])..<y(p.nums[2]) {
                let px = rgb(rep, ox + p.nums[0], yy)
                let d = abs(luma(px) - luma(bg))
                if d > bestD { bestD = d; best = px }
            }
            out.append(best)
        }
    }
    return out
}

let d = sample(design, ox: dx, oy: dy, height: dh)
let m = sample(mine, ox: 0, oy: 0, height: mine.pixelsHigh)
print("sample                    design   build    max step  allowed")
var failed = false
for (i, p) in specs.enumerated() {
    let step = zip(d[i], m[i]).map { abs($0 - $1) }.max() ?? 0
    let ok = step <= p.allow
    if !ok { failed = true }
    print(p.name.padding(toLength: 25, withPad: " ", startingAt: 0), hex(d[i]), hex(m[i]), String(step).padding(toLength: 9, withPad: " ", startingAt: 0), p.allow, ok ? "" : "GAP")
}
print("size design \(dw)x\(dh), build \(mine.pixelsWide)x\(mine.pixelsHigh)")
print(failed ? "VERDICT: a sample is outside its allowance" : "VERDICT: every sample within its allowance")

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
