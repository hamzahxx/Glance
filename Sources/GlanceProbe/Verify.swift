import Foundation
import GlanceCore

/// `--verify`: runs the analysis against synthetic data with a known answer.
///
/// The classifier silently returning plausible-looking numbers is the failure
/// mode that matters here — a wrong verdict gets acted on. This is the check
/// that fails loudly if it breaks.
enum Verify {
    static func run() -> Never {
        var seed: UInt64 = 42
        func noise(_ scale: Double) -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 11) / Double(1 << 53) * 2 - 1) * scale
        }

        // Two displays 30° apart in yaw, three columns 8° apart within each.
        // Pitch is pure noise, so any pitch-driven result must come out at chance.
        var samples: [Sample] = []
        for round in 0..<2 {
            for screen in 0..<2 {
                for target in 0..<9 {
                    for _ in 0..<30 {
                        samples.append(Sample(
                            round: round, screen: screen, target: target,
                            pose: HeadPose(
                                yaw: Double(screen) * 30 + Double(target % 3) * 8 + noise(2),
                                pitch: noise(5),
                                roll: 0,
                                faceArea: 0.1
                            )
                        ))
                    }
                }
            }
        }
        let train = dwellAveraged(samples.filter { $0.round == 0 }, frames: dwellFrames)
        let test = dwellAveraged(samples.filter { $0.round == 1 }, frames: dwellFrames)

        let display = evaluate(train: train, test: test, classes: 2) { $0.screen }.accuracy
        check("separable displays are classified", display > 0.99, display)

        // Columns are only meaningful within one display: column 0 of a display
        // 30° away sits further right than column 2 of this one.
        let train0 = train.filter { $0.screen == 0 }, test0 = test.filter { $0.screen == 0 }
        let columns = evaluate(train: train0, test: test0, classes: 3) { $0.target % 3 }.accuracy
        check("separable columns are classified, within one display", columns > 0.95, columns)

        let rows = evaluate(train: train, test: test, classes: 3, includePitch: true) { $0.target / 3 }.accuracy
        check("pure-noise rows come out at chance", rows < 0.50, rows)

        let wide = evaluateWithDeadband(train: train, test: test, band: 4) { $0.screen }
        check("a deadband well inside the gap keeps full coverage", wide.coverage > 0.99, wide.coverage)

        // Dwell averaging must beat single frames on noisy input.
        let raw = evaluate(
            train: samples.filter { $0.round == 0 && $0.screen == 0 },
            test: samples.filter { $0.round == 1 && $0.screen == 0 },
            classes: 3
        ) { $0.target % 3 }.accuracy
        check("dwell averaging does not hurt", columns >= raw - 0.001, columns - raw)

        print("\nall checks passed")
        exit(0)
    }

    private static func check(_ what: String, _ passed: Bool, _ value: Double) {
        print(String(format: "  %@ %@  (%.3f)", passed ? "✅" : "❌", what, value))
        if !passed {
            print("VERIFY FAILED: \(what)")
            exit(1)
        }
    }
}
