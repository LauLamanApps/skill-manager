#!/usr/bin/env swift
// Generates the app icon (AppIcon.iconset PNGs) programmatically with AppKit.
// Usage: swift scripts/generate-icon.swift <output-iconset-dir>
// Then:  iconutil -c icns <output-iconset-dir> -o Resources/AppIcon.icns

import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: generate-icon.swift <output-iconset-dir>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// A layer of the stack: a rounded square rotated 45° and flattened vertically,
// centered on (512, cy) of the 1024pt canvas.
func layerPath(cy: CGFloat) -> NSBezierPath {
    let side: CGFloat = 420
    let path = NSBezierPath(
        roundedRect: NSRect(x: -side / 2, y: -side / 2, width: side, height: side),
        xRadius: 70, yRadius: 70
    )
    var t = AffineTransform()
    t.translate(x: 512, y: cy)
    t.scale(x: 1.0, y: 0.55)
    t.rotate(byDegrees: 45)
    path.transform(using: t)
    return path
}

// Four-point sparkle with concave sides, tips at distance r from (cx, cy).
func sparklePath(cx: CGFloat, cy: CGFloat, r: CGFloat) -> NSBezierPath {
    let pinch = 0.16 * r
    let tips = [CGPoint(x: 0, y: r), CGPoint(x: r, y: 0), CGPoint(x: 0, y: -r), CGPoint(x: -r, y: 0)]
    // Inner control point between tip i and tip i+1 (quadratic pulled toward center).
    let ctrls = [CGPoint(x: pinch, y: pinch), CGPoint(x: pinch, y: -pinch),
                 CGPoint(x: -pinch, y: -pinch), CGPoint(x: -pinch, y: pinch)]
    let path = NSBezierPath()
    path.move(to: CGPoint(x: cx + tips[0].x, y: cy + tips[0].y))
    for i in 0..<4 {
        let p0 = CGPoint(x: cx + tips[i].x, y: cy + tips[i].y)
        let p1 = CGPoint(x: cx + tips[(i + 1) % 4].x, y: cy + tips[(i + 1) % 4].y)
        let q = CGPoint(x: cx + ctrls[i].x, y: cy + ctrls[i].y)
        // Quadratic-as-cubic so NSBezierPath can draw it.
        let c1 = CGPoint(x: p0.x + 2 / 3 * (q.x - p0.x), y: p0.y + 2 / 3 * (q.y - p0.y))
        let c2 = CGPoint(x: p1.x + 2 / 3 * (q.x - p1.x), y: p1.y + 2 / 3 * (q.y - p1.y))
        path.curve(to: p1, controlPoint1: c1, controlPoint2: c2)
    }
    path.close()
    return path
}

func renderMaster() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Big Sur squircle grid: 824×824 icon shape centered on a 1024 canvas.
    let squircle = NSBezierPath(
        roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
        xRadius: 185, yRadius: 185
    )
    NSGradient(colors: [color(0x191D27), color(0x353D4F)])!.draw(in: squircle, angle: 90)
    // Faint top edge highlight.
    squircle.lineWidth = 4
    color(0xFFFFFF, 0.07).setStroke()
    squircle.stroke()

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()

    // Stack of skills: bottom → top.
    color(0x3C4557).setFill()
    layerPath(cy: 330).fill()
    color(0x5A657C).setFill()
    layerPath(cy: 460).fill()

    let top = layerPath(cy: 590)
    NSGradient(colors: [color(0xCE5F38), color(0xEC8F6A)])!.draw(in: top, angle: 90)
    top.lineWidth = 6
    color(0xFFFFFF, 0.25).setStroke()
    top.stroke()

    // AI sparkles, top-right.
    color(0xFFF3E8).setFill()
    sparklePath(cx: 760, cy: 760, r: 80).fill()
    color(0xFFF3E8, 0.85).setFill()
    sparklePath(cx: 650, cy: 850, r: 34).fill()

    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let masterRep = renderMaster()
let master = NSImage(size: NSSize(width: 1024, height: 1024))
master.addRepresentation(masterRep)

func writePNG(pixels: Int, name: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)
    ctx?.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    master.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: NSRect(x: 0, y: 0, width: 1024, height: 1024),
        operation: .copy, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: outDir.appendingPathComponent(name))
}

let entries: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (pixels, name) in entries {
    writePNG(pixels: pixels, name: name)
}
print("iconset written to \(outDir.path)")
