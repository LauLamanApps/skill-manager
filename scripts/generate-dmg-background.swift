#!/usr/bin/env swift
// Generates the DMG background image programmatically with AppKit, reusing the
// app icon's palette (dark navy squircle, orange accent) so the installer window
// matches the app icon.
// Usage: swift scripts/generate-dmg-background.swift <output.png> [icon.icns]

import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: generate-dmg-background.swift <output.png> [icon.icns]\n".data(using: .utf8)!)
    exit(1)
}
let outURL = URL(fileURLWithPath: args[1])
let iconPath = args.count >= 3 ? args[2] : "Resources/AppIcon.icns"

// Matches the Finder window bounds and icon layout set by make-dmg.sh's AppleScript.
let width = 660
let height = 400
let iconSize: CGFloat = 128
let appFinderPos = CGPoint(x: 180, y: 170)
let appsFinderPos = CGPoint(x: 480, y: 170)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Finder places icons top-down; our canvas is bottom-left origin.
func fromFinder(_ p: CGPoint) -> CGPoint {
    CGPoint(x: p.x, y: CGFloat(height) - p.y)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)
ctx?.imageInterpolation = .high
NSGraphicsContext.current = ctx

let full = NSRect(x: 0, y: 0, width: width, height: height)
NSGradient(colors: [color(0x191D27), color(0x2B3142)])!.draw(in: full, angle: -90)

let appCenter = fromFinder(appFinderPos)
let appsCenter = fromFinder(appsFinderPos)

// Arrow from the app icon to the Applications alias.
let startX = appCenter.x + iconSize / 2 + 10
let endX = appsCenter.x - iconSize / 2 - 18
let shaft = NSBezierPath()
shaft.move(to: CGPoint(x: startX, y: appCenter.y))
shaft.line(to: CGPoint(x: endX, y: appCenter.y))
shaft.lineWidth = 5
color(0xEC8F6A, 0.85).setStroke()
shaft.stroke()

let head = NSBezierPath()
head.move(to: CGPoint(x: endX, y: appCenter.y + 14))
head.line(to: CGPoint(x: endX + 18, y: appCenter.y))
head.line(to: CGPoint(x: endX, y: appCenter.y - 14))
head.close()
color(0xEC8F6A, 0.85).setFill()
head.fill()

// The app icon itself, read from the built .icns so it always matches the app.
if let icon = NSImage(contentsOfFile: iconPath) {
    icon.draw(
        in: NSRect(x: appCenter.x - iconSize / 2, y: appCenter.y - iconSize / 2, width: iconSize, height: iconSize),
        from: .zero, operation: .sourceOver, fraction: 1
    )
}

// The live system icon for /Applications, so it matches whatever macOS renders in Finder.
let appsIcon = NSWorkspace.shared.icon(forFile: "/Applications")
appsIcon.draw(
    in: NSRect(x: appsCenter.x - iconSize / 2, y: appsCenter.y - iconSize / 2, width: iconSize, height: iconSize),
    from: .zero, operation: .sourceOver, fraction: 1
)

// Finder draws each icon's filename label just below it in the system label
// color (black in Light mode), which our dark background makes hard to read.
// A light pill behind the label spot keeps it legible regardless of appearance.
// Where exactly Finder renders that label (relative to the position we set on
// the item) isn't reliably predictable at build time — it's drifted both left
// and right of the icon's x across runs. Rather than chase an exact offset,
// the pill is sized generously in both directions so normal drift stays
// comfortably inside it instead of needing a pixel-perfect match.
let pillWidth: CGFloat = 170
let pillHeight: CGFloat = 24
func labelPill(center: CGPoint) {
    let pillRect = NSRect(
        x: center.x - pillWidth / 2, y: center.y - pillHeight / 2,
        width: pillWidth, height: pillHeight
    )
    let pill = NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2, yRadius: pillHeight / 2)
    color(0xFFFFFF, 0.92).setFill()
    pill.fill()
}
// Vertically centered where Finder puts the single-line label: icon bottom + gap + half line height.
let labelOffset = iconSize / 2 + 10 + pillHeight / 2
labelPill(center: CGPoint(x: appCenter.x, y: appCenter.y - labelOffset))
labelPill(center: CGPoint(x: appsCenter.x, y: appsCenter.y - labelOffset))

let caption = "Drag to Applications to install"
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: color(0xFFF3E8, 0.8),
]
let captionSize = caption.size(withAttributes: attrs)
caption.draw(at: CGPoint(x: (CGFloat(width) - captionSize.width) / 2, y: 70), withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: outURL)
print("dmg background written to \(outURL.path)")
