import CoreGraphics
import Foundation
import Testing
@testable import GlanceCore

private let hudA = DisplayIdentifier(vendor: 1, model: 1, serial: 1)
private let hudB = DisplayIdentifier(vendor: 1, model: 2, serial: 2)

private func hudPrediction(_ display: DisplayIdentifier, margin: Double = 20) -> YawClassifier.Prediction {
    .init(display: display, displayName: "d", strip: nil, displayMargin: margin, stripMargin: nil)
}

// MARK: - Gate refusal

@Test("The gate names each refusal and clears it on a move")
func gateRefusals() {
    var gate = MovementGate(dwell: 0.5)
    #expect(gate.lastRefusal == nil)

    _ = gate.update(nil, now: 0, keyboardIdle: 10)
    #expect(gate.lastRefusal == .noPrediction)

    _ = gate.update(hudPrediction(hudA), now: 1, keyboardIdle: 10)
    _ = gate.update(hudPrediction(hudA), now: 1.25, keyboardIdle: 10)
    #expect(gate.lastRefusal == .dwell(progress: 0.5))

    #expect(gate.update(hudPrediction(hudA), now: 1.5, keyboardIdle: 10) != nil)
    #expect(gate.lastRefusal == nil)

    _ = gate.update(hudPrediction(hudA), now: 2, keyboardIdle: 10)
    #expect(gate.lastRefusal == .sameTarget)

    _ = gate.update(hudPrediction(hudB, margin: 3), now: 3, keyboardIdle: 10)
    #expect(gate.lastRefusal == .switchMargin)

    gate.reset()
    #expect(gate.lastRefusal == nil)
}

@Test("Looking back at the accepted target after a blink reads as already here")
func gateBlinkBackIsSameTarget() {
    var gate = MovementGate(dwell: 0.4)
    _ = gate.update(hudPrediction(hudA), now: 0, keyboardIdle: 10)
    _ = gate.update(hudPrediction(hudA), now: 0.4, keyboardIdle: 10)
    _ = gate.update(nil, now: 1, keyboardIdle: 10)
    _ = gate.update(hudPrediction(hudA), now: 1.1, keyboardIdle: 10)
    #expect(gate.lastRefusal == .sameTarget)
}

// MARK: - Text

private func text(
    yaw: Double? = 0, prediction: YawClassifier.Prediction? = hudPrediction(hudA),
    refusal: MovementGate.Refusal? = nil, hold: String? = nil,
    move: (MovementGate.Decision, String)? = nil
) -> String {
    HUDModel.make(yaw: yaw, prediction: prediction, refusal: refusal, holdReason: hold,
                  recentMove: move.map { (decision: $0.0, name: $0.1) }, scale: -45...45).text
}

@Test("HUD text names the refusal for every case")
func hudTexts() {
    let target = MovementGate.Target(display: hudB, strip: nil)
    #expect(text(yaw: nil, prediction: nil, refusal: .noPrediction) == "No face")
    #expect(text(prediction: nil, refusal: .noPrediction) == "Near seam")
    #expect(text(refusal: .switchMargin) == "Not convincing enough to switch")
    #expect(text(refusal: .dwell(progress: 0.62)) == "Holding (dwell 62%)")
    #expect(text(refusal: .sameTarget) == "Already here")
    #expect(text(hold: "Held — Keynote is fullscreen") == "Held — Keynote is fullscreen")
    #expect(text(refusal: .sameTarget,
                 move: (MovementGate.Decision(target: target, activateFocus: true), "External"))
            == "Moved → External")
    #expect(text(refusal: .sameTarget,
                 move: (MovementGate.Decision(target: target, activateFocus: false), "External"))
            == "Typing — focus held")
    // A fresh refusal after the move replaces the move text.
    #expect(text(refusal: .switchMargin,
                 move: (MovementGate.Decision(target: target, activateFocus: true), "External"))
            == "Not convincing enough to switch")
}

// MARK: - Needle

@Test("Needle maps yaw across the scale and clamps at the ends")
func hudNeedle() {
    #expect(HUDModel.needle(yaw: 0, scale: -45...45) == 0.5)
    #expect(HUDModel.needle(yaw: -90, scale: -45...45) == 0)
    #expect(HUDModel.needle(yaw: 90, scale: -45...45) == 1)
    let model = HUDModel.make(yaw: nil, prediction: nil, refusal: nil, holdReason: nil,
                              recentMove: nil, scale: -45...45)
    #expect(model.needle == nil)
}

@Test("Bands split at midpoints and the scale pads past the outer centres")
func hudBandsAndScale() {
    func calibration(_ id: DisplayIdentifier, _ yaw: Double, x: CGFloat) -> (DisplayCalibration, DisplaySnapshot) {
        let frame = CGRect(x: x, y: 0, width: 1200, height: 900)
        return (DisplayCalibration(display: id, name: "\(id.model)", bounds: frame, yawMean: yaw,
                                   strips: [], stripSeparability: 0, stripsEnabled: false),
                DisplaySnapshot(id: id, cgID: id.model, frame: frame))
    }
    let a = calibration(hudA, 30, x: 1200), b = calibration(hudB, -10, x: 0)
    let classifier = YawClassifier(
        profile: CalibrationProfile(version: CalibrationProfile.currentVersion, createdAt: .init(),
                                    displays: [a.0, b.0], displaySeparability: 1),
        connected: [a.1, b.1]
    )
    let bands = classifier.bands
    #expect(bands.map(\.display) == [hudB, hudA])
    #expect(bands[0].lower == -.infinity && bands[0].upper == 10)
    #expect(bands[1].lower == 10 && bands[1].upper == .infinity)
    #expect(classifier.seamMargin == YawClassifier.defaultMargin)
    #expect(HUDModel.scale(for: bands) == -20...40)
    #expect(HUDModel.scale(for: []) == HUDModel.uncalibratedScale)
}

@Test("Settings without showHUD load with the HUD off")
func showHUDDefaultsOff() throws {
    let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"version":1}"#.utf8))
    #expect(!settings.showHUD)
}
