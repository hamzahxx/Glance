import AVFoundation
import Foundation

public enum CameraStatus: Equatable, Sendable {
    case notRequested
    case authorized
    case denied
    case unavailable(String)

    public var summary: String {
        switch self {
        case .notRequested: "not requested"
        case .authorized: "ready"
        case .denied: "access denied"
        case .unavailable(let why): "unavailable — \(why)"
        }
    }
}

/// Milestone 2: real camera, real head pose, no calibration and no cursor.
///
/// Everything camera-side runs on the capture queue; every callback out of this
/// type is delivered on the main actor.
@MainActor
public final class VisionTrackingEngine: TrackingEngine {
    public var onEvent: ((TrackingEvent) -> Void)?
    /// Latest smoothed pose, or nil when no face is trusted. Diagnostics only.
    public var onPose: ((HeadPose?) -> Void)?
    public var onCameraStatus: ((CameraStatus) -> Void)?
    /// Every frame's raw reading, before smoothing and before the confidence
    /// gate. Diagnostics only — nothing should act on this.
    public var onRawPose: ((HeadPose?) -> Void)?

    public private(set) var cameraStatus: CameraStatus = .notRequested {
        didSet { if cameraStatus != oldValue { onCameraStatus?(cameraStatus) } }
    }
    public private(set) var latestPose: HeadPose?
    /// Raw frame counters, for diagnostics and for the face-availability number
    /// the probe reports. Not reset by pause, only by stop.
    public private(set) var framesSeen = 0
    public private(set) var framesWithFace = 0
    public var deviceName: String { capture.deviceName }

    /// Answers "may tracking start, or is calibration required first?".
    /// Defaults to refusing: an unwired app demands calibration rather than
    /// silently tracking against nothing.
    public var isCalibrated: () -> Bool = { false }

    private let capture = PoseCapture()
    private var filter: PoseFilter
    private var running = false

    public init(settings: Settings = Settings()) {
        filter = PoseFilter(
            minConfidence: settings.confidenceThreshold,
            smoothing: settings.smoothingEnabled ? 0.3 : 1.0
        )
    }

    /// The confidence below which a detection is discarded as no face at all.
    public var confidenceThreshold: Double { filter.minConfidence }

    public func apply(_ settings: Settings) {
        filter.minConfidence = settings.confidenceThreshold
        filter.smoothing = settings.smoothingEnabled ? 0.3 : 1.0
    }

    public func start() {
        guard !running else { return }
        capture.onPose = { [weak self] pose in
            Task { @MainActor in self?.ingest(pose) }
        }
        capture.onFailure = { [weak self] reason in
            Task { @MainActor in self?.fail(reason) }
        }

        Task { @MainActor in
            guard await capture.requestPermission() else {
                cameraStatus = .denied
                // Fail closed: a denied camera is an error state, not a quiet no-op.
                onEvent?(.failed("Camera access denied. Grant it in System Settings › Privacy & Security › Camera."))
                return
            }
            cameraStatus = .authorized
            do {
                try capture.start()
                running = true
                onEvent?(.engineReady(calibrated: isCalibrated()))
            } catch {
                cameraStatus = .unavailable("\(error)")
                onEvent?(.failed("\(error)"))
            }
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        capture.stop()
        capture.onPose = nil
        capture.onFailure = nil
        filter.reset()
        framesSeen = 0
        framesWithFace = 0
        latestPose = nil
        onPose?(nil)
    }

    private func ingest(_ raw: HeadPose?) {
        guard running else { return }
        framesSeen += 1
        if raw != nil { framesWithFace += 1 }
        onRawPose?(raw)
        let update = filter.ingest(raw)
        if update.pose != latestPose {
            latestPose = update.pose
            onPose?(update.pose)
        }
        if let event = update.event { onEvent?(event) }
    }

    private func fail(_ reason: String) {
        guard running else { return }
        running = false
        capture.stop()
        cameraStatus = .unavailable(reason)
        latestPose = nil
        onPose?(nil)
        onEvent?(.failed(reason))
    }
}
