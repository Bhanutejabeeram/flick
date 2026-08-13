// Draws the Flick logo — three rounded bars + a chevron — and writes:
//   AppIcon.iconset/  (all sizes, dark tile, for iconutil)
//   MenuIcon.png / MenuIcon@2x.png  (monochrome template for the menu bar)
// Usage: swift scripts/make-icons.swift <output-dir>
import AppKit

// ── Palette ────────────────────────────────────────────────────────────────
// Bar gradient, tweak these two to restyle the logo.
let barStart = NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.30, alpha: 1) // amber
let barEnd   = NSColor(calibratedRed: 1.00, green: 0.40, blue: 0.35, alpha: 1) // coral
let chevronColor = NSColor.white
let tileColor = NSColor(calibratedRed: 0.055, green: 0.055, blue: 0.075, alpha: 1)

// ── Geometry (unit square, y-up) ───────────────────────────────────────────
// (minX, maxX, centerY) per bar; middle bar is the widest, like the mock.
let bars: [(CGFloat, CGFloat, CGFloat)] = [
    (0.14, 0.40, 0.66),
    (0.09, 0.43, 0.50),
    (0.13, 0.39, 0.34),
]
let barHeight: CGFloat = 0.085
let chevron: [(CGFloat, CGFloat)] = [(0.56, 0.83), (0.84, 0.50), (0.56, 0.17)]
let chevronWidth: CGFloat = 0.115

func drawLogo(in rect: CGRect, tile: Bool, monochrome: Bool) {
    let s = rect.width
    if tile {
        let inset = s * 0.06
        let tileRect = rect.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: tileRect, xRadius: s * 0.20, yRadius: s * 0.20)
        tileColor.setFill()
        path.fill()
    }
    for (i, bar) in bars.enumerated() {
        let h = barHeight * s
        let barRect = CGRect(x: bar.0 * s, y: bar.2 * s - h / 2,
                             width: (bar.1 - bar.0) * s, height: h)
        let pill = NSBezierPath(roundedRect: barRect, xRadius: h / 2, yRadius: h / 2)
        if monochrome {
            NSColor.black.setFill()
            pill.fill()
        } else {
            // Shift each bar's gradient slightly, like the reference mark.
            let t = CGFloat(i) * 0.18
            let a = barStart.blended(withFraction: t, of: barEnd) ?? barStart
            let b = barEnd.blended(withFraction: t * 0.5, of: barStart) ?? barEnd
            NSGradient(starting: a, ending: b)?.draw(in: pill, angle: 0)
        }
    }
    let stroke = NSBezierPath()
    stroke.move(to: CGPoint(x: chevron[0].0 * s, y: chevron[0].1 * s))
    stroke.line(to: CGPoint(x: chevron[1].0 * s, y: chevron[1].1 * s))
    stroke.line(to: CGPoint(x: chevron[2].0 * s, y: chevron[2].1 * s))
    stroke.lineWidth = chevronWidth * s
    stroke.lineCapStyle = .round
    stroke.lineJoinStyle = .round
    (monochrome ? NSColor.black : chevronColor).setStroke()
    stroke.stroke()
}

func writePNG(size: Int, to path: String, tile: Bool, monochrome: Bool) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not create bitmap \(size)px")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    drawLogo(in: CGRect(x: 0, y: 0, width: size, height: size), tile: tile, monochrome: monochrome)
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(path)")
    }
    try! data.write(to: URL(fileURLWithPath: path))
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icons"
let iconset = outDir + "/AppIcon.iconset"
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    writePNG(size: base, to: "\(iconset)/icon_\(base)x\(base).png", tile: true, monochrome: false)
    writePNG(size: base * 2, to: "\(iconset)/icon_\(base)x\(base)@2x.png", tile: true, monochrome: false)
}
writePNG(size: 18, to: outDir + "/MenuIcon.png", tile: false, monochrome: true)
writePNG(size: 36, to: outDir + "/MenuIcon@2x.png", tile: false, monochrome: true)
print("icons written to \(outDir)")
