import Foundation
import Testing
@testable import GlanceCore

private let displayA = DisplayIdentifier(vendor: 1, model: 1, serial: 1)
private let displayB = DisplayIdentifier(vendor: 1, model: 2, serial: 2)

private func prediction(
    _ display: DisplayIdentifier, strip: Int? = nil,
    displayMargin: Double = 20, stripMargin: Double? = nil
) -> YawClassifier.Prediction {
    .init(display: display, displayName: "d", strip: strip,
          displayMargin: displayMargin, stripMargin: stripMargin)
}

/// Idle keyboard unless a test says otherwise.
private let idle = 10.0

@Test("Nothing moves before the dwell period elapses")
func dwellIsRequired() {
    var gate = MovementGate(dwell: 0.4)
    #expect(gate.update(prediction(displayA), now: 0, keyboardIdle: idle) == nil)
    #expect(gate.update(prediction(displayA), now: 0.39, keyboardIdle: idle) == nil)
    #expect(gate.update(prediction(displayA), now: 0.4, keyboardIdle: idle) != nil)
}

@Test("A candidate that changes restarts the dwell clock")
func candidateChangeResetsDwell() {
    var gate = MovementGate(dwell: 0.4)
    _ = gate.update(prediction(displayA), now: 0, keyboardIdle: idle)
    // Switching away at 0.3s restarts the clock, so 0.5s is only 0.2s in.
    _ = gate.update(prediction(displayB), now: 0.3, keyboardIdle: idle)
    #expect(gate.update(prediction(displayB), now: 0.5, keyboardIdle: idle) == nil)
    #expect(gate.update(prediction(displayB), now: 0.8, keyboardIdle: idle) != nil)
}

@Test("The same target is never moved to twice")
func noRepeatedMoves() {
    var gate = MovementGate(dwell: 0.4)
    _ = gate.update(prediction(displayA), now: 0, keyboardIdle: idle)
    #expect(gate.update(prediction(displayA), now: 1, keyboardIdle: idle) != nil)
    // Still looking at it an hour later: no further moves.
    for t in stride(from: 2.0, to: 20.0, by: 1.0) {
        #expect(gate.update(prediction(displayA), now: t, keyboardIdle: idle) == nil)
    }
}

@Test("Losing the face does not cause a repeat move on reacquisition")
func lossDoesNotRepeat() {
    var gate = MovementGate(dwell: 0.4)
    _ = gate.update(prediction(displayA), now: 0, keyboardIdle: idle)
    #expect(gate.update(prediction(displayA), now: 1, keyboardIdle: idle) != nil)

    // Face lost for a while, then back on the same display.
    for t in stride(from: 2.0, to: 5.0, by: 0.5) {
        #expect(gate.update(nil, now: t, keyboardIdle: idle) == nil)
    }
    _ = gate.update(prediction(displayA), now: 5.5, keyboardIdle: idle)
    #expect(gate.update(prediction(displayA), now: 6.5, keyboardIdle: idle) == nil)
}

@Test("Leaving an accepted display needs more confidence than acquiring one")
func hysteresis() {
    var gate = MovementGate(dwell: 0.4, switchMargin: 4)
    _ = gate.update(prediction(displayA, displayMargin: 2), now: 0, keyboardIdle: idle)
    #expect(gate.update(prediction(displayA, displayMargin: 2), now: 1, keyboardIdle: idle) != nil)

    // A marginal competitor does not win, however long it persists.
    for t in stride(from: 2.0, to: 4.0, by: 1.0 / 30) {
        #expect(gate.update(prediction(displayB, displayMargin: 2.5), now: t, keyboardIdle: idle) == nil)
    }

    // A confident one does — but only after holding confidence for a full dwell,
    // not on the first confident frame after that long ambiguous stare.
    #expect(gate.update(prediction(displayB, displayMargin: 9), now: 4, keyboardIdle: idle) == nil)
    #expect(gate.update(prediction(displayB, displayMargin: 9), now: 4.1, keyboardIdle: idle) == nil)
    #expect(gate.update(prediction(displayB, displayMargin: 9), now: 4.5, keyboardIdle: idle) != nil)
}

@Test("An oscillating yaw at a boundary does not produce repeated moves")
func boundaryDoesNotOscillate() {
    var gate = MovementGate(dwell: 0.4, switchMargin: 4)
    var moves = 0
    var now = 0.0
    // Alternate between two displays, both barely past the acquire gate.
    for i in 0..<100 {
        let p = prediction(i % 2 == 0 ? displayA : displayB, displayMargin: 2.1)
        if gate.update(p, now: now, keyboardIdle: idle) != nil { moves += 1 }
        now += 0.5
    }
    // The first target can be acquired; nothing after it clears the switch bar.
    #expect(moves <= 1)
}

@Test("Switching strips within a display is judged on the strip margin")
func stripSwitchUsesStripMargin() {
    var gate = MovementGate(dwell: 0.4, switchMargin: 4)
    _ = gate.update(prediction(displayA, strip: 0, stripMargin: 10), now: 0, keyboardIdle: idle)
    #expect(gate.update(prediction(displayA, strip: 0, stripMargin: 10), now: 1, keyboardIdle: idle) != nil)

    // Same display, different strip, unconvincing strip margin.
    for t in stride(from: 2.0, to: 4.0, by: 1.0 / 30) {
        #expect(gate.update(prediction(displayA, strip: 1, stripMargin: 1), now: t, keyboardIdle: idle) == nil)
    }
    #expect(gate.update(prediction(displayA, strip: 1, stripMargin: 8), now: 4, keyboardIdle: idle) == nil)
    #expect(gate.update(prediction(displayA, strip: 1, stripMargin: 8), now: 4.5, keyboardIdle: idle) != nil)
}

// MARK: - The typing guard

@Test("Focus is withheld while the user is typing, but the cursor still moves")
func typingWithholdsFocus() throws {
    var gate = MovementGate(dwell: 0.4, typingIdle: 0.5)
    _ = gate.update(prediction(displayA), now: 0, keyboardIdle: 0.1)
    // #require wraps its expression in a closure, so the mutating call is hoisted.
    let result = gate.update(prediction(displayA), now: 1, keyboardIdle: 0.1)
    let decision = try #require(result)
    #expect(!decision.activateFocus)
    #expect(decision.target.display == displayA)
}

@Test("Focus is allowed once the keyboard has been idle long enough")
func idleAllowsFocus() throws {
    var gate = MovementGate(dwell: 0.4, typingIdle: 0.5)
    _ = gate.update(prediction(displayA), now: 0, keyboardIdle: 0.6)
    let result = gate.update(prediction(displayA), now: 1, keyboardIdle: 0.6)
    let decision = try #require(result)
    #expect(decision.activateFocus)
}

@Test("The typing threshold is honoured exactly at the boundary")
func typingBoundary() throws {
    var gate = MovementGate(dwell: 0, typingIdle: 0.5)
    let atThreshold = gate.update(prediction(displayA), now: 0, keyboardIdle: 0.5)
    #expect(try #require(atThreshold).activateFocus)

    var other = MovementGate(dwell: 0, typingIdle: 0.5)
    let justUnder = other.update(prediction(displayA), now: 0, keyboardIdle: 0.49)
    #expect(try !#require(justUnder).activateFocus)
}

// MARK: - Reset

@Test("Reset clears the accepted target so the next session can move there again")
func resetAllowsMovingBack() {
    var gate = MovementGate(dwell: 0.4)
    _ = gate.update(prediction(displayA), now: 0, keyboardIdle: idle)
    #expect(gate.update(prediction(displayA), now: 1, keyboardIdle: idle) != nil)

    gate.reset()
    #expect(gate.currentTarget == nil)
    _ = gate.update(prediction(displayA), now: 2, keyboardIdle: idle)
    #expect(gate.update(prediction(displayA), now: 3, keyboardIdle: idle) != nil)
}

@Test("A nil prediction never produces a decision")
func nilNeverMoves() {
    var gate = MovementGate(dwell: 0)
    for t in stride(from: 0.0, to: 10.0, by: 0.1) {
        #expect(gate.update(nil, now: t, keyboardIdle: idle) == nil)
    }
    #expect(gate.currentTarget == nil)
}


@Test("A confidence spike lasting less than the dwell never switches")
func confidenceSpikeIsIgnored() {
    var gate = MovementGate(dwell: 0.4, switchMargin: 4)
    _ = gate.update(prediction(displayA), now: 0, keyboardIdle: idle)
    #expect(gate.update(prediction(displayA), now: 1, keyboardIdle: idle) != nil)

    // 30 fps of the competing display, confident for only 6 frames (0.2s) at a
    // time before dropping back to ambiguous.
    var moves = 0
    var frame = 0
    for t in stride(from: 2.0, to: 12.0, by: 1.0 / 30) {
        let margin = (frame / 6) % 2 == 0 ? 9.0 : 2.5
        if gate.update(prediction(displayB, displayMargin: margin), now: t, keyboardIdle: idle) != nil {
            moves += 1
        }
        frame += 1
    }
    #expect(moves == 0)
}
