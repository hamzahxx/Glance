import CoreGraphics
import Foundation

/// Maps a head yaw onto a display, and a strip within it where that display
/// earned strips.
///
/// One dimension by design. The 2026-09-30 probe measured pitch as actively
/// harmful — including it dropped display accuracy from 99.7% to 89.1% — so
/// pitch is captured for diagnostics and never classified on.
public struct YawClassifier: Sendable {
    public struct Prediction: Equatable, Sendable {
        public var display: DisplayIdentifier
        public var displayName: String
        /// Nil when this display has no strips, or when the strip was too close
        /// to call. The display is still usable in that case.
        public var strip: Int?
        /// Degrees of yaw to the nearest competing display. Large is confident.
        public var displayMargin: Double
        public var stripMargin: Double?
    }

    /// Half-gap below which two classes are too close to call. Measured: a ±2°
    /// gate removed every display error in the probe data while keeping 92% of
    /// samples.
    public static let defaultMargin = 2.0

    private let profile: CalibrationProfile
    private let margin: Double
    /// Only displays that are currently connected are candidates.
    private let candidates: [DisplayCalibration]

    public init(profile: CalibrationProfile, connected: [DisplaySnapshot], margin: Double = YawClassifier.defaultMargin) {
        self.profile = profile
        self.margin = margin
        let live = Set(connected.map(\.id))
        candidates = profile.displays.filter { live.contains($0.display) }
    }

    /// Best guess with no gating, for diagnostics and menu display.
    public func nearest(yaw: Double) -> Prediction? {
        guard let display = candidates.min(by: {
            abs(yaw - $0.yawMean) < abs(yaw - $1.yawMean)
        }) else { return nil }

        let displayMargin = halfGap(yaw, candidates.map(\.yawMean))
        var strip: Int?
        var stripMargin: Double?
        if display.stripsEnabled, !display.strips.isEmpty {
            let means = display.strips.map(\.yawMean)
            strip = display.strips.min { abs(yaw - $0.yawMean) < abs(yaw - $1.yawMean) }?.index
            stripMargin = halfGap(yaw, means)
        }
        return Prediction(
            display: display.display,
            displayName: display.name,
            strip: strip,
            displayMargin: displayMargin,
            stripMargin: stripMargin
        )
    }

    /// Gated result. Returns nil when the display itself is too close to call —
    /// that is the sample the app must refuse to act on. A confident display
    /// with an unconvincing strip keeps the display and drops the strip.
    public func classify(yaw: Double) -> Prediction? {
        guard var prediction = nearest(yaw: yaw) else { return nil }
        guard prediction.displayMargin >= margin else { return nil }
        if let stripMargin = prediction.stripMargin, stripMargin < margin {
            prediction.strip = nil
        }
        return prediction
    }

    /// Where the cursor would go. Milestone 4 consumes this; nothing moves yet.
    public func targetPoint(for prediction: Prediction, in snapshots: [DisplaySnapshot]) -> CGPoint? {
        guard let snapshot = snapshots.first(where: { $0.id == prediction.display }) else { return nil }
        guard let strip = prediction.strip else { return snapshot.center }
        return snapshot.stripCenter(strip)
    }

    /// Half the distance between the nearest and second-nearest centroid.
    /// A single candidate is unambiguous, so its margin is unbounded.
    private func halfGap(_ value: Double, _ centroids: [Double]) -> Double {
        guard centroids.count > 1 else { return .infinity }
        let sorted = centroids.map { abs(value - $0) }.sorted()
        return (sorted[1] - sorted[0]) / 2
    }
}
