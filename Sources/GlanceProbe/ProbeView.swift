import AppKit

/// Borderless fullscreen window that can still take key events (for Esc/Space).
final class ProbeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Dark screen with a 3×3 grid of targets, one highlighted at a time.
final class ProbeView: NSView {
    var activeTarget: Int?
    var isCollecting = false
    var headline = ""
    var subhead = ""
    /// Fraction of the screen the grid is inset from each edge. Targets sit in from
    /// targets inset from screen edges.
    private let inset = 0.12

    override var isFlipped: Bool { true }  // target 0 is top-left

    func center(of target: Int) -> NSPoint {
        let fractions = [inset, 0.5, 1 - inset]
        return NSPoint(
            x: bounds.width * fractions[target % 3],
            y: bounds.height * fractions[target / 3]
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        for target in 0..<9 {
            let active = target == activeTarget
            let radius: CGFloat = active ? (isCollecting ? 34 : 24) : 9
            let color: NSColor = active
                ? (isCollecting ? .systemGreen : .systemYellow)
                : NSColor.white.withAlphaComponent(0.18)
            color.setFill()
            let p = center(of: target)
            NSBezierPath(ovalIn: NSRect(
                x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2
            )).fill()

            if active && isCollecting {
                // A small dark pupil gives the eye something exact to fix on.
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)).fill()
            }
        }

        drawText(headline, size: 22, y: bounds.midY - 40, color: .white)
        drawText(subhead, size: 14, y: bounds.midY + 2, color: NSColor.white.withAlphaComponent(0.55))
    }

    private func drawText(_ s: String, size: CGFloat, y: CGFloat, color: NSColor) {
        guard !s.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
        ]
        let text = NSAttributedString(string: s, attributes: attributes)
        let width = text.size().width
        text.draw(at: NSPoint(x: bounds.midX - width / 2, y: y))
    }
}
