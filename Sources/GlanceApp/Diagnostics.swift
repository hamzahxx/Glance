import AppKit
import AVFoundation
import Foundation
import GlanceCore

/// `--diagnose [seconds]`: runs the real engine headlessly and reports what the
/// camera and Vision actually produced.
///
/// This is Milestone 2's deliverable and also how it gets verified: driving the
/// menu bar by hand needs Accessibility permission a terminal will not have.
@MainActor
enum Diagnostics {
    static func run(seconds: Double) -> Never {
        let engine = VisionTrackingEngine()
        var log: [String] = []

        // Log the starting TCC state before awaiting anything: if the run ends
        // with an empty log, this is the line that says why.
        let initial = AVCaptureDevice.authorizationStatus(for: .video)
        let names: [AVAuthorizationStatus: String] = [
            .notDetermined: "notDetermined (a prompt will be shown — it must be answered)",
            .restricted: "restricted", .denied: "denied", .authorized: "authorized",
        ]
        log.append("tcc    → \(names[initial] ?? "unknown(\(initial.rawValue))")")
        var yaws: [Double] = []
        var pitches: [Double] = []
        var poseUpdates = 0
        var predictions: [String: Int] = [:]
        var refused = 0
        // Dry run: the gate runs for real, but nothing is moved or activated.
        var gate = MovementGate()
        var decisions: [String] = []
        // Raw readings, before smoothing and before the confidence gate, so the
        // two ways a frame can be lost are told apart.
        var raw: [(t: Date, yaw: Double, confidence: Double)] = []
        var rawMisses = 0
        let started = Date()

        let snapshots = AppDelegate.currentDisplays()
        let classifier = CalibrationStore().load().map {
            YawClassifier(profile: $0, connected: snapshots)
        }

        engine.isCalibrated = {
            CalibrationStore().load()?.validity(against: snapshots).isValid ?? false
        }
        engine.onCameraStatus = { log.append("camera → \($0.summary)") }
        engine.onEvent = { log.append("event  → \($0)") }
        engine.onRawPose = { pose in
            guard let pose else { rawMisses += 1; return }
            raw.append((Date(), pose.yaw, pose.confidence))
        }
        engine.onPose = { pose in
            poseUpdates += 1
            guard let pose else { return }
            yaws.append(pose.yaw)
            pitches.append(pose.pitch)

            // End-to-end check: real pose → real profile → target.
            guard let classifier else { return }
            if let gated = classifier.classify(yaw: pose.yaw) {
                var label = gated.displayName
                if let strip = gated.strip { label += " · strip \(strip + 1)" }
                predictions[label, default: 0] += 1
            } else {
                refused += 1
            }

            let gated = classifier.classify(yaw: pose.yaw)
            guard let decision = gate.update(
                gated,
                now: ProcessInfo.processInfo.systemUptime,
                keyboardIdle: KeyboardActivity.secondsSinceLastKeystroke()
            ) else { return }

            guard let snapshot = snapshots.first(where: { $0.id == decision.target.display })
            else { return }
            let point = decision.target.strip.map(snapshot.stripCenter) ?? snapshot.center
            // Resolve the window without touching it, so the hit-test is
            // verified without activating anything.
            let owner = FocusActivator.application(at: point)
                .flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
            decisions.append(String(
                format: "%@ at (%.0f, %.0f) → %@%@",
                snapshot.name, point.x, point.y,
                owner ?? "no window there",
                decision.activateFocus ? "" : "  [focus held — typing]"
            ))
        }

        engine.start()

        // The first run shows a camera prompt. Wait for it to be answered rather
        // than timing out and reporting a misleading "no frames".
        let deadline = Date().addingTimeInterval(90)
        var waited = 0.0
        while engine.cameraStatus == .notRequested, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            waited += 0.2
        }
        if waited > 0.5 {
            log.append(String(format: "waited %.0fs for the camera prompt to be answered", waited))
        }
        if engine.cameraStatus == .notRequested {
            log.append("camera prompt was never answered — re-run and click Allow")
        }

        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let seen = engine.framesSeen
        let withFace = engine.framesWithFace
        engine.stop()

        var out = "=== Glance head-pose diagnostics ===\n"
        out += "displays:\n"
        for screen in AppDelegate.currentDisplays() {
            out += String(format: "  %@  %.0fx%.0f at (%.0f, %.0f)  vendor %u model %u\n",
                          screen.name, screen.frame.width, screen.frame.height,
                          screen.frame.minX, screen.frame.minY,
                          screen.id.vendor, screen.id.model)
        }
        let store = CalibrationStore()
        if let profile = store.load() {
            out += String(format: "calibration: %@ · displays %.0f%% separable\n",
                          profile.validity(against: AppDelegate.currentDisplays()).explanation,
                          profile.displaySeparability * 100)
        } else {
            out += "calibration: none saved\n"
        }
        out += "\n"
        out += "duration: \(Int(seconds))s   camera: \(engine.deviceName)\n"
        out += "engine: Vision VNDetectFaceRectanglesRequest rev3 — head pose, not gaze\n"
        out += "bundle: \(Bundle.main.bundlePath)\n"
        out += "accessibility (window raise): \(WindowRaiser.isPermitted ? "TRUSTED" : "NOT trusted")\n"
        out += "login item: \(LoginItem.explanation)\n\n"
        out += log.map { "  \($0)" }.joined(separator: "\n") + "\n\n"

        out += "frames: \(seen)"
        if seen > 0 {
            out += String(format: "   with a usable face: %d (%.1f%%)   ~%.0f fps",
                          withFace, Double(withFace) / Double(seen) * 100, Double(seen) / seconds)
        }
        out += "\npose updates delivered: \(poseUpdates)\n"

        if yaws.isEmpty {
            out += """

            No face was detected for the whole run. If nobody was sitting in front \
            of the camera that is the correct result, and the face-loss path above \
            is what should have fired.
            """
        } else {
            out += String(format: "\nyaw   min %+.1f°  max %+.1f°  last %+.1f°\n",
                          yaws.min()!, yaws.max()!, yaws.last!)
            out += String(format: "pitch min %+.1f°  max %+.1f°  last %+.1f°\n",
                          pitches.min()!, pitches.max()!, pitches.last!)
        }

        if classifier != nil, !yaws.isEmpty {
            out += "\ntarget prediction (gated at \(YawClassifier.defaultMargin)° of yaw):\n"
            for (label, count) in predictions.sorted(by: { $0.value > $1.value }) {
                out += String(format: "  %-34@ %4d  %5.1f%%\n", label, count,
                              Double(count) / Double(yaws.count) * 100)
            }
            out += String(format: "  %-34@ %4d  %5.1f%%\n", "refused — too close to call", refused,
                          Double(refused) / Double(yaws.count) * 100)
        }

        let threshold = engine.confidenceThreshold
        if !raw.isEmpty {
            let confidences = raw.map(\.confidence).sorted()
            let belowGate = confidences.filter { $0 < threshold }.count
            out += String(format: """

            confidence (gate is %.2f — below this a detection counts as no face):
              min %.2f   median %.2f   max %.2f
              rejected by the gate: %d of %d detections (%.1f%%)
              frames with no detection at all: %d

            """,
            threshold, confidences.first!, confidences[confidences.count / 2], confidences.last!,
            belowGate, confidences.count, Double(belowGate) / Double(confidences.count) * 100,
            rawMisses)

            // Where does the head have to be before the camera stops seeing it?
            let usable = raw.filter { $0.confidence >= threshold }
            if let widest = usable.map(\.yaw).max(), let narrowest = usable.map(\.yaw).min() {
                out += String(format: "  usable yaw range: %+.1f° … %+.1f°\n", narrowest, widest)
            }

            out += "\nper second — frames, detections, usable, mean yaw:\n"
            let seconds = Int(Date().timeIntervalSince(started)) + 1
            for second in 0..<seconds {
                let window = raw.filter {
                    Int($0.t.timeIntervalSince(started)) == second
                }
                let ok = window.filter { $0.confidence >= threshold }
                let yaw = ok.isEmpty ? Double.nan : ok.map(\.yaw).reduce(0, +) / Double(ok.count)
                out += String(format: "  %2ds  detections %3d  usable %3d  yaw %@\n",
                              second, window.count, ok.count,
                              yaw.isNaN ? "—" : String(format: "%+.1f°", yaw))
            }
        }

        if classifier != nil {
            out += "\nmovement decisions (DRY RUN — nothing was moved or activated):\n"
            if decisions.isEmpty {
                out += "  none — no target held still for the dwell period\n"
            } else {
                for decision in decisions { out += "  \(decision)\n" }
            }
        }

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Glance")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("diagnose-\(stamp).txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)

        print(out)
        print("written to \(url.path)")
        exit(0)
    }
}
