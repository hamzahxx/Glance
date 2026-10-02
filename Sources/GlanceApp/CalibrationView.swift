import AppKit
import GlanceCore

/// Borderless fullscreen window that can still take key events.
final class CalibrationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One of these covers every display during calibration, so the whole desk goes
/// dark at once rather than one screen at a time.
///
/// All positions are in **screen** coordinates and converted per window at draw
/// time. That is what lets a single blob travel from one display to the next and
/// be drawn continuously by two different windows.
final class CalibrationView: NSView {
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Target positions on *this* display, in screen coordinates.
    var targets: [NSPoint] = []
    var activeTarget: Int?

    /// Blob head and tail, in screen coordinates. Nil hides it.
    var blobHead: NSPoint?
    var blobTail: NSPoint?
    var headRadius: CGFloat = 26
    var tailRadius: CGFloat = 9
    /// 0...1 — fills a ring around the blob while samples are collected.
    var collectProgress: Double = 0

    var headline = ""
    var subhead = ""
    /// Only the display being calibrated carries the text.
    var showsText = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onBegin?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) { onBegin?() }

    private func local(_ screenPoint: NSPoint) -> NSPoint {
        window?.convertPoint(fromScreen: screenPoint) ?? screenPoint
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        for (index, target) in targets.enumerated() {
            let p = local(target)
            let isActive = index == activeTarget
            let radius: CGFloat = isActive ? 22 : 15
            NSColor.white.withAlphaComponent(isActive ? 0.30 : 0.12).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = isActive ? 2 : 1
            ring.stroke()
        }

        if let head = blobHead {
            drawBlob(head: local(head), tail: local(blobTail ?? head))
        }

        if showsText {
            draw(headline, size: 21, weight: .medium, y: bounds.midY - 120, alpha: 1)
            draw(subhead, size: 13, weight: .regular, y: bounds.midY - 152, alpha: 0.5)
        }
    }

    private func drawBlob(head: NSPoint, tail: NSPoint) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 26
        shadow.shadowOffset = .zero

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.setFill()
        Blob.path(head: head, headRadius: headRadius, tail: tail, tailRadius: tailRadius).fill()
        NSGraphicsContext.restoreGraphicsState()

        // A dark pupil gives the eye something exact to fix on.
        NSColor.black.withAlphaComponent(0.85).setFill()
        let pupil: CGFloat = max(3, headRadius * 0.16)
        NSBezierPath(ovalIn: NSRect(x: head.x - pupil, y: head.y - pupil,
                                    width: pupil * 2, height: pupil * 2)).fill()

        guard collectProgress > 0 else { return }
        let ringRadius = headRadius + 14
        let ring = NSBezierPath()
        ring.appendArc(withCenter: head, radius: ringRadius,
                       startAngle: 90, endAngle: 90 - 360 * CGFloat(collectProgress), clockwise: true)
        ring.lineWidth = 3
        NSColor.systemGreen.withAlphaComponent(0.9).setStroke()
        ring.stroke()
    }

    private func draw(_ s: String, size: CGFloat, weight: NSFont.Weight, y: CGFloat, alpha: CGFloat) {
        guard !s.isEmpty else { return }
        let text = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ])
        text.draw(at: NSPoint(x: bounds.midX - text.size().width / 2, y: y))
    }
}

/// The convex hull of two circles: a circle when still, a teardrop when moving.
///
/// The tail trails the head by an amount proportional to speed, so the shape
/// stretches as it leaves a target and rounds off as it arrives — the way a drop
/// of water behaves, rather than a dot being switched on somewhere else.
enum Blob {
    static func path(head: NSPoint, headRadius: CGFloat, tail: NSPoint, tailRadius: CGFloat) -> NSBezierPath {
        let dx = tail.x - head.x
        let dy = tail.y - head.y
        let distance = (dx * dx + dy * dy).squareRoot()

        // Too close, or one circle swallows the other: just draw the head.
        guard distance > 0.5, distance > abs(headRadius - tailRadius) else {
            return NSBezierPath(ovalIn: NSRect(x: head.x - headRadius, y: head.y - headRadius,
                                               width: headRadius * 2, height: headRadius * 2))
        }

        let angle = atan2(dy, dx)
        let alpha = acos((headRadius - tailRadius) / distance)
        let degrees = 180 / CGFloat.pi

        let path = NSBezierPath()
        // The far side of the head, the two external tangents, then the far side
        // of the tail — the outline of the hull.
        path.appendArc(withCenter: head, radius: headRadius,
                       startAngle: (angle + alpha) * degrees,
                       endAngle: (angle - alpha) * degrees,
                       clockwise: false)
        path.appendArc(withCenter: tail, radius: tailRadius,
                       startAngle: (angle - alpha) * degrees,
                       endAngle: (angle + alpha) * degrees,
                       clockwise: false)
        path.close()
        return path
    }
}
