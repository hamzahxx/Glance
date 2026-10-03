import Foundation

/// Lifecycle of the tracking pipeline.
///
/// The single invariant this type exists to protect: cursor movement is
/// permitted in exactly one state. Everything else fails closed.
public enum TrackingState: Equatable, Sendable {
    case disabled
    case initializing
    case calibrating
    case tracking
    case paused(PauseReason)
    case error(String)
}

public enum PauseReason: String, Equatable, Sendable, CaseIterable {
    case faceLost
    case lowConfidence
    case displayChanged
}

/// Everything that can move the pipeline between states.
public enum TrackingEvent: Equatable, Sendable {
    case enable
    case disable
    /// Engine came up. `calibrated` false routes through calibration first.
    case engineReady(calibrated: Bool)
    case calibrationFinished
    /// User asked to recalibrate while already tracking.
    case recalibrate
    case inputLost(PauseReason)
    case inputReacquired
    case failed(String)
    /// Clears a fatal error back to disabled.
    case reset
}

/// How the menu-bar icon reads.
public enum StatusIndicator: Equatable, Sendable {
    case disabled
    case active
    case attentionRequired
}

public extension TrackingState {
    /// The fail-closed gate. Only `.tracking` may move the cursor.
    var allowsCursorMovement: Bool {
        self == .tracking
    }

    /// Never imply tracking is active when it is not.
    var indicator: StatusIndicator {
        switch self {
        case .disabled: .disabled
        case .initializing, .calibrating, .tracking: .active
        case .paused, .error: .attentionRequired
        }
    }

    var isFatal: Bool {
        if case .error = self { return true }
        return false
    }
}

/// Pure transition function. Returns `nil` for events the current state ignores,
/// so callers can distinguish "no-op" from "moved".
public func reduce(_ state: TrackingState, _ event: TrackingEvent) -> TrackingState? {
    switch event {
    // The user must always have direct access to disable tracking.
    case .disable, .reset:
        return state == .disabled ? nil : .disabled

    // Any failure is fatal and stops movement, from any live state.
    case .failed(let message):
        return state == .disabled ? nil : .error(message)

    case .enable:
        return state == .disabled ? .initializing : nil

    case .engineReady(let calibrated):
        guard state == .initializing else { return nil }
        return calibrated ? .tracking : .calibrating

    case .calibrationFinished:
        return state == .calibrating ? .tracking : nil

    case .recalibrate:
        return state == .tracking ? .calibrating : nil

    case .inputLost(let reason):
        return state == .tracking ? .paused(reason) : nil

    // Resume only after stable reacquisition.
    case .inputReacquired:
        if case .paused = state { return .tracking }
        return nil
    }
}

/// What a display change asks of the pipeline.
public enum DisplayChangeAction: Equatable, Sendable {
    case none
    /// Tracking on a mapping that no longer fits: calibrate now.
    case recalibrate
    /// Paused, so nothing moves yet: calibrate once tracking resumes.
    case deferred
}

/// Pure decision behind the display-change handler, so it can be tested
/// without AppKit. Disabled and initializing need nothing: starting the engine
/// asks whether the profile is valid. Calibrating already has the user's eyes.
public func displayChangeAction(isValid: Bool, state: TrackingState) -> DisplayChangeAction {
    guard !isValid else { return .none }
    switch state {
    case .tracking: return .recalibrate
    case .paused: return .deferred
    default: return .none
    }
}
