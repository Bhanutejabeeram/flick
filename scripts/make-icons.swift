// Generates all app icons from the master logo (assets/flick.png):
//   AppIcon.iconset/  (all sizes, rounded tile, for iconutil)
//   MenuIcon.png / MenuIcon@2x.png  (monochrome template for the menu bar,
//   cropped to the glyph and alpha-masked from luminance so it stays crisp
//   at 18pt and adapts to light/dark menu bars)
// Usage: swift scripts/make-icons.swift <source.png> <output-dir>
import AppKit

guard CommandLine.arguments.count >= 3 else {
    fatalError("usage: make-icons.swift <source.png> <output-dir>")
}
let sourcePath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]
guard let source = NSImage(contentsOfFile: sourcePath) else {
    fatalError("cannot read \(sourcePath)")
}

func render(width: Int, height: Int, draw: (CGRect) -> Void) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not create bitmap \(width)x\(height)")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    draw(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(path)")
    }
    try! data.write(to: URL(fileURLWithPath: path))
}

// ── App icon: the logo clipped to macOS's rounded tile ─────────────────────
func appIcon(size: Int) -> NSBitmapImageRep {
    render(width: size, height: size) { rect in
        let s = rect.width
        let inset = s * 0.06
        let tile = rect.insetBy(dx: inset, dy: inset)
        NSBezierPath(roundedRect: tile, xRadius: s * 0.20, yRadius: s * 0.20).addClip()
        source.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

// ── Menu-bar template: crop to glyph, alpha from luminance ─────────────────

/// Bounding box of the bright glyph in unit coordinates (bottom-left origin),
/// padded and squared so the mark scales into 18pt without distortion.
func glyphBox() -> CGRect {
    let probeSize = 256
    let probe = render(width: probeSize, height: probeSize) { rect in
        source.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
    }
    var minX = probeSize, minY = probeSize, maxX = -1, maxY = -1
    for row in 0..<probeSize {
        for col in 0..<probeSize {
            guard let c = probe.colorAt(x: col, y: row) else { continue }
            let lum = (c.redComponent + c.greenComponent + c.blueComponent) / 3
            if lum > 0.35 {
                minX = min(minX, col); maxX = max(maxX, col)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
    }
    guard maxX >= 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
    // Bitmap rows are top-down; unit coordinates are bottom-up.
    var box = CGRect(x: CGFloat(minX) / CGFloat(probeSize),
                     y: CGFloat(probeSize - 1 - maxY) / CGFloat(probeSize),
                     width: CGFloat(maxX - minX + 1) / CGFloat(probeSize),
                     height: CGFloat(maxY - minY + 1) / CGFloat(probeSize))
    // Square it around the centre, with a little breathing room.
    let side = min(1.0, max(box.width, box.height) * 1.12)
    box = CGRect(x: max(0, min(1 - side, box.midX - side / 2)),
                 y: max(0, min(1 - side, box.midY - side / 2)),
                 width: side, height: side)
    return box
}

func menuTemplate(size: Int, cropUnit: CGRect) -> NSBitmapImageRep {
    let crop = CGRect(x: cropUnit.minX * source.size.width,
                      y: cropUnit.minY * source.size.height,
                      width: cropUnit.width * source.size.width,
                      height: cropUnit.height * source.size.height)
    let rep = render(width: size, height: size) { rect in
        source.draw(in: rect, from: crop, operation: .copy, fraction: 1)
    }
    // Template images are black + alpha; macOS recolors them. Bright pixels
    // of the logo become opaque, the dark background becomes transparent.
    guard let data = rep.bitmapData else { fatalError("no bitmap data") }
    let bytesPerRow = rep.bytesPerRow, samples = rep.samplesPerPixel
    for row in 0..<size {
        let rowPtr = data + row * bytesPerRow
        for col in 0..<size {
            let p = rowPtr + col * samples
            let lum = (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3
            p[0] = 0; p[1] = 0; p[2] = 0
            p[3] = UInt8(lum)
        }
    }
    return rep
}

// ── Emit ───────────────────────────────────────────────────────────────────
let iconset = outDir + "/AppIcon.iconset"
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    writePNG(appIcon(size: base), to: "\(iconset)/icon_\(base)x\(base).png")
    writePNG(appIcon(size: base * 2), to: "\(iconset)/icon_\(base)x\(base)@2x.png")
}
let box = glyphBox()
writePNG(menuTemplate(size: 18, cropUnit: box), to: outDir + "/MenuIcon.png")
writePNG(menuTemplate(size: 36, cropUnit: box), to: outDir + "/MenuIcon@2x.png")
print("icons written to \(outDir) (glyph box \(box))")
