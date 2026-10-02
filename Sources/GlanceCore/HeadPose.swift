import Foundation

/// One head-orientation reading. Angles in degrees.
///
/// This is head pose, not gaze: it describes where the head is pointing, and
/// says nothing about where the eyes are looking. The 2026-09-30 probe is the
/// reason the pipeline uses yaw alone: pitch measured as noise, and including
/// it dropped display accuracy from 99.7% to 89.1%.
public struct HeadPose: Sendable, Equatable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    /// Face box area as a fraction of the frame; a cheap proxy for posture drift.
    public var faceArea: Double
    /// Vision's own confidence in the detection, 0...1.
    public var confidence: Double

    public init(
        yaw: Double, pitch: Double, roll: Double,
        faceArea: Double = 0, confidence: Double = 1
    ) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.faceArea = faceArea
        self.confidence = confidence
    }
}
