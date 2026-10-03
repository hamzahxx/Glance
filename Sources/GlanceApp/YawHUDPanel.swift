import AppKit
import GlanceCore

/// Small floating readout of head yaw over the display bands, and of whatever
/// is refusing to move. It must never take focus: Glance exists to stop focus
/// landing in the wrong place, and a HUD that grabbed it would be that bug.
///
/// Self-contained so the setup guide can show the same panel.
@MainActor
final class YawHUDPanel {
    struct Frame: Equatable {
        var model: HUDModel
        var bands: [YawClassifier.Band]
        var scale: ClosedRange<Double>
        var seamMargin: Double
    }

    /// 15 fps is plenty for a needle; frames arrive at 30.
    private static let minInterval: TimeInterval = 1.0 / 15

    private let panel: NonActivatingPanel
    private let view = HUDView()
    private var pending: Frame?
    private var lastDraw: TimeInterval = 0
    private var scheduled = false

    init() {
        let size = NSSize(width: 320, height: 90)
        panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true
        )
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view.frame = NSRect(origin: .zero, size: size)
        panel.contentView = view
    }

    var isVisible: Bool { panel.isVisible }

    /// Top-right of the main display. orderFrontRegardless shows the panel
    /// without activating Glance.
    func show() {
        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 12, y: visible.maxY - 12))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Redraws only on change, at most 15 times a second.
    func update(_ frame: Frame) {
        guard frame != (pending ?? view.frameModel) else { return }
        pending = frame
        let wait = lastDraw + Self.minInterval - ProcessInfo.processInfo.systemUptime
        if wait <= 0 {
            draw()
        } else if !scheduled {
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated {
                    self?.scheduled = false
                    self?.draw()
                }
            }
        }
    }

    private func draw() {
        guard let pending else { return }
        self.pending = nil
        lastDraw = ProcessInfo.processInfo.systemUptime
        view.frameModel = pending
        view.needsDisplay = true
    }
}

/// Refuses key and main status, so the HUD can never become the focused window.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HUDView: NSView {
    var frameModel: YawHUDPanel.Frame?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let outer = bounds.insetBy(dx: 1, dy: 1)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: outer, xRadius: 10, yRadius: 10).fill()
        guard let f = frameModel else { return }

        let track = NSRect(x: 12, y: 10, width: bounds.width - 24, height: 34)
        let span = f.scale.upperBound - f.scale.lowerBound
        func x(_ yaw: Double) -> CGFloat {
            let clamped = min(max(yaw, f.scale.lowerBound), f.scale.upperBound)
            return track.minX + CGFloat((clamped - f.scale.lowerBound) / span) * track.width
        }

        // Bands, alternating shades, each labelled with its display.
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        if f.bands.isEmpty {
            NSColor.quaternaryLabelColor.setFill()
            track.fill()
        }
        for (i, band) in f.bands.enumerated() {
            let rect = NSRect(x: x(band.lower), y: track.minY, width: x(band.upper) - x(band.lower), height: track.height)
            (i.isMultiple(of: 2) ? NSColor.quaternaryLabelColor : NSColor.tertiaryLabelColor).setFill()
            rect.fill()
            let label = NSAttributedString(string: band.name, attributes: labelAttrs)
            let size = label.size()
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY + 2))
        }

        // Seams: hatched where classify refuses.
        for band in f.bands.dropFirst() {
            let seam = NSRect(x: x(band.lower - f.seamMargin), y: track.minY,
                              width: x(band.lower + f.seamMargin) - x(band.lower - f.seamMargin), height: track.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: seam).addClip()
            let hatch = NSBezierPath()
            var hx = seam.minX - track.height
            while hx < seam.maxX {
                hatch.move(to: NSPoint(x: hx, y: track.maxY))
                hatch.line(to: NSPoint(x: hx + track.height, y: track.minY))
                hx += 4
            }
            NSColor.systemOrange.withAlphaComponent(0.6).setStroke()
            hatch.lineWidth = 1
            hatch.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Needle.
        if let needle = f.model.needle {
            let nx = track.minX + CGFloat(needle) * track.width
            NSColor.controlAccentColor.setFill()
            NSRect(x: nx - 1.5, y: track.minY - 4, width: 3, height: track.height + 8).fill()
        }

        // Dwell fill.
        let bar = NSRect(x: track.minX, y: track.maxY + 6, width: track.width, height: 4)
        NSColor.quaternaryLabelColor.setFill()
        bar.fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(f.model.dwellFraction), height: bar.height).fill()

        // The one line that says why.
        NSAttributedString(string: f.model.text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor,
        ]).draw(at: NSPoint(x: track.minX, y: bar.maxY + 6))
    }
}
