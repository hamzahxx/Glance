import AppKit
import GlanceCore
import QuartzCore

/// Walks every (pass, display, target) combination, collecting yaw while the
/// user looks at each target, then builds a profile.
///
/// Two passes, not one: the profile records a *held-out* separability score, and
/// scoring the same samples it was fitted on would read near-perfect no matter
/// how bad the signal is.
@MainActor
final class CalibrationRunner {
    struct Config {
        var rounds = 2
        /// Split between travelling to a target and settling on it.
        var settle = 0.9
        var collect = 1.5
    }

    enum Outcome {
        case finished(CalibrationProfile)
        case cancelled
        case failed(String)
    }

    var onOutcome: ((Outcome) -> Void)?

    private struct Step {
        var round: Int
        var displayIndex: Int
        var target: Int
    }

    private enum Phase {
        case waiting
        case travelling
        case settling
        case collecting
    }

    /// A display, its screen, and the three target points on it.
    private struct Panel {
        var snapshot: DisplaySnapshot
        var screen: NSScreen
        var window: CalibrationWindow
        var view: CalibrationView
        var targets: [NSPoint]
    }

    private let config: Config
    private let allowStrips: Bool
    private var panels: [Panel] = []

    private var steps: [Step] = []
    private var stepIndex = 0
    private var phase: Phase = .waiting
    private var phaseStart: CFTimeInterval = 0
    private var travelFrom: NSPoint = .zero
    private var travelTo: NSPoint = .zero
    private var ticker: Timer?

    private var samples: [CalibrationBuilder.Sample] = []
    private var started = false
    private var finished = false
    private var monitor: Any?
    private var previousPolicy: NSApplication.ActivationPolicy?

    private var travelDuration: Double { config.settle * 0.65 }
    private var settleDuration: Double { config.settle * 0.35 }

    init(snapshots: [DisplaySnapshot], allowStrips: Bool = false, config: Config = Config()) {
        self.allowStrips = allowStrips
        self.config = config

        // Left to right across the desk, by where the displays physically are —
        // not by the order the system happens to enumerate them.
        let ordered = snapshots.compactMap { snapshot -> (DisplaySnapshot, NSScreen)? in
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == snapshot.cgID
            }) else { return nil }
            return (snapshot, screen)
        }.sorted { $0.1.frame.minX < $1.1.frame.minX }

        panels = ordered.map { snapshot, screen in
            let window = CalibrationWindow(
                contentRect: screen.frame, styleMask: [.borderless],
                backing: .buffered, defer: false
            )
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.backgroundColor = .black
            let view = CalibrationView()
            window.contentView = view

            // Same 12% inset the probe used, so calibration reproduces the
            // geometry the feasibility numbers were measured against.
            let inset = 0.12
            let fractions = [inset, 0.5, 1 - inset]
            let targets = fractions.map {
                NSPoint(x: screen.frame.minX + screen.frame.width * $0, y: screen.frame.midY)
            }
            view.targets = targets
            return Panel(snapshot: snapshot, screen: screen, window: window, view: view, targets: targets)
        }

        // Round-major, and serpentine: left to right, then right to left. The
        // blob never has to jump back across the desk between passes, and a
        // whole pass over every display finishes before the next begins, so the
        // held-out pass measures looking away and back rather than one stare.
        for round in 0..<config.rounds {
            var pass: [Step] = []
            for displayIndex in panels.indices {
                for target in 0..<3 {
                    pass.append(Step(round: round, displayIndex: displayIndex, target: target))
                }
            }
            if round % 2 == 1 { pass.reverse() }
            steps += pass
        }
    }

    func start() {
        guard !panels.isEmpty, !steps.isEmpty else {
            onOutcome?(.failed("No displays detected."))
            return
        }

        // An .accessory app cannot reliably take key focus, so the keystroke
        // that starts calibration never arrives. Become a regular app for the
        // duration and hand the policy back afterwards.
        previousPolicy = NSApp.activationPolicy()
        if previousPolicy != .regular { NSApp.setActivationPolicy(.regular) }

        for panel in panels {
            panel.view.onBegin = { [weak self] in self?.begin() }
            panel.view.onCancel = { [weak self] in self?.finish(.cancelled) }
            panel.window.orderFrontRegardless()
        }
        NSApp.activate()
        let first = panels[steps[0].displayIndex]
        first.window.makeKeyAndOrderFront(nil)
        first.window.makeFirstResponder(first.view)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 49 where !self.started: self.begin(); return nil
            case 53: self.finish(.cancelled); return nil
            default: return event
            }
        }

        // The blob waits on the first target so the eye already knows where to go.
        travelTo = point(for: steps[0])
        travelFrom = travelTo
        phase = .waiting
        render(headline: "Sit exactly as you normally work.",
               subhead: "\(steps.count) targets across \(panels.count) display(s). "
                   + "Follow the drop and hold still.  SPACE or click to start · ESC to cancel")

        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Fed from the tracking engine; calibration never opens its own camera.
    func ingest(_ pose: HeadPose?) {
        guard phase == .collecting, !finished, let pose, stepIndex < steps.count else { return }
        let step = steps[stepIndex]
        samples.append(CalibrationBuilder.Sample(
            display: panels[step.displayIndex].snapshot.id,
            strip: step.target,
            round: step.round,
            yaw: pose.yaw
        ))
    }

    func cancel() { finish(.cancelled) }

    // MARK: - Sequencing

    private func begin() {
        guard !started, !finished else { return }
        started = true
        enter(.travelling)
    }

    private func point(for step: Step) -> NSPoint {
        panels[step.displayIndex].targets[step.target]
    }

    private func enter(_ next: Phase) {
        phase = next
        phaseStart = CACurrentMediaTime()
        if next == .travelling {
            travelFrom = travelTo
            travelTo = point(for: steps[stepIndex])
        }
    }

    private func tick() {
        guard !finished else { return }
        let elapsed = CACurrentMediaTime() - phaseStart

        switch phase {
        case .waiting:
            break
        case .travelling where elapsed >= travelDuration:
            enter(.settling)
        case .settling where elapsed >= settleDuration:
            enter(.collecting)
        case .collecting where elapsed >= config.collect:
            stepIndex += 1
            if stepIndex >= steps.count {
                complete()
                return
            }
            enter(.travelling)
        default:
            break
        }
        updateBlob()
    }

    private func updateBlob() {
        let elapsed = CACurrentMediaTime() - phaseStart
        let base: CGFloat = 26
        var head = travelTo
        var tail = travelTo
        var radius = base
        var tailRadius: CGFloat = 9
        var progress = 0.0

        switch phase {
        case .waiting:
            // A slow breath, so it reads as alive while it waits.
            radius = base * (1 + 0.06 * CGFloat(sin(CACurrentMediaTime() * 1.6)))

        case .travelling:
            let t = min(max(elapsed / travelDuration, 0), 1)
            // Smoothstep: eases out of one target and into the next.
            let eased = t * t * (3 - 2 * t)
            head = NSPoint(x: travelFrom.x + (travelTo.x - travelFrom.x) * eased,
                           y: travelFrom.y + (travelTo.y - travelFrom.y) * eased)
            // Speed peaks mid-flight, and so does the stretch.
            let stretch = sin(.pi * t)
            let dx = travelTo.x - travelFrom.x
            let dy = travelTo.y - travelFrom.y
            let distance = (dx * dx + dy * dy).squareRoot()
            let tailLength = min(distance * 0.45, 170) * CGFloat(stretch)
            if distance > 0.5 {
                tail = NSPoint(x: head.x - dx / distance * tailLength,
                               y: head.y - dy / distance * tailLength)
            }
            radius = base * (1 - 0.18 * CGFloat(stretch))
            tailRadius = 9 * (1 - 0.5 * CGFloat(stretch))

        case .settling:
            // Jelly: overshoot once, then damp out.
            let u = min(max(elapsed / settleDuration, 0), 1)
            radius = base * (1 + 0.28 * CGFloat(sin(.pi * u) * exp(-2.4 * u)))

        case .collecting:
            progress = min(max(elapsed / config.collect, 0), 1)
            radius = base * (1 + 0.05 * CGFloat(sin(elapsed * 7)))
        }

        let step = steps[min(stepIndex, steps.count - 1)]
        for (index, panel) in panels.enumerated() {
            panel.view.blobHead = head
            panel.view.blobTail = tail
            panel.view.headRadius = radius
            panel.view.tailRadius = tailRadius
            panel.view.collectProgress = progress
            panel.view.activeTarget = index == step.displayIndex ? step.target : nil
            panel.view.showsText = index == step.displayIndex
            if index == step.displayIndex, phase != .waiting {
                panel.view.headline = phase == .collecting ? "Hold still" : "Follow the drop"
                panel.view.subhead = progressText(step)
            } else if phase != .waiting {
                panel.view.headline = ""
                panel.view.subhead = ""
            }
            panel.view.needsDisplay = true
        }
    }

    private func render(headline: String, subhead: String) {
        let step = steps[min(stepIndex, steps.count - 1)]
        for (index, panel) in panels.enumerated() {
            panel.view.showsText = index == step.displayIndex
            panel.view.headline = headline
            panel.view.subhead = subhead
            panel.view.activeTarget = index == step.displayIndex ? step.target : nil
            panel.view.blobHead = travelTo
            panel.view.blobTail = travelTo
            panel.view.needsDisplay = true
        }
    }

    private func progressText(_ step: Step) -> String {
        "pass \(step.round + 1)/\(config.rounds) · \(panels[step.displayIndex].snapshot.name) · "
            + "\(stepIndex + 1) of \(steps.count)"
    }

    // MARK: - Output

    private func complete() {
        switch CalibrationBuilder.build(samples: samples, snapshots: panels.map(\.snapshot),
                                        allowStrips: allowStrips) {
        case .success(let profile):
            finish(.finished(profile))
        case .failure(let error):
            switch error {
            case .noSamples:
                finish(.failed("No usable samples were captured — was a face visible?"))
            case .tooFewSamples(let where_):
                finish(.failed("Too few usable samples for \(where_). Check lighting and try again."))
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        phase = .waiting
        ticker?.invalidate()
        ticker = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for panel in panels { panel.window.orderOut(nil) }
        if let previousPolicy, previousPolicy != .regular {
            NSApp.setActivationPolicy(previousPolicy)
        }
        log(outcome)
        onOutcome?(outcome)
    }

    /// A calibration that fails leaves no other trace, so record why.
    private func log(_ outcome: Outcome) {
        let description: String
        switch outcome {
        case .finished(let profile):
            description = "finished — " + profile.displays.map {
                String(format: "%@ strips=%@ sep=%.2f", $0.name, $0.stripsEnabled ? "on" : "off", $0.stripSeparability)
            }.joined(separator: "; ")
        case .cancelled:
            description = "cancelled at step \(stepIndex) of \(steps.count), \(samples.count) samples"
        case .failed(let message):
            description = "failed — \(message) (\(samples.count) samples)"
        }
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(description)\n"
        let url = CalibrationStore.directory.appendingPathComponent("calibration.log")
        try? FileManager.default.createDirectory(at: CalibrationStore.directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
