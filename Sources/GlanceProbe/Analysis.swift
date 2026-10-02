import Foundation
import GlanceCore

struct Sample {
    var round: Int
    var screen: Int
    var target: Int  // 0...8, row-major: 0 = top-left, 8 = bottom-right
    var pose: HeadPose
}

/// Nearest-centroid classifier, scaled per axis by pooled within-class spread.
///
/// `includePitch` is not a tuning knob — it is the measurement. Pitch turned out
/// to be noise in the 2026-09-30 data, and including it dragged display accuracy
/// from 97% down to 89%, so the report scores both and says which won.
struct NearestCentroid {
    private var centroids: [Int: (yaw: Double, pitch: Double)] = [:]
    private var scaleYaw = 1.0
    private var scalePitch = 1.0
    private let includePitch: Bool

    init(train: [(label: Int, pose: HeadPose)], includePitch: Bool) {
        self.includePitch = includePitch
        let byLabel = Dictionary(grouping: train, by: \.label)
        var withinYaw: [Double] = []
        var withinPitch: [Double] = []

        for (label, rows) in byLabel {
            let yaws = rows.map(\.pose.yaw)
            let pitches = rows.map(\.pose.pitch)
            centroids[label] = (Stats.mean(yaws), Stats.mean(pitches))
            withinYaw.append(Stats.std(yaws))
            withinPitch.append(Stats.std(pitches))
        }
        scaleYaw = max(Stats.mean(withinYaw), 0.01)
        scalePitch = max(Stats.mean(withinPitch), 0.01)
    }

    func classify(_ pose: HeadPose) -> Int? {
        centroids.min { distance(pose, $0.value) < distance(pose, $1.value) }?.key
    }

    /// Half the gap between the best and second-best class, in degrees of yaw.
    /// A sample sitting on the boundary between two displays scores ~0 — exactly
    /// the sample the app must refuse to act on.
    func margin(_ pose: HeadPose) -> Double {
        let sorted = centroids.values.map { abs(pose.yaw - $0.yaw) }.sorted()
        guard sorted.count > 1 else { return .infinity }
        return (sorted[1] - sorted[0]) / 2
    }

    private func distance(_ p: HeadPose, _ c: (yaw: Double, pitch: Double)) -> Double {
        let dy = (p.yaw - c.yaw) / scaleYaw
        guard includePitch else { return dy * dy }
        let dp = (p.pitch - c.pitch) / scalePitch
        return dy * dy + dp * dp
    }
}

func evaluate(
    train: [Sample],
    test: [Sample],
    classes: Int,
    includePitch: Bool = false,
    label: (Sample) -> Int
) -> (accuracy: Double, confusion: [[Int]]) {
    guard !train.isEmpty, !test.isEmpty else { return (0, []) }
    let model = NearestCentroid(train: train.map { (label($0), $0.pose) }, includePitch: includePitch)
    var confusion = Array(repeating: Array(repeating: 0, count: classes), count: classes)
    var correct = 0
    for sample in test {
        guard let predicted = model.classify(sample.pose) else { continue }
        confusion[label(sample)][predicted] += 1
        if predicted == label(sample) { correct += 1 }
    }
    return (Double(correct) / Double(test.count), confusion)
}

/// Accuracy when samples near a class boundary are refused, and the fraction of
/// samples that survive. This is the app's confidence gate, measured.
func evaluateWithDeadband(
    train: [Sample],
    test: [Sample],
    band: Double,
    label: (Sample) -> Int
) -> (accuracy: Double, coverage: Double) {
    guard !train.isEmpty, !test.isEmpty else { return (0, 0) }
    let model = NearestCentroid(train: train.map { (label($0), $0.pose) }, includePitch: false)
    var acted = 0, correct = 0
    for sample in test where model.margin(sample.pose) >= band {
        acted += 1
        if model.classify(sample.pose) == label(sample) { correct += 1 }
    }
    guard acted > 0 else { return (0, 0) }
    return (Double(correct) / Double(acted), Double(acted) / Double(test.count))
}

/// Rolling mean over `frames` consecutive samples of the same target.
///
/// The app never decides on a single frame — it dwells. Scoring per-frame
/// understates it, so every headline number is reported dwell-averaged.
func dwellAveraged(_ samples: [Sample], frames: Int) -> [Sample] {
    guard frames > 1 else { return samples }
    var out: [Sample] = []
    let bursts = Dictionary(grouping: samples) { "\($0.round).\($0.screen).\($0.target)" }
    for burst in bursts.values where burst.count >= frames {
        for start in 0...(burst.count - frames) {
            let window = burst[start..<(start + frames)]
            var averaged = window[window.startIndex]
            averaged.pose = HeadPose(
                yaw: Stats.mean(window.map(\.pose.yaw)),
                pitch: Stats.mean(window.map(\.pose.pitch)),
                roll: Stats.mean(window.map(\.pose.roll)),
                faceArea: Stats.mean(window.map(\.pose.faceArea))
            )
            out.append(averaged)
        }
    }
    return out
}

func separationRatio(_ samples: [Sample], axis: (HeadPose) -> Double) -> Double {
    let byTarget = Dictionary(grouping: samples) { "\($0.screen).\($0.target)" }
    guard byTarget.count > 1 else { return 0 }
    let means = byTarget.values.map { Stats.mean($0.map { axis($0.pose) }) }
    let withins = byTarget.values.map { Stats.std($0.map { axis($0.pose) }) }
    return Stats.std(means) / max(Stats.mean(withins), 0.001)
}

// MARK: - Report

/// Frames per dwell window. ~30 fps, so 12 frames is roughly the 400 ms dwell.
let dwellFrames = 12

func buildReport(
    samples: [Sample],
    screenNames: [String],
    framesSeen: Int,
    framesWithFace: Int,
    device: String
) -> String {
    var out = ""
    func line(_ s: String = "") { out += s + "\n" }

    let rounds = Set(samples.map(\.round)).sorted()
    let screens = Set(samples.map(\.screen)).sorted()

    line("=== Glance feasibility probe ===")
    line("camera: \(device)   engine: Vision VNDetectFaceRectanglesRequest rev3")
    line("samples: \(samples.count)   rounds: \(rounds.count)   displays: \(screens.count)")

    let availability = framesSeen == 0 ? 1 : Double(framesWithFace) / Double(framesSeen)
    if framesSeen == 0 {
        line("face availability: not recorded in the CSV (replay)")
    } else {
        line(String(format: "face detected in %.1f%% of %d frames", availability * 100, framesSeen))
    }

    let distinctYaw = Set(samples.map { ($0.pose.yaw * 1000).rounded() }).count
    let distinctPitch = Set(samples.map { ($0.pose.pitch * 1000).rounded() }).count
    line("distinct values — yaw: \(distinctYaw), pitch: \(distinctPitch) (of \(samples.count) samples)")
    if distinctYaw < samples.count / 10 || distinctPitch < samples.count / 10 {
        line("  ⚠️  Vision appears to quantize these angles. See verdict.")
    }
    line()

    for screen in screens {
        line("--- display \(screen): \(screenNames.indices.contains(screen) ? screenNames[screen] : "?")")
        line("target      yaw mean ± sd      pitch mean ± sd     n")
        for target in 0..<9 {
            let rows = samples.filter { $0.screen == screen && $0.target == target }
            guard !rows.isEmpty else { continue }
            let y = rows.map(\.pose.yaw), p = rows.map(\.pose.pitch)
            line(String(
                format: "  %@   %7.2f ± %5.2f    %7.2f ± %5.2f   %3d",
                targetName(target), Stats.mean(y), Stats.std(y), Stats.mean(p), Stats.std(p), rows.count
            ))
        }
        line()
    }

    line(String(format: "separation ratio — yaw: %.2f   pitch: %.2f  (between-target sd / within-target sd)",
                separationRatio(samples, axis: \.yaw),
                separationRatio(samples, axis: \.pitch)))
    line()

    guard rounds.count >= 2 else {
        line("Only one round captured — cannot measure generalization. Re-run with --rounds 2.")
        return out
    }
    let train = samples.filter { $0.round == rounds.first! }
    let test = samples.filter { $0.round == rounds.last! }
    let trainDwell = dwellAveraged(train, frames: dwellFrames)
    let testDwell = dwellAveraged(test, frames: dwellFrames)

    line("held-out evaluation: train on round \(rounds.first!), test on round \(rounds.last!)")
    line("dwell = \(dwellFrames) frames (~400 ms). Per-frame numbers are shown only for comparison.")
    line()

    var displayAccuracy = 1.0
    if screens.count > 1 {
        let frame = evaluate(train: train, test: test, classes: screens.count) { $0.screen }
        let dwell = evaluate(train: trainDwell, test: testDwell, classes: screens.count) { $0.screen }
        let withPitch = evaluate(train: trainDwell, test: testDwell, classes: screens.count, includePitch: true) { $0.screen }
        displayAccuracy = dwell.accuracy

        line("DISPLAY CLASSIFICATION (\(screens.count)-way)")
        line(String(format: "  per frame, yaw only:   %.1f%%", frame.accuracy * 100))
        line(String(format: "  with dwell, yaw only:  %.1f%%   ← the app's real operating point", dwell.accuracy * 100))
        line(String(format: "  with dwell, yaw+pitch: %.1f%%   %@", withPitch.accuracy * 100,
                    withPitch.accuracy < dwell.accuracy ? "← pitch makes it worse; exclude it" : ""))
        line()
        line("  confidence gate — refuse samples within N° of a display boundary:")
        line("    band    accuracy   coverage")
        for band in [0.0, 2, 4, 6, 8] {
            let r = evaluateWithDeadband(train: trainDwell, test: testDwell, band: band) { $0.screen }
            line(String(format: "    ±%.0f°     %6.1f%%     %5.1f%%", band, r.accuracy * 100, r.coverage * 100))
        }
    } else {
        line("DISPLAY CLASSIFICATION: skipped (only one display was probed)")
    }

    var columnAccuracy = 0.0, rowAccuracy = 0.0, regionAccuracy = 0.0
    var weight = 0
    var perDisplayColumns: [(Int, Double)] = []
    for screen in screens {
        let tr = trainDwell.filter { $0.screen == screen }
        let te = testDwell.filter { $0.screen == screen }
        guard !tr.isEmpty, !te.isEmpty else { continue }

        let region = evaluate(train: tr, test: te, classes: 9, includePitch: true) { $0.target }
        let column = evaluate(train: tr, test: te, classes: 3) { $0.target % 3 }
        let row = evaluate(train: tr, test: te, classes: 3, includePitch: true) { $0.target / 3 }

        line()
        line("display \(screen) — within this display, dwell-averaged:")
        line(String(format: "  columns, 3-way:    %.1f%%   (chance 33%%)  ← yaw", column.accuracy * 100))
        line(String(format: "  rows, 3-way:       %.1f%%   (chance 33%%)  ← pitch", row.accuracy * 100))
        line(String(format: "  9-region:          %.1f%%   (chance 11%%)", region.accuracy * 100))
        line("  column confusion (actual → predicted), left/middle/right:")
        line(confusionBlock(column.confusion, labels: ["L", "M", "R"]))

        perDisplayColumns.append((screen, column.accuracy))
        columnAccuracy += column.accuracy
        rowAccuracy += row.accuracy
        regionAccuracy += region.accuracy
        weight += 1
    }
    if weight > 0 {
        columnAccuracy /= Double(weight)
        rowAccuracy /= Double(weight)
        regionAccuracy /= Double(weight)
    }

    line()
    line(verdict(
        display: displayAccuracy,
        region: regionAccuracy,
        column: columnAccuracy,
        row: rowAccuracy,
        perDisplayColumns: perDisplayColumns,
        availability: availability,
        multipleDisplays: screens.count > 1,
        screenNames: screenNames
    ))
    return out
}

private func targetName(_ i: Int) -> String {
    let rows = ["top", "mid", "bot"], cols = ["left", "ctr ", "right"]
    return "\(rows[i / 3])-\(cols[i % 3])".padding(toLength: 10, withPad: " ", startingAt: 0)
}

private func confusionBlock(_ m: [[Int]], labels: [String]) -> String {
    guard !m.isEmpty else { return "    (none)" }
    var s = "      " + labels.map { $0.padding(toLength: 6, withPad: " ", startingAt: 0) }.joined() + "\n"
    for (i, row) in m.enumerated() {
        s += "    \(labels[i]) " + row.map { String(format: "%-6d", $0) }.joined() + "\n"
    }
    return String(s.dropLast())
}

private func verdict(
    display: Double,
    region: Double,
    column: Double,
    row: Double,
    perDisplayColumns: [(Int, Double)],
    availability: Double,
    multipleDisplays: Bool,
    screenNames: [String]
) -> String {
    var s = "=== VERDICT ===\n"

    if availability < 0.9 {
        s += "⚠️  Face detected in under 90% of frames. Fix lighting or seating and re-run.\n\n"
    }

    if multipleDisplays {
        if display >= 0.95 {
            s += "✅ Displays separate reliably (\(pct(display)) dwell-averaged). This is the number the product depends on. Proceed.\n\n"
        } else if display >= 0.90 {
            s += "⚠️  Display separation is \(pct(display)) — usable only behind a strict confidence gate. Pick a deadband above that holds 100% and check the coverage you are giving up.\n\n"
        } else {
            s += """
            ❌ Displays do not separate (\(pct(display))). Region selection is moot if the app \
            cannot tell which monitor you face. Evaluate eye tracking (FR-16) before continuing.
            """
            return s
        }
    } else {
        s += "⚠️  Only one display probed. Re-run with every display connected — display separation is the number that matters most.\n\n"
    }

    if row >= 0.80 {
        s += "Rows hold at \(pct(row)); a vertical subdivision is worth keeping.\n"
    } else {
        s += """
        Rows fail (\(pct(row))). Head pitch does not separate vertical thirds — people turn \
        their heads sideways but move their eyes vertically. Drop vertical subdivision.

        """
    }

    let good = perDisplayColumns.filter { $0.1 >= 0.95 }
    let bad = perDisplayColumns.filter { $0.1 < 0.95 }
    if bad.isEmpty {
        s += "Columns hold on every display (worst \(pct(perDisplayColumns.map(\.1).min() ?? 0))). Three vertical strips per display are viable.\n"
    } else if good.isEmpty {
        s += """
        Columns do not hold on any display (best \(pct(perDisplayColumns.map(\.1).max() ?? 0))). \
        Ship one region per display: move the cursor to the centre of the display being looked at. \
        That alone addresses wrong-window typing.
        """
    } else {
        let name = { (i: Int) in screenNames.indices.contains(i) ? screenNames[i] : "display \(i)" }
        s += """
        Columns hold on some displays and not others:
        \(perDisplayColumns.map { "  \(name($0.0)): \(pct($0.1))\($0.1 >= 0.95 ? " ✅" : " ❌")" }.joined(separator: "\n"))

        A display far to one side needs a large head turn to reach its far column, which is where \
        head-pose estimation degrades. Do not pick one layout for every display: have calibration \
        measure each display's own column separability and enable strips only where it clears 95%. \
        Everything else gets one region.
        """
    }
    return s
}

private func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
