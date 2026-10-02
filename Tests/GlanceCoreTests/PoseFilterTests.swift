import Testing
@testable import GlanceCore

private func pose(_ yaw: Double = 10, confidence: Double = 1) -> HeadPose {
    HeadPose(yaw: yaw, pitch: 0, roll: 0, confidence: confidence)
}

@Test("A face is not lost until enough consecutive frames miss")
func lossNeedsPersistence() {
    var filter = PoseFilter(lossFrames: 5, smoothing: 1)
    for _ in 0..<4 {
        #expect(filter.ingest(nil).event == nil)
        #expect(!filter.isLost)
    }
    #expect(filter.ingest(nil).event == .inputLost(.faceLost))
    #expect(filter.isLost)
}

@Test("A single dropped frame does not lose the face")
func blinkIsNotLoss() {
    var filter = PoseFilter(lossFrames: 5, smoothing: 1)
    for _ in 0..<10 {
        _ = filter.ingest(pose())
        #expect(filter.ingest(nil).event == nil)
    }
    #expect(!filter.isLost)
}

@Test("Loss is announced once, not on every subsequent miss")
func lossIsNotRepeated() {
    var filter = PoseFilter(lossFrames: 2, smoothing: 1)
    _ = filter.ingest(nil)
    #expect(filter.ingest(nil).event == .inputLost(.faceLost))
    for _ in 0..<20 {
        #expect(filter.ingest(nil).event == nil)
    }
}

@Test("Reacquisition requires stability, and withholds pose until then")
func reacquisitionNeedsStability() {
    var filter = PoseFilter(lossFrames: 1, reacquireFrames: 3, smoothing: 1)
    #expect(filter.ingest(nil).event == .inputLost(.faceLost))

    // Pose stays nil while the face is not yet trusted — a caller must not be
    // able to act on it.
    for _ in 0..<2 {
        let update = filter.ingest(pose())
        #expect(update.event == nil)
        #expect(update.pose == nil)
    }
    let recovered = filter.ingest(pose())
    #expect(recovered.event == .inputReacquired)
    #expect(recovered.pose != nil)
}

@Test("Low-confidence detections count as no face at all")
func confidenceGate() {
    // reacquireFrames 1 so this test is about the confidence gate alone, not
    // about the reacquisition hysteresis covered above.
    var filter = PoseFilter(lossFrames: 3, reacquireFrames: 1, minConfidence: 0.6, smoothing: 1)
    for _ in 0..<2 { _ = filter.ingest(pose(confidence: 0.2)) }
    #expect(filter.ingest(pose(confidence: 0.2)).event == .inputLost(.faceLost))
    #expect(filter.ingest(pose(confidence: 0.9)).pose != nil)
}

@Test("Smoothing damps a jump and converges toward it")
func smoothingConverges() {
    var filter = PoseFilter(smoothing: 0.5)
    _ = filter.ingest(pose(0))
    let first = filter.ingest(pose(10)).pose!.yaw
    #expect(first == 5)  // damped, not the raw jump
    let second = filter.ingest(pose(10)).pose!.yaw
    #expect(second > first && second < 10)
}

@Test("Smoothing of 1 passes values straight through")
func smoothingDisabled() {
    var filter = PoseFilter(smoothing: 1)
    _ = filter.ingest(pose(0))
    #expect(filter.ingest(pose(10)).pose!.yaw == 10)
}

@Test("Reset clears loss state")
func resetClears() {
    var filter = PoseFilter(lossFrames: 1, smoothing: 1)
    #expect(filter.ingest(nil).event == .inputLost(.faceLost))
    filter.reset()
    #expect(!filter.isLost)
    #expect(filter.ingest(pose()).pose != nil)
}
