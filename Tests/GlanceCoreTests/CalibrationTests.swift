import CoreGraphics
import Foundation
import Testing
@testable import GlanceCore

private func identifier(_ n: UInt32) -> DisplayIdentifier {
    DisplayIdentifier(vendor: 1, model: n, serial: n)
}

private func snapshot(_ n: UInt32, x: CGFloat = 0, name: String = "Display") -> DisplaySnapshot {
    DisplaySnapshot(
        id: identifier(n), cgID: n,
        frame: CGRect(x: x, y: 0, width: 1440, height: 900), name: name
    )
}

/// Two rounds of samples for one display, strips centred at the given yaws.
private func samples(
    display: DisplayIdentifier, centres: [Double], spread: Double = 0.5, count: Int = 20
) -> [CalibrationBuilder.Sample] {
    var out: [CalibrationBuilder.Sample] = []
    for round in 0..<2 {
        for (strip, centre) in centres.enumerated() {
            for i in 0..<count {
                // Deterministic spread, alternating either side of the centre.
                let offset = (Double(i % 5) - 2) / 2 * spread
                out.append(.init(display: display, strip: strip, round: round, yaw: centre + offset))
            }
        }
    }
    return out
}

// MARK: - Building

@Test("Well-separated strips are enabled")
func stripsEnabledWhenSeparable() throws {
    let screen = snapshot(1)
    let result = CalibrationBuilder.build(
        samples: samples(display: screen.id, centres: [-12, 0, 12]),
        snapshots: [screen],
        allowStrips: true
    )
    let profile = try #require(try? result.get())
    let display = try #require(profile.displays.first)
    #expect(display.stripsEnabled)
    #expect(display.stripSeparability == 1.0)
    #expect(display.strips.count == 3)
    #expect(abs(display.strips[1].yawMean) < 0.001)
}

@Test("Overlapping strips are measured as inseparable and disabled")
func stripsDisabledWhenOverlapping() throws {
    let screen = snapshot(1)
    // Centres 0.5° apart with 4° of spread: genuinely not separable, which is
    // what the external monitor looked like in the real probe.
    let result = CalibrationBuilder.build(
        samples: samples(display: screen.id, centres: [0, 0.5, 1.0], spread: 8),
        snapshots: [screen],
        allowStrips: true
    )
    let profile = try #require(try? result.get())
    let display = try #require(profile.displays.first)
    #expect(!display.stripsEnabled)
    #expect(display.stripSeparability < CalibrationProfile.stripEligibilityThreshold)
}

@Test("A display with too few samples fails rather than saving a thin profile")
func tooFewSamplesFails() {
    let screen = snapshot(1)
    let thin = samples(display: screen.id, centres: [-12, 0, 12], count: 2)
    let result = CalibrationBuilder.build(samples: thin, snapshots: [screen])
    guard case .failure(let error) = result else {
        Issue.record("expected failure")
        return
    }
    #expect(error != .noSamples)
}

@Test("No samples is a failure, not an empty profile")
func noSamplesFails() {
    #expect(CalibrationBuilder.build(samples: [], snapshots: [snapshot(1)]) == .failure(.noSamples))
}

@Test("Separability is held out, so fitting noise does not score perfectly")
func separabilityIsHeldOut() {
    // Same centre for every strip: nothing to separate, whatever the spread.
    let screen = snapshot(1)
    let result = CalibrationBuilder.build(
        samples: samples(display: screen.id, centres: [0, 0, 0], spread: 2),
        snapshots: [screen]
    )
    let profile = try! result.get()
    #expect(profile.displays[0].stripSeparability < 0.6)
}

@Test("Two well-separated displays measure as separable")
func displaySeparability() throws {
    let a = snapshot(1, name: "Built-in"), b = snapshot(2, x: 1440, name: "External")
    let result = CalibrationBuilder.build(
        samples: samples(display: a.id, centres: [-10, 0, 10])
            + samples(display: b.id, centres: [40, 50, 60]),
        snapshots: [a, b]
    )
    let profile = try #require(try? result.get())
    #expect(profile.displaySeparability == 1.0)
    #expect(profile.displays.count == 2)
}

// MARK: - Validity

@Test("A profile is invalid when a connected display was never calibrated")
func uncalibratedDisplayIsInvalid() throws {
    let a = snapshot(1), b = snapshot(2, x: 1440, name: "New monitor")
    let profile = try #require(try? CalibrationBuilder.build(
        samples: samples(display: a.id, centres: [-10, 0, 10]), snapshots: [a]
    ).get())

    #expect(profile.validity(against: [a]) == .valid)
    #expect(profile.validity(against: [a, b]) == .uncalibratedDisplay("New monitor"))
}

@Test("Moving a display invalidates the mapping built against it")
func geometryChangeIsInvalid() throws {
    let a = snapshot(1, name: "Built-in")
    let profile = try #require(try? CalibrationBuilder.build(
        samples: samples(display: a.id, centres: [-10, 0, 10]), snapshots: [a]
    ).get())

    var moved = a
    moved.frame = CGRect(x: 500, y: 0, width: 1440, height: 900)
    #expect(profile.validity(against: [moved]) == .geometryChanged("Built-in"))
}

@Test("A disconnected display does not invalidate the others")
func disconnectLeavesOthersValid() throws {
    let a = snapshot(1), b = snapshot(2, x: 1440)
    let profile = try #require(try? CalibrationBuilder.build(
        samples: samples(display: a.id, centres: [-10, 0, 10])
            + samples(display: b.id, centres: [40, 50, 60]),
        snapshots: [a, b]
    ).get())
    #expect(profile.validity(against: [a]) == .valid)
}

@Test("Inseparable displays make the whole profile unusable")
func inseparableDisplaysAreUnusable() throws {
    let a = snapshot(1), b = snapshot(2, x: 1440)
    let profile = try #require(try? CalibrationBuilder.build(
        samples: samples(display: a.id, centres: [0, 1, 2], spread: 6)
            + samples(display: b.id, centres: [1, 2, 3], spread: 6),
        snapshots: [a, b]
    ).get())
    if case .unusable = profile.validity(against: [a, b]) {} else {
        Issue.record("expected .unusable, got \(profile.validity(against: [a, b]))")
    }
}

@Test("An older profile version is rejected rather than misread")
func versionMismatch() throws {
    var profile = try #require(try? CalibrationBuilder.build(
        samples: samples(display: snapshot(1).id, centres: [-10, 0, 10]),
        snapshots: [snapshot(1)]
    ).get())
    profile.version = 0
    #expect(profile.validity(against: [snapshot(1)]) == .outdated)
}

// MARK: - Store

@Test("Profiles round-trip through disk")
func storeRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("glance-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = CalibrationStore(url: url)
    #expect(store.load() == nil)

    let profile = try #require(try? CalibrationBuilder.build(
        samples: samples(display: snapshot(1).id, centres: [-10, 0, 10]),
        snapshots: [snapshot(1)]
    ).get())
    #expect(store.save(profile))

    let loaded = try #require(store.load())
    #expect(loaded.displays == profile.displays)
    #expect(loaded.displaySeparability == profile.displaySeparability)
}

@Test("A corrupt profile reads as missing rather than crashing")
func corruptStore() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("glance-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("not json".utf8).write(to: url)
    #expect(CalibrationStore(url: url).load() == nil)
}


@Test("Strips stay off unless explicitly allowed, however separable they measure")
func stripsAreOptIn() throws {
    let screen = snapshot(1)
    let profile = try #require(try? CalibrationBuilder.build(
        samples: samples(display: screen.id, centres: [-12, 0, 12]), snapshots: [screen]
    ).get())
    let display = try #require(profile.displays.first)
    // Still measured, just not acted on.
    #expect(display.stripSeparability == 1.0)
    #expect(!display.stripsEnabled)
}

@Test("Separability is scored dwell-averaged, matching how the app decides")
func separabilityIsDwellAveraged() throws {
    let screen = snapshot(1)
    // Centres 6° apart with ±6° of frame-to-frame noise: badly separable per
    // frame, clearly separable once averaged over a dwell — which is the only
    // way the app ever acts on it.
    var noisy: [CalibrationBuilder.Sample] = []
    for round in 0..<2 {
        for strip in 0..<3 {
            for i in 0..<60 {
                let wobble = Double((i * 37) % 13) - 6
                noisy.append(.init(display: screen.id, strip: strip, round: round,
                                   yaw: Double(strip) * 6 + wobble))
            }
        }
    }
    let perFrame = CalibrationBuilder.heldOutAccuracy(
        train: Dictionary(grouping: noisy.filter { $0.round == 0 }, by: \.strip).mapValues { $0.map(\.yaw) },
        test: Dictionary(grouping: noisy.filter { $0.round > 0 }, by: \.strip).mapValues { $0.map(\.yaw) }
    )
    let profile = try #require(try? CalibrationBuilder.build(
        samples: noisy, snapshots: [screen], allowStrips: true
    ).get())

    #expect(perFrame < 0.8)
    #expect(profile.displays[0].stripSeparability > perFrame)
}

@Test("A short burst still contributes rather than scoring as nothing")
func shortBurstStillScored() {
    let screen = snapshot(1)
    // Fewer samples per strip than the dwell window.
    let short = samples(display: screen.id, centres: [-12, 0, 12], count: 11)
    let result = CalibrationBuilder.build(samples: short, snapshots: [screen], allowStrips: true)
    let profile = try! result.get()
    #expect(profile.displays[0].stripSeparability > 0)
}
