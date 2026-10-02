import AppKit
import Foundation

// Background art for the disk image window.
//
// Finder places icons in window coordinates with the origin at the top left;
// this draws with the origin at the bottom left, so anything positioned against
// an icon is mirrored vertically here. The icon row sits at window y=190, which
// is image y = height - 190.

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let windowWidth: CGFloat = 660
let windowHeight: CGFloat = 400
let iconRowFromTop: CGFloat = 190

func drop(head: NSPoint, headRadius: CGFloat, tail: NSPoint, tailRadius: CGFloat) -> NSBezierPath {
    let dx = tail.x - head.x, dy = tail.y - head.y
    let distance = (dx * dx + dy * dy).squareRoot()
    guard distance > 0.5, distance > abs(headRadius - tailRadius) else {
        return NSBezierPath(ovalIn: NSRect(x: head.x - headRadius, y: head.y - headRadius,
                                           width: headRadius * 2, height: headRadius * 2))
    }
    let angle = atan2(dy, dx)
    let alpha = acos((headRadius - tailRadius) / distance)
    let degrees = 180 / CGFloat.pi
    let path = NSBezierPath()
    path.appendArc(withCenter: head, radius: headRadius,
                   startAngle: (angle + alpha) * degrees, endAngle: (angle - alpha) * degrees, clockwise: false)
    path.appendArc(withCenter: tail, radius: tailRadius,
                   startAngle: (angle - alpha) * degrees, endAngle: (angle + alpha) * degrees, clockwise: false)
    path.close()
    return path
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, centredAt p: NSPoint, scale: CGFloat) {
    let attributed = NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size * scale, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .kern: 0.6 * scale,
    ])
    let bounds = attributed.size()
    attributed.draw(at: NSPoint(x: p.x - bounds.width / 2, y: p.y))
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let W = windowWidth * scale, H = windowHeight * scale
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let full = NSRect(x: 0, y: 0, width: W, height: H)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.145, green: 0.173, blue: 0.306, alpha: 1),
        NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.118, alpha: 1),
    ])!.draw(in: full, angle: -90)

    let rowY = H - iconRowFromTop * scale   // the vertical centre of both icons

    // A drop travelling from the app toward the Applications alias: the gesture
    // the window is asking for, drawn as the app's own mark.
    let from = NSPoint(x: 268 * scale, y: rowY)
    let to = NSPoint(x: 398 * scale, y: rowY)
    let glow = NSShadow()
    glow.shadowColor = NSColor.white.withAlphaComponent(0.35)
    glow.shadowBlurRadius = 10 * scale
    glow.shadowOffset = .zero
    NSGraphicsContext.current?.saveGraphicsState()
    glow.set()
    NSColor.white.withAlphaComponent(0.92).setFill()
    drop(head: to, headRadius: 11 * scale, tail: from, tailRadius: 2.5 * scale).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    for (index, step) in [0.0, 1.0, 2.0].enumerated() {
        let r = (3.4 - step * 0.8) * scale
        let p = NSPoint(x: from.x - (14 + step * 15) * scale, y: rowY)
        NSColor.white.withAlphaComponent(0.30 - Double(index) * 0.08).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
    }

    text("Glance", size: 23, weight: .semibold, alpha: 0.95,
         centredAt: NSPoint(x: W / 2, y: H - 62 * scale), scale: scale)
    text("Drag Glance into your Applications folder", size: 12, weight: .regular, alpha: 0.46,
         centredAt: NSPoint(x: W / 2, y: H - 88 * scale), scale: scale)
    text("First launch: right-click Glance → Open, or System Settings › Privacy & Security › Open Anyway",
         size: 10, weight: .regular, alpha: 0.30,
         centredAt: NSPoint(x: W / 2, y: 30 * scale), scale: scale)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for scale in [CGFloat(1), CGFloat(2)] {
    guard let data = render(scale: scale).representation(using: .png, properties: [:]) else { continue }
    let name = scale == 1 ? "dmg-background.png" : "dmg-background@2x.png"
    try data.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(name))
    print("  \(name)")
}
