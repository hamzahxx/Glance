import Foundation

/// Smooths pose and decides when the face has actually been lost.
///
/// Both jobs need hysteresis rather than a threshold: a single dropped frame
/// while you blink is not a lost face, and a single detection during a turn is
/// not a reacquisition. Kept free of AVFoundation so it can be tested without a
/// camera.
public struct PoseFilter {
    public struct Update: Equatable {
        /// Smoothed pose, or nil while no usable face is present.
        public var pose: HeadPose?
        /// Emitted only on a transition, never repeated.
        public var event: TrackingEvent?
    }

    /// Consecutive unusable frames before the face counts as lost.
    public var lossFrames: Int
    /// Consecutive usable frames before tracking resumes. Resuming requires
    /// resuming only after *stable* reacquisition.
    public var reacquireFrames: Int
    /// Detections below this are treated as no face at all.
    public var minConfidence: Double
    /// EMA weight for new samples. 1 disables smoothing.
    public var smoothing: Double

    private var misses = 0
    private var hits = 0
    private var lost = false
    private var smoothed: HeadPose?

    public init(
        lossFrames: Int = 15,
        reacquireFrames: Int = 10,
        minConfidence: Double = 0.6,
        smoothing: Double = 0.3
    ) {
        self.lossFrames = lossFrames
        self.reacquireFrames = reacquireFrames
        self.minConfidence = minConfidence
        self.smoothing = smoothing
    }

    public var isLost: Bool { lost }

    public mutating func ingest(_ raw: HeadPose?) -> Update {
        guard let raw, raw.confidence >= minConfidence else {
            hits = 0
            misses += 1
            smoothed = nil
            guard !lost, misses >= lossFrames else { return Update(pose: nil, event: nil) }
            lost = true
            return Update(pose: nil, event: .inputLost(.faceLost))
        }

        misses = 0
        hits += 1
        smoothed = blend(smoothed, raw)

        guard lost, hits >= reacquireFrames else {
            // While lost, withhold the pose until reacquisition is stable, so a
            // caller cannot act on a face it has not yet trusted.
            return Update(pose: lost ? nil : smoothed, event: nil)
        }
        lost = false
        return Update(pose: smoothed, event: .inputReacquired)
    }

    public mutating func reset() {
        misses = 0
        hits = 0
        lost = false
        smoothed = nil
    }

    private func blend(_ previous: HeadPose?, _ new: HeadPose) -> HeadPose {
        guard let previous, smoothing < 1 else { return new }
        let a = max(0, min(1, smoothing))
        return HeadPose(
            yaw: previous.yaw + a * (new.yaw - previous.yaw),
            pitch: previous.pitch + a * (new.pitch - previous.pitch),
            roll: previous.roll + a * (new.roll - previous.roll),
            faceArea: new.faceArea,
            confidence: new.confidence
        )
    }
}
