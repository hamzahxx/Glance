import Foundation

/// The boundary the real camera/pose pipeline will sit behind (Milestone 2).
///
/// The engine is expected to do its work off the main thread and deliver events
/// back on it; `onEvent` is main-actor-isolated to make that explicit.
@MainActor
public protocol TrackingEngine: AnyObject {
    var onEvent: ((TrackingEvent) -> Void)? { get set }
    func start()
    func stop()
}

/// Milestone 1 stand-in. Reports ready immediately and produces nothing else.
///
/// It exists so the state machine and menu can be exercised end to end before a
/// camera is involved. It does not read a camera and does not move the cursor.
@MainActor
public final class StubTrackingEngine: TrackingEngine {
    public var onEvent: ((TrackingEvent) -> Void)?

    public init() {}

    public func start() {
        // Async so callers observe the real Disabled → Initializing → Tracking
        // sequence rather than a synchronous jump.
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(.engineReady(calibrated: true))
        }
    }

    public func stop() {}
}
