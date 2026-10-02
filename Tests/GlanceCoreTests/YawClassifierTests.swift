import CoreGraphics
import Testing
@testable import GlanceCore

private func display(
    _ n: UInt32, name: String, yaw: Double, strips: [Double], enabled: Bool, x: CGFloat = 0
) -> (DisplayCalibration, DisplaySnapshot) {
    let id = DisplayIdentifier(vendor: 1, model: n, serial: n)
    let frame = CGRect(x: x, y: 0, width: 1200, height: 900)
    return (
        DisplayCalibration(
            display: id, name: name, bounds: frame, yawMean: yaw,
            strips: strips.enumerated().map {
                StripCalibration(index: $0.offset, yawMean: $0.element, yawStd: 1, sampleCount: 30)
            },
            stripSeparability: enabled ? 0.99 : 0.8,
            stripsEnabled: enabled
        ),
        DisplaySnapshot(id: id, cgID: n, frame: frame, name: name)
    )
}

private let builtIn = display(1, name: "Built-in", yaw: 6, strips: [-4, 6, 16], enabled: true)
private let external = display(2, name: "External", yaw: 36, strips: [20, 36, 50], enabled: false, x: 1200)

private func makeClassifier(margin: Double = 2) -> YawClassifier {
    YawClassifier(
        profile: CalibrationProfile(
            version: CalibrationProfile.currentVersion, createdAt: .init(),
            displays: [builtIn.0, external.0], displaySeparability: 0.99
        ),
        connected: [builtIn.1, external.1],
        margin: margin
    )
}

@Test("Yaw near a display centroid picks that display")
func picksNearestDisplay() throws {
    let classifier = makeClassifier()
    #expect(try #require(classifier.classify(yaw: 6)).displayName == "Built-in")
    #expect(try #require(classifier.classify(yaw: 36)).displayName == "External")
}

@Test("Yaw on the boundary between displays is refused")
func boundaryIsRefused() {
    let classifier = makeClassifier()
    // Midway between 6 and 36; margin is 0 there.
    #expect(classifier.classify(yaw: 21) == nil)
    // …but the diagnostic path still reports the best guess.
    #expect(classifier.nearest(yaw: 21) != nil)
}

@Test("Strips are offered only where the display earned them")
func stripsOnlyWhereEnabled() throws {
    let classifier = makeClassifier()
    let onBuiltIn = try #require(classifier.classify(yaw: -4))
    #expect(onBuiltIn.strip == 0)

    // Same geometry, but this display measured below the threshold.
    let onExternal = try #require(classifier.classify(yaw: 50))
    #expect(onExternal.strip == nil)
    #expect(onExternal.displayName == "External")
}

@Test("A confident display with an ambiguous strip keeps the display")
func ambiguousStripKeepsDisplay() throws {
    let classifier = makeClassifier()
    // Between the built-in's strips at -4 and 6, far from the other display.
    let prediction = try #require(classifier.classify(yaw: 1))
    #expect(prediction.displayName == "Built-in")
    #expect(prediction.strip == nil)
}

@Test("Only connected displays are candidates")
func ignoresDisconnectedDisplays() throws {
    let classifier = YawClassifier(
        profile: CalibrationProfile(
            version: CalibrationProfile.currentVersion, createdAt: .init(),
            displays: [builtIn.0, external.0], displaySeparability: 0.99
        ),
        connected: [builtIn.1]
    )
    // Yaw that would have been the external display now resolves to the only
    // one present, with unbounded margin.
    let prediction = try #require(classifier.classify(yaw: 36))
    #expect(prediction.displayName == "Built-in")
    #expect(prediction.displayMargin == .infinity)
}

@Test("A wider margin refuses more")
func marginIsRespected() {
    #expect(makeClassifier(margin: 2).classify(yaw: 13) != nil)
    #expect(makeClassifier(margin: 9).classify(yaw: 13) == nil)
}

@Test("Target point is the strip centre, or the display centre without strips")
func targetPoints() throws {
    let classifier = makeClassifier()
    let snapshots = [builtIn.1, external.1]

    let left = try #require(classifier.classify(yaw: -4))
    let leftPoint = try #require(classifier.targetPoint(for: left, in: snapshots))
    #expect(leftPoint.x == 200)  // centre of the left third of 0..1200

    let whole = try #require(classifier.classify(yaw: 36))
    let wholePoint = try #require(classifier.targetPoint(for: whole, in: snapshots))
    #expect(wholePoint.x == 1800)  // centre of 1200..2400
}
