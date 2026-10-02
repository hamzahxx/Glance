import Foundation

/// Decides when a prediction has been stable enough to act on.
///
/// Every rule here exists to *refuse*. The classifier says where you are
/// probably looking; this says whether that belief has earned the right to move
/// your cursor.
public struct MovementGate {
    public struct Target: Equatable, Sendable {
        public var display: DisplayIdentifier
        public var strip: Int?

        public init(display: DisplayIdentifier, strip: Int?) {
            self.display = display
            self.strip = strip
        }
    }

    public struct Decision: Equatable, Sendable {
        public var target: Target
        /// False while the user is mid-keystroke. The cursor still moves;
        /// only focus is withheld.
        public var activateFocus: Bool
    }

    /// Seconds a candidate must hold still before it is accepted.
    public var dwell: TimeInterval
    /// Margin required to *leave* an already-accepted target, above the margin
    /// required to acquire one. Without
    /// it, a yaw sitting near a boundary oscillates every dwell period.
    public var switchMargin: Double
    /// Seconds since the last keystroke before focus may change.
    public var typingIdle: TimeInterval

    private var candidate: Target?
    private var candidateSince: TimeInterval = 0
    private var accepted: Target?

    public init(dwell: TimeInterval = 0.4, switchMargin: Double = 4, typingIdle: TimeInterval = 0.5) {
        self.dwell = dwell
        self.switchMargin = switchMargin
        self.typingIdle = typingIdle
    }

    public var currentTarget: Target? { accepted }

    public mutating func update(
        _ prediction: YawClassifier.Prediction?,
        now: TimeInterval,
        keyboardIdle: TimeInterval
    ) -> Decision? {
        // No trusted prediction: drop the candidate, but keep what was last
        // accepted so a blink does not cause a repeat move to the same place.
        guard let prediction else {
            candidate = nil
            return nil
        }

        let target = Target(display: prediction.display, strip: prediction.strip)
        if candidate != target {
            candidate = target
            candidateSince = now
        }

        if let accepted, target != accepted {
            // Changing display is the expensive mistake, so it pays the higher
            // bar; changing strip within a display is judged on the strip's own
            // margin.
            let margin = accepted.display == target.display
                ? (prediction.stripMargin ?? .infinity)
                : prediction.displayMargin
            guard margin >= switchMargin else {
                // Time spent unconvincing does not count toward dwell, so a
                // switch requires confidence *sustained* for the whole period
                // rather than one confident frame after a long ambiguous stare.
                candidateSince = now
                return nil
            }
        }

        guard now - candidateSince >= dwell else { return nil }
        // No repeated moves to the same target.
        guard target != accepted else { return nil }

        accepted = target
        return Decision(target: target, activateFocus: keyboardIdle >= typingIdle)
    }

    /// Forget everything. Used when tracking stops or calibration changes, so a
    /// stale accepted target cannot suppress the first move of the next session.
    public mutating func reset() {
        candidate = nil
        accepted = nil
        candidateSince = 0
    }
}
