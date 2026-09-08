#!/usr/bin/env swift
// Generates the DMG's mounted-volume icon: the classic macOS external-drive
// shape (rounded slab with a darker foot band, modeled on the system's own
// generic-disk artwork) in the app's navy/orange palette, logo on the face.
// Usage: swift scripts/generate-volume-icon.swift <output-iconset-dir>
// Then:  iconutil -c icns <output-iconset-dir> -o Resources/VolumeIcon.icns

import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: generate-volume-icon.swift <output-iconset-dir>\n".data(using: .utf8)!)
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

// Same diamond-stack mark as AppIcon, scaled to fit wherever it's stamped.
func layerPath(cx: CGFloat, cy: CGFloat, side: CGFloat) -> NSBezierPath {
    let path = NSBezierPath(
        roundedRect: NSRect(x: -side / 2, y: -side / 2, width: side, height: side),
        xRadius: side * 0.167, yRadius: side * 0.167
    )
    var t = AffineTransform()
    t.translate(x: cx, y: cy)
    t.scale(x: 1.0, y: 0.55)
    t.rotate(byDegrees: 45)
    path.transform(using: t)
    return path
}

func sparklePath(cx: CGFloat, cy: CGFloat, r: CGFloat) -> NSBezierPath {
    let pinch = 0.16 * r
    let tips = [CGPoint(x: 0, y: r), CGPoint(x: r, y: 0), CGPoint(x: 0, y: -r), CGPoint(x: -r, y: 0)]
    let ctrls = [CGPoint(x: pinch, y: pinch), CGPoint(x: pinch, y: -pinch),
                 CGPoint(x: -pinch, y: -pinch), CGPoint(x: -pinch, y: pinch)]
    let path = NSBezierPath()
    path.move(to: CGPoint(x: cx + tips[0].x, y: cy + tips[0].y))
    for i in 0..<4 {
        let p0 = CGPoint(x: cx + tips[i].x, y: cy + tips[i].y)
        let p1 = CGPoint(x: cx + tips[(i + 1) % 4].x, y: cy + tips[(i + 1) % 4].y)
        let q = CGPoint(x: cx + ctrls[i].x, y: cy + ctrls[i].y)
        let c1 = CGPoint(x: p0.x + 2 / 3 * (q.x - p0.x), y: p0.y + 2 / 3 * (q.y - p0.y))
        let c2 = CGPoint(x: p1.x + 2 / 3 * (q.x - p1.x), y: p1.y + 2 / 3 * (q.y - p1.y))
        path.curve(to: p1, controlPoint1: c1, controlPoint2: c2)
    }
    path.close()
    return path
}

func drawLogo(cx: CGFloat, cy: CGFloat, scale: CGFloat) {
    color(0x3C4557).setFill()
    layerPath(cx: cx, cy: cy - 30 * scale, side: 300 * scale).fill()
    color(0x5A657C).setFill()
    layerPath(cx: cx, cy: cy + 20 * scale, side: 300 * scale).fill()
    let top = layerPath(cx: cx, cy: cy + 70 * scale, side: 300 * scale)
    NSGradient(colors: [color(0xCE5F38), color(0xEC8F6A)])!.draw(in: top, angle: 90)
    top.lineWidth = 5 * scale
    color(0xFFFFFF, 0.25).setStroke()
    top.stroke()
    color(0xFFF3E8).setFill()
    sparklePath(cx: cx + 140 * scale, cy: cy + 170 * scale, r: 40 * scale).fill()
    color(0xFFF3E8, 0.85).setFill()
    sparklePath(cx: cx + 70 * scale, cy: cy + 210 * scale, r: 20 * scale).fill()
}

func renderMaster() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let width: CGFloat = 660
    let height: CGFloat = 900
    let x0: CGFloat = (1024 - width) / 2
    let y0: CGFloat = (1024 - height) / 2
    let radius: CGFloat = 130
    let footHeight: CGFloat = 150

    let body = NSBezierPath(roundedRect: NSRect(x: x0, y: y0, width: width, height: height), xRadius: radius, yRadius: radius)
    NSGradient(colors: [color(0x454F68), color(0x1B1F29)])!.draw(in: body, angle: -90)
    body.lineWidth = 3
    color(0xFFFFFF, 0.10).setStroke()
    body.stroke()

    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()

    // Foot band across the bottom, square-topped, rounded to match the body's
    // bottom corners — the detail that reads instantly as "this is a drive".
    let foot = NSBezierPath(roundedRect: NSRect(x: x0, y: y0, width: width, height: footHeight + radius), xRadius: radius, yRadius: radius)
    color(0x0B0D12).setFill()
    foot.fill()
    let footTopLine = NSBezierPath()
    footTopLine.move(to: CGPoint(x: x0, y: y0 + footHeight))
    footTopLine.line(to: CGPoint(x: x0 + width, y: y0 + footHeight))
    footTopLine.lineWidth = 2
    color(0xFFFFFF, 0.08).setStroke()
    footTopLine.stroke()

    // Glossy top highlight on the main body.
    let gloss = NSRect(x: x0, y: y0 + height - 260, width: width, height: 260)
    NSGradient(colors: [color(0xFFFFFF, 0.12), color(0xFFFFFF, 0.0)])!.draw(in: gloss, angle: -90)

    drawLogo(cx: x0 + width / 2, cy: y0 + footHeight + (height - footHeight) / 2 - 40, scale: 0.62)

    NSGraphicsContext.current?.restoreGraphicsState()

    // Small indicator dot on the foot, the classic generic-disk-icon detail.
    let dotR: CGFloat = 14
    let dot = NSBezierPath(ovalIn: NSRect(
        x: x0 + width - 60 - dotR, y: y0 + footHeight / 2 - dotR, width: dotR * 2, height: dotR * 2
    ))
    color(0xFFFFFF, 0.5).setFill()
    dot.fill()

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
