import CoreGraphics
import Foundation
import Testing
@testable import GlanceCore

private func display(_ cgID: UInt32, x: Double, serial: UInt32 = 0) -> DisplaySnapshot {
    DisplaySnapshot(
        id: DisplayIdentifier(vendor: 7, model: 9, serial: serial),
        cgID: cgID,
        frame: CGRect(x: x, y: 0, width: 1920, height: 1080)
    )
}

@Test("Identical monitors get distinct identities, numbered left to right")
func identicalMonitorsAreDisambiguated() {
    // Listed right-first to prove ordering comes from position, not list order.
    let result = DisplayGeometry.disambiguated([display(2, x: 1920), display(1, x: 0)])
    #expect(result.map(\.cgID) == [2, 1])
    #expect(result.map(\.id.index) == [1, 0])
    #expect(Set(result.map(\.id)).count == 2)
}

@Test("Displays without a twin keep index 0")
func distinctMonitorsAreUntouched() {
    let input = [display(1, x: 0, serial: 1), display(2, x: 1920, serial: 2)]
    #expect(DisplayGeometry.disambiguated(input) == input)
}

@Test("Identifiers saved before the tiebreaker still decode")
func legacyIdentifierDecodes() throws {
    let json = Data(#"{"vendor":7,"model":9,"serial":0}"#.utf8)
    let id = try JSONDecoder().decode(DisplayIdentifier.self, from: json)
    #expect(id == DisplayIdentifier(vendor: 7, model: 9, serial: 0))

    let roundTrip = DisplayIdentifier(vendor: 7, model: 9, serial: 0, index: 1)
    let decoded = try JSONDecoder().decode(
        DisplayIdentifier.self, from: JSONEncoder().encode(roundTrip)
    )
    #expect(decoded == roundTrip)
}
