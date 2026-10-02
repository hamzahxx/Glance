import AppKit
import Foundation

// Renders Glance's app icon at every size macOS asks for.
//
// The mark is the calibration drop: a circle at rest, a teardrop in flight.
// Using the same shape the app animates ties the icon to the one thing a user
// actually watches while setting Glance up.

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Glance.iconset"
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

/// The convex hull of two circles — see Blob.path in CalibrationView.
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

func render(size S: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Apple's icon grid: artwork inset from the canvas, continuous corners at
    // roughly 22% of the square's side.
    let inset = S * 0.085
    let square = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let squircle = NSBezierPath(roundedRect: square, xRadius: square.width * 0.2237,
                                yRadius: square.width * 0.2237)

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.27, green: 0.33, blue: 0.62, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.17, alpha: 1),
    ])!.draw(in: square, angle: -90)

    // Travel runs along one axis: the drop leads, a dotted wake follows. The
    // whole composition is built around this vector so it stays centred.
    let travel = CGVector(dx: 0.80, dy: 0.60)   // normalised, up and to the right
    let reach = S * 0.165
    let centre = NSPoint(x: square.midX - S * 0.012, y: square.midY - S * 0.010)
    let head = NSPoint(x: centre.x + travel.dx * reach, y: centre.y + travel.dy * reach)
    let tail = NSPoint(x: centre.x - travel.dx * reach, y: centre.y - travel.dy * reach)

    // The wake: three fading dots along the path already travelled.
    for (index, step) in [1.45, 1.95, 2.40].enumerated() {
        let r = S * (0.030 - Double(index) * 0.007)
        let p = NSPoint(x: centre.x - travel.dx * reach * step, y: centre.y - travel.dy * reach * step)
        NSColor.white.withAlphaComponent(0.34 - Double(index) * 0.09).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
    }
    let glow = NSShadow()
    glow.shadowColor = NSColor.white.withAlphaComponent(0.5)
    glow.shadowBlurRadius = S * 0.055
    glow.shadowOffset = .zero
    glow.set()
    NSColor.white.setFill()
    drop(head: head, headRadius: S * 0.163, tail: tail, tailRadius: S * 0.038).fill()

    NSGraphicsContext.current?.restoreGraphicsState()

    // A hairline edge so the icon reads against both light and dark backdrops.
    NSColor.white.withAlphaComponent(0.13).setStroke()
    squircle.lineWidth = max(1, S * 0.006)
    squircle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = CGFloat(size * scale)
    guard let data = render(size: pixels).representation(using: .png, properties: [:]) else { continue }
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(size)x\(size)\(suffix).png"
    try data.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(name))
    print("  \(name)  \(Int(pixels))px")
}
print("wrote \(outputDirectory)")
