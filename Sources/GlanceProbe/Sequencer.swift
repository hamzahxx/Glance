import GlanceCore
import AppKit

/// Walks every (round, display, target) combination, collecting head pose while
/// the user looks at each highlighted dot.
@MainActor
final class Sequencer {
    struct Config {
        var rounds = 2
        var settle = 0.8   // seconds of "get ready" before samples count
        var collect = 1.5  // seconds of samples per target
    }

    private struct Step {
        var round: Int
        var screenIndex: Int
        var target: Int
    }

    /// Probe output lives in a hidden app folder, not scattered across $HOME.
    static let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".Glance")

    private let config: Config
    private let capture = PoseCapture()
    private let window: ProbeWindow
    private let view = ProbeView()
    private let screens: [NSScreen]

    private var steps: [Step] = []
    private var stepIndex = 0
    private var collecting = false
    private var samples: [Sample] = []
    private var framesSeen = 0
    private var framesWithFace = 0
    private var started = false

    init(config: Config) {
        self.config = config
        self.screens = NSScreen.screens
        window = ProbeWindow(
            contentRect: screens.first?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.contentView = view

        // Round-major so that a whole pass over every display finishes before the
        // second pass starts. Training on pass 1 and testing on pass 2 then
        // measures real look-away-and-back behaviour rather than one long stare.
        for round in 0..<config.rounds {
            for screenIndex in screens.indices {
                for target in 0..<9 {
                    steps.append(Step(round: round, screenIndex: screenIndex, target: target))
                }
            }
        }
    }

    func run() async {
        guard await capture.requestPermission() else {
            fail("Camera permission denied. Grant it in System Settings › Privacy & Security › Camera, then re-run.")
            return
        }
        do {
            try capture.start()
        } catch {
            fail("\(error)")
            return
        }

        capture.onPose = { [weak self] pose in
            Task { @MainActor in self?.ingest(pose) }
        }

        moveWindow(to: 0)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        showIntro()
    }

    // MARK: - Input

    private func showIntro() {
        view.activeTarget = nil
        view.isCollecting = false
        view.headline = "Sit exactly as you normally work."
        view.subhead = "\(steps.count) targets across \(screens.count) display(s). "
            + "Look at each green dot and hold still. SPACE to start · ESC to abort."
        view.needsDisplay = true

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 49 where !self.started:  // space
                self.started = true
                self.advance()
                return nil
            case 53:  // esc
                self.finish(aborted: true)
                return nil
            default:
                return event
            }
        }
    }

    private func ingest(_ pose: HeadPose?) {
        framesSeen += 1
        guard let pose else { return }
        framesWithFace += 1
        guard collecting, stepIndex < steps.count else { return }
        let step = steps[stepIndex]
        samples.append(Sample(round: step.round, screen: step.screenIndex, target: step.target, pose: pose))
    }

    // MARK: - Sequencing

    private func advance() {
        guard stepIndex < steps.count else {
            finish(aborted: false)
            return
        }
        let step = steps[stepIndex]
        if window.screen !== screens[step.screenIndex] {
            moveWindow(to: step.screenIndex)
        }

        // Settle first: the samples taken while the head is still swinging toward
        // the target are the ones that would make this measurement a lie.
        collecting = false
        view.activeTarget = step.target
        view.isCollecting = false
        view.headline = "Get ready…"
        view.subhead = progressText(step)
        view.needsDisplay = true

        DispatchQueue.main.asyncAfter(deadline: .now() + config.settle) { [weak self] in
            guard let self, self.stepIndex < self.steps.count else { return }
            self.collecting = true
            self.view.isCollecting = true
            self.view.headline = "Hold still"
            self.view.needsDisplay = true

            DispatchQueue.main.asyncAfter(deadline: .now() + self.config.collect) { [weak self] in
                guard let self else { return }
                self.collecting = false
                self.stepIndex += 1
                self.advance()
            }
        }
    }

    private func progressText(_ step: Step) -> String {
        let name = screens[step.screenIndex].localizedName
        return "round \(step.round + 1)/\(config.rounds) · \(name) · "
            + "target \(step.target + 1)/9 · \(stepIndex + 1) of \(steps.count) overall"
    }

    private func moveWindow(to index: Int) {
        guard screens.indices.contains(index) else { return }
        window.setFrame(screens[index].frame, display: true)
    }

    // MARK: - Output

    private func finish(aborted: Bool) {
        capture.stop()
        window.orderOut(nil)

        guard !samples.isEmpty else {
            fail(aborted ? "Aborted before any samples were collected." : "No samples collected — no face was ever detected.")
            return
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = Sequencer.outputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent("probe-\(stamp)")
        writeCSV(to: base.appendingPathExtension("csv"))

        var report = buildReport(
            samples: samples,
            screenNames: screens.map(\.localizedName),
            framesSeen: framesSeen,
            framesWithFace: framesWithFace,
            device: capture.deviceName
        )
        if aborted {
            report = "⚠️  ABORTED after \(stepIndex) of \(steps.count) targets — partial data.\n\n" + report
        }
        let reportURL = base.appendingPathExtension("txt")
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)

        print(report)
        print("\ncsv:    \(base.appendingPathExtension("csv").path)")
        print("report: \(reportURL.path)")
        NSApp.terminate(nil)
    }

    private func writeCSV(to url: URL) {
        var csv = "round,screen,screen_name,target,yaw_deg,pitch_deg,roll_deg,face_area\n"
        for s in samples {
            let name = screens.indices.contains(s.screen) ? screens[s.screen].localizedName : "?"
            csv += "\(s.round),\(s.screen),\"\(name)\",\(s.target),"
            csv += String(format: "%.4f,%.4f,%.4f,%.5f\n", s.pose.yaw, s.pose.pitch, s.pose.roll, s.pose.faceArea)
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }

    private func fail(_ message: String) {
        print("probe failed: \(message)")
        NSApp.terminate(nil)
    }
}
