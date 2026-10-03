import Foundation

/// What the yaw HUD shows for one frame. Pure, so the wording is tested
/// rather than eyeballed.
public struct HUDModel: Equatable, Sendable {
    /// One line naming whatever is refusing to move, or the move just made.
    public var text: String
    /// Needle position across the scale, 0...1. Nil when there is no face.
    public var needle: Double?
    /// Dwell bar fill, 0...1.
    public var dwellFraction: Double

    public init(text: String, needle: Double?, dwellFraction: Double) {
        self.text = text
        self.needle = needle
        self.dwellFraction = dwellFraction
    }

    /// Without calibration the needle runs over a plain ±45° scale.
    public static let uncalibratedScale = -45.0...45.0

    /// Yaw range the HUD draws: every band centre plus room either side.
    public static func scale(for bands: [YawClassifier.Band]) -> ClosedRange<Double> {
        guard let lo = bands.map(\.centre).min(), let hi = bands.map(\.centre).max()
        else { return uncalibratedScale }
        let pad = max(10, (hi - lo) * 0.25)
        return (lo - pad)...(hi + pad)
    }

    /// Where `yaw` falls across `scale`, clamped to the ends.
    public static func needle(yaw: Double, scale: ClosedRange<Double>) -> Double {
        let span = scale.upperBound - scale.lowerBound
        guard span > 0 else { return 0.5 }
        return min(max((yaw - scale.lowerBound) / span, 0), 1)
    }

    /// - Parameters:
    ///   - yaw: smoothed head yaw, nil when no face is trusted.
    ///   - prediction: the gated classification of `yaw`; nil near a seam.
    ///   - refusal: `MovementGate.lastRefusal` after this frame.
    ///   - holdReason: text for anything holding movement outside the gate
    ///     (a pause rule, a paused state); shown verbatim and wins.
    ///   - recentMove: a move made in the last moment, so it stays readable
    ///     for longer than the frame it happened on.
    public static func make(
        yaw: Double?,
        prediction: YawClassifier.Prediction?,
        refusal: MovementGate.Refusal?,
        holdReason: String?,
        recentMove: (decision: MovementGate.Decision, name: String)?,
        scale: ClosedRange<Double>
    ) -> HUDModel {
        let needle = yaw.map { Self.needle(yaw: $0, scale: scale) }
        func model(_ text: String, dwell: Double = 0) -> HUDModel {
            HUDModel(text: text, needle: needle, dwellFraction: dwell)
        }
        if let holdReason { return model(holdReason) }
        if let recentMove, refusal == nil || refusal == .sameTarget {
            return model(recentMove.decision.activateFocus
                ? "Moved → \(recentMove.name)" : "Typing — focus held", dwell: 1)
        }
        guard yaw != nil else { return model("No face") }
        guard prediction != nil else { return model("Near seam") }
        switch refusal {
        case .noPrediction: return model("Near seam")
        case .switchMargin: return model("Not convincing enough to switch")
        case .dwell(let progress):
            return model("Holding (dwell \(Int((progress * 100).rounded(.down)))%)", dwell: progress)
        case .sameTarget, nil: return model("Already here", dwell: 1)
        }
    }
}
