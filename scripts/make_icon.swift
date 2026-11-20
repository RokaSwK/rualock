// Draws the app icon: the black notch shape with the green "watching" dot and ring.
//   swift scripts/make_icon.swift build/AppIcon.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024
    // macOS icon grid: 824pt body centred in 1024, radius ~185.
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * u, yRadius: 185 * u)
    NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.18, blue: 0.20, alpha: 1),
               ending: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1))!.draw(in: squircle, angle: -90)

    // The notch, hanging from the top edge, with the island growing out of its right side.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSColor.black.setFill()
    let notch = NSBezierPath(roundedRect: NSRect(x: 250 * u, y: 600 * u, width: 524 * u, height: 400 * u), xRadius: 90 * u, yRadius: 90 * u)
    notch.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Lens on the left, status dot on the right.
    NSColor(srgbRed: 0.14, green: 0.15, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 390 * u, y: 712 * u, width: 76 * u, height: 76 * u)).fill()
    let green = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
    let c = NSPoint(x: 620 * u, y: 750 * u)
    green.withAlphaComponent(0.28).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 72 * u, y: c.y - 72 * u, width: 144 * u, height: 144 * u)).fill()
    green.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 40 * u, y: c.y - 40 * u, width: 80 * u, height: 80 * u)).fill()

    // A padlock below: what happens when you walk away.
    let white = NSColor(white: 0.92, alpha: 1)
    let shackle = NSBezierPath()
    shackle.lineWidth = 34 * u
    shackle.lineCapStyle = .round
    shackle.move(to: NSPoint(x: 432 * u, y: 380 * u))
    shackle.line(to: NSPoint(x: 432 * u, y: 440 * u))
    shackle.appendArc(withCenter: NSPoint(x: 512 * u, y: 440 * u), radius: 80 * u, startAngle: 180, endAngle: 0, clockwise: true)
    shackle.line(to: NSPoint(x: 592 * u, y: 380 * u))
    white.setStroke()
    shackle.stroke()
    white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 382 * u, y: 200 * u, width: 260 * u, height: 200 * u), xRadius: 36 * u, yRadius: 36 * u).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for k in scales {
        let name = k == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try! render(pt * k).write(to: out.appendingPathComponent(name))
    }
}
