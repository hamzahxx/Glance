import CoreGraphics
import Foundation
import Testing
@testable import GlanceCore

private func snap(_ n: UInt32, x: CGFloat = 0, name: String) -> DisplaySnapshot {
    DisplaySnapshot(
        id: DisplayIdentifier(vendor: 1, model: n, serial: n), cgID: n,
        frame: CGRect(x: x, y: 0, width: 1440, height: 900), name: name
    )
}

private func profile(for snapshots: [DisplaySnapshot], created: Date = Date()) -> CalibrationProfile {
    var samples: [CalibrationBuilder.Sample] = []
    for (index, snapshot) in snapshots.enumerated() {
        for round in 0..<2 {
            for strip in 0..<3 {
                for i in 0..<20 {
                    samples.append(.init(
                        display: snapshot.id, strip: strip, round: round,
                        yaw: Double(index) * 40 + Double(strip) * 10 + Double(i % 3) * 0.2
                    ))
                }
            }
        }
    }
    return try! CalibrationBuilder.build(samples: samples, snapshots: snapshots, now: created).get()
}

private let laptop = snap(1, name: "Built-in")
private let homeMonitor = snap(2, x: 1440, name: "Home 4K")
private let officeMonitor = snap(3, x: 1440, name: "Office Ultrawide")

private let home = [laptop, homeMonitor]
private let office = [laptop, officeMonitor]

private func library() -> CalibrationLibrary {
    CalibrationLibrary(profiles: [
        NamedCalibration(name: "Home", profile: profile(for: home, created: Date(timeIntervalSince1970: 1))),
        NamedCalibration(name: "Office", profile: profile(for: office, created: Date(timeIntervalSince1970: 2))),
    ])
}

@Test("The profile matching the connected displays is chosen without being asked")
func autoMatchesDesk() {
    let library = library()
    #expect(library.active(for: home)?.name == "Home")
    #expect(library.active(for: office)?.name == "Office")
}

@Test("A desk with no matching profile selects nothing rather than the wrong one")
func unknownDeskMatchesNothing() {
    let unknown = [laptop, snap(9, x: 1440, name: "Hotel TV")]
    #expect(library().active(for: unknown) == nil)
}

@Test("A pinned profile wins over automatic matching")
func pinningOverridesMatching() {
    var library = library()
    let office = library.profiles.first { $0.name == "Office" }!
    library.pinnedID = office.id
    // Sitting at the home desk, but pinned to Office.
    #expect(library.active(for: home)?.name == "Office")
}

@Test("A pinned profile is returned even where it does not fit, so the mismatch can be explained")
func pinnedMismatchIsVisibleNotSubstituted() {
    var library = library()
    library.pinnedID = library.profiles.first { $0.name == "Office" }!.id
    let active = library.active(for: home)
    #expect(active?.name == "Office")
    // The caller sees it does not apply here rather than silently getting Home.
    #expect(!(active!.profile.validity(against: home).isValid))
}

@Test("Only profiles that fit are offered as candidates")
func candidatesFilterByDesk() {
    #expect(library().candidates(for: home).map(\.name) == ["Home"])
    #expect(library().candidates(for: office).map(\.name) == ["Office"])
}

@Test("Recalibrating replaces a profile in place rather than duplicating it")
func upsertReplaces() {
    var library = library()
    var existing = library.profiles[0]
    existing.name = "Home (relaid out)"
    library.upsert(existing)
    #expect(library.profiles.count == 2)
    #expect(library.profiles[0].name == "Home (relaid out)")
}

@Test("Deleting the pinned profile falls back to automatic matching")
func deletingPinnedClearsPin() {
    var library = library()
    let office = library.profiles.first { $0.name == "Office" }!
    library.pinnedID = office.id
    library.remove(office.id)
    #expect(library.pinnedID == nil)
    #expect(library.profiles.count == 1)
    #expect(library.active(for: home)?.name == "Home")
}

@Test("Suggested names come from the displays")
func suggestedName() {
    #expect(CalibrationLibrary.suggestedName(for: home) == "Built-in + Home 4K")
    #expect(CalibrationLibrary.suggestedName(for: []) == "Setup")
}

// MARK: - Storage and migration

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("glance-test-\(UUID().uuidString).json")
}

@Test("Libraries round-trip through disk")
func libraryRoundTrip() {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = CalibrationLibraryStore(url: url, legacy: CalibrationStore(url: tempURL()))
    var original = library()
    original.pinnedID = original.profiles[1].id
    #expect(store.save(original))

    let loaded = store.load()
    #expect(loaded.profiles.map(\.name) == ["Home", "Office"])
    #expect(loaded.pinnedID == original.pinnedID)
}

@Test("A single pre-library calibration is adopted as a named profile")
func migratesLegacyProfile() {
    let libraryURL = tempURL(), legacyURL = tempURL()
    defer {
        try? FileManager.default.removeItem(at: libraryURL)
        try? FileManager.default.removeItem(at: legacyURL)
    }

    let legacy = CalibrationStore(url: legacyURL)
    #expect(legacy.save(profile(for: home)))

    let store = CalibrationLibraryStore(url: libraryURL, legacy: legacy)
    let migrated = store.load(migrationName: "My desk")
    #expect(migrated.profiles.count == 1)
    #expect(migrated.profiles[0].name == "My desk")
    #expect(migrated.active(for: home)?.name == "My desk")

    // The old file is left in place, and the migration is not repeated.
    #expect(legacy.load() != nil)
    #expect(store.load().profiles.count == 1)
}

@Test("An empty library is returned when there is nothing on disk at all")
func emptyWhenNothingStored() {
    let store = CalibrationLibraryStore(url: tempURL(), legacy: CalibrationStore(url: tempURL()))
    #expect(store.load().profiles.isEmpty)
}
