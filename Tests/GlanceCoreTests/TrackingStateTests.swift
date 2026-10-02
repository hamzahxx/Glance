import Testing
@testable import GlanceCore

// MARK: - The fail-closed invariant

@Test("Only .tracking permits cursor movement")
func onlyTrackingAllowsMovement() {
    let states: [TrackingState] = [
        .disabled, .initializing, .calibrating, .tracking,
        .paused(.faceLost), .paused(.lowConfidence), .paused(.displayChanged),
        .error("boom"),
    ]
    for state in states {
        #expect(state.allowsCursorMovement == (state == .tracking), "\(state)")
    }
}

@Test("No event sequence reaches a movement-allowed state without the engine reporting ready")
func movementRequiresEngineReady() {
    // Everything except .engineReady(calibrated: true) / .calibrationFinished.
    let events: [TrackingEvent] = [
        .enable, .disable, .reset, .inputReacquired,
        .inputLost(.faceLost), .failed("x"), .engineReady(calibrated: false),
    ]
    var state = TrackingState.disabled
    for _ in 0..<4 {
        for event in events {
            state = reduce(state, event) ?? state
            #expect(!state.allowsCursorMovement, "reached \(state) via \(event)")
        }
    }
}

// MARK: - Transitions

@Test("Happy path: disabled → initializing → tracking")
func happyPath() {
    #expect(reduce(.disabled, .enable) == .initializing)
    #expect(reduce(.initializing, .engineReady(calibrated: true)) == .tracking)
}

@Test("Uncalibrated engine routes through calibration")
func calibrationPath() {
    #expect(reduce(.initializing, .engineReady(calibrated: false)) == .calibrating)
    #expect(reduce(.calibrating, .calibrationFinished) == .tracking)
}

@Test("Pause and reacquisition", arguments: PauseReason.allCases)
func pauseAndResume(reason: PauseReason) {
    #expect(reduce(.tracking, .inputLost(reason)) == .paused(reason))
    #expect(reduce(.paused(reason), .inputReacquired) == .tracking)
    // Pausing is only meaningful from tracking.
    #expect(reduce(.calibrating, .inputLost(reason)) == nil)
}

@Test("Disable reaches .disabled from every live state")
func disableAlwaysWins() {
    let live: [TrackingState] = [
        .initializing, .calibrating, .tracking, .paused(.faceLost), .error("boom"),
    ]
    for state in live {
        #expect(reduce(state, .disable) == .disabled, "\(state)")
        #expect(reduce(state, .reset) == .disabled, "\(state)")
    }
    #expect(reduce(.disabled, .disable) == nil)
}

@Test("Failure is fatal from every live state")
func failureIsFatal() {
    let live: [TrackingState] = [.initializing, .calibrating, .tracking, .paused(.faceLost)]
    for state in live {
        #expect(reduce(state, .failed("engine crash")) == .error("engine crash"), "\(state)")
    }
    // A disabled app has nothing to fail.
    #expect(reduce(.disabled, .failed("engine crash")) == nil)
}

@Test("Out-of-order events are ignored")
func invalidTransitionsAreIgnored() {
    #expect(reduce(.tracking, .enable) == nil)
    #expect(reduce(.disabled, .engineReady(calibrated: true)) == nil)
    #expect(reduce(.tracking, .calibrationFinished) == nil)
    #expect(reduce(.tracking, .inputReacquired) == nil)
    #expect(reduce(.disabled, .inputLost(.faceLost)) == nil)
}

// MARK: - Indicator

@Test("Paused and error never read as active")
func indicatorHonesty() {
    #expect(TrackingState.disabled.indicator == .disabled)
    #expect(TrackingState.tracking.indicator == .active)
    #expect(TrackingState.initializing.indicator == .active)
    #expect(TrackingState.calibrating.indicator == .active)
    #expect(TrackingState.paused(.faceLost).indicator == .attentionRequired)
    #expect(TrackingState.error("boom").indicator == .attentionRequired)
}
