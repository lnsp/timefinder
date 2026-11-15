// Renders the app icon PNGs (original vector artwork — no SF Symbols, which Apple's license
// forbids in app icons).
//
// Usage: swift scripts/make-icon.swift [output-dir]
//        (default: Resources/Assets.xcassets/AppIcon.appiconset)
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws in a 1024×1024 design space, scaled to `size`.
func render(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Body: macOS icon grid (824pt square, ~185pt corner radius) with a soft drop shadow.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    color(0x0B3C5D).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x1FB5A3), color(0x0E6E8C), color(0x0B3C5D)])!.draw(in: body, angle: -90)

    // Snapshot stack: three receding cards behind the folder.
    for (index, alpha) in [(2, 0.22), (1, 0.38)] as [(CGFloat, CGFloat)] {
        let inset = 40 * index
        let card = NSRect(x: 252 + inset, y: 330 + 62 * index, width: 520 - 2 * inset, height: 330)
        color(0xFFFFFF, alpha).setFill()
        NSBezierPath(roundedRect: card, xRadius: 38, yRadius: 38).fill()
    }

    // Front folder (tab + body), white with a faint top highlight.
    let folder = NSBezierPath()
    folder.move(to: NSPoint(x: 252, y: 300))
    folder.line(to: NSPoint(x: 252, y: 600))
    folder.appendArc(withCenter: NSPoint(x: 290, y: 600), radius: 38, startAngle: 180, endAngle: 90, clockwise: true)
    folder.line(to: NSPoint(x: 430, y: 638))
    folder.line(to: NSPoint(x: 470, y: 600))
    folder.line(to: NSPoint(x: 734, y: 600))
    folder.appendArc(withCenter: NSPoint(x: 734, y: 562), radius: 38, startAngle: 90, endAngle: 0, clockwise: true)
    folder.line(to: NSPoint(x: 772, y: 338))
    folder.appendArc(withCenter: NSPoint(x: 734, y: 338), radius: 38, startAngle: 0, endAngle: -90, clockwise: true)
    folder.line(to: NSPoint(x: 290, y: 300))
    folder.appendArc(withCenter: NSPoint(x: 290, y: 338), radius: 38, startAngle: -90, endAngle: -180, clockwise: true)
    folder.close()
    NSGradient(colors: [color(0xFFFFFF), color(0xE3F2F5)])!.draw(in: folder, angle: -90)

    // Clock with a counter-clockwise "back in time" arrow, centred on the folder.
    let center = NSPoint(x: 512, y: 450)
    let ink = color(0x0E6E8C)
    ink.setStroke()
    ink.setFill()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: 104, startAngle: 135, endAngle: 420, clockwise: false)
    arc.lineWidth = 30
    arc.lineCapStyle = .round
    arc.stroke()

    // Arrowhead at the arc's open end (120°), pointing along the counter-clockwise tangent.
    let theta = 120 * CGFloat.pi / 180
    let anchor = NSPoint(x: center.x + 104 * cos(theta), y: center.y + 104 * sin(theta))
    let tangent = NSPoint(x: -sin(theta), y: cos(theta))   // direction of counter-clockwise travel
    let normal = NSPoint(x: cos(theta), y: sin(theta))     // radial
    let head = NSBezierPath()
    head.move(to: NSPoint(x: anchor.x + tangent.x * 46, y: anchor.y + tangent.y * 46))
    head.line(to: NSPoint(x: anchor.x - tangent.x * 14 + normal.x * 48, y: anchor.y - tangent.y * 14 + normal.y * 48))
    head.line(to: NSPoint(x: anchor.x - tangent.x * 14 - normal.x * 48, y: anchor.y - tangent.y * 14 - normal.y * 48))
    head.close()
    head.fill()

    // Hands: 12 o'clock and ~4 o'clock.
    let hands = NSBezierPath()
    hands.move(to: NSPoint(x: center.x, y: center.y + 62))
    hands.line(to: center)
    hands.line(to: NSPoint(x: center.x + 48, y: center.y - 30))
    hands.lineWidth = 26
    hands.lineCapStyle = .round
    hands.lineJoinStyle = .round
    hands.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: CGFloat(base * scale)).write(to: outDir.appendingPathComponent(name))
    }
}
print("Wrote icons to \(outDir.path)")
