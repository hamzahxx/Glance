import CoreGraphics
import Foundation
import Testing
@testable import GlanceCore

private let builtInID = DisplayIdentifier(vendor: 1, model: 1, serial: 1)
private let externalID = DisplayIdentifier(vendor: 1, model: 2, serial: 2)

/// Mirrors the real desk: a 2560-wide external entirely left of the built-in.
private let builtIn = DisplaySnapshot(
    id: builtInID, cgID: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), name: "Built-in"
)
private let external = DisplaySnapshot(
    id: externalID, cgID: 2, frame: CGRect(x: -2560, y: -256, width: 2560, height: 1080), name: "External"
)
private let displays = [builtIn, external]

@Test("A recorded point comes back for its own display")
func recallsPerDisplay() {
    var memory = CursorMemory()
    memory.record(CGPoint(x: 700, y: 400), displays: displays)
    memory.record(CGPoint(x: -2400, y: 300), displays: displays)

    #expect(memory.position(for: builtInID, displays: displays) == CGPoint(x: 700, y: 400))
    #expect(memory.position(for: externalID, displays: displays) == CGPoint(x: -2400, y: 300))
}

@Test("The far-left window on a wide monitor is remembered, not the centre")
func remembersFarLeft() {
    var memory = CursorMemory()
    // Working in a window at the left edge of the 2560-wide external.
    let farLeft = CGPoint(x: -2450, y: 500)
    memory.record(farLeft, displays: displays)
    #expect(memory.position(for: externalID, displays: displays) == farLeft)
    // Which is nowhere near the centre that would otherwise be targeted.
    #expect(external.center.x == -1280)
}

@Test("Nothing is remembered for a display the pointer has not visited")
func unvisitedDisplayHasNoMemory() {
    var memory = CursorMemory()
    memory.record(CGPoint(x: 700, y: 400), displays: displays)
    #expect(memory.position(for: externalID, displays: displays) == nil)
}

@Test("A point on no display is ignored")
func pointOutsideEveryDisplay() {
    var memory = CursorMemory()
    memory.record(CGPoint(x: 99_999, y: 99_999), displays: displays)
    #expect(memory.position(for: builtInID, displays: displays) == nil)
    #expect(memory.position(for: externalID, displays: displays) == nil)
}

@Test("The latest position wins")
func latestWins() {
    var memory = CursorMemory()
    memory.record(CGPoint(x: 100, y: 100), displays: displays)
    memory.record(CGPoint(x: 900, y: 500), displays: displays)
    #expect(memory.position(for: builtInID, displays: displays) == CGPoint(x: 900, y: 500))
}

@Test("A display that shrinks forgets a point now outside it")
func resizeInvalidatesMemory() {
    var memory = CursorMemory()
    memory.record(CGPoint(x: -2400, y: 300), displays: displays)

    // Same display, now a smaller resolution that no longer covers that point.
    var smaller = external
    smaller.frame = CGRect(x: -1280, y: 0, width: 1280, height: 720)
    #expect(memory.position(for: externalID, displays: [builtIn, smaller]) == nil)
}

@Test("A disconnected display yields nothing rather than a stale point")
func disconnectedDisplay() {
    var memory = CursorMemory()
    memory.record(CGPoint(x: -2400, y: 300), displays: displays)
    #expect(memory.position(for: externalID, displays: [builtIn]) == nil)
}

@Test("Forgetting clears everything")
func forgetAll() {
    var memory = CursorMemory()
    memory.record(CGPoint(x: 700, y: 400), displays: displays)
    memory.forgetAll()
    #expect(memory.position(for: builtInID, displays: displays) == nil)
}

// MARK: - Inferred positions

@Test("An inferred position is used when nothing was observed")
func inferredUsedWhenNoObservation() {
    var memory = CursorMemory()
    let windowCentre = CGPoint(x: -2100, y: 400)
    memory.recordInferred(windowCentre, for: externalID, displays: displays)
    #expect(memory.position(for: externalID, displays: displays) == windowCentre)
    #expect(!memory.hasObserved(externalID))
}

@Test("An observed position always beats an inferred one")
func observedBeatsInferred() {
    var memory = CursorMemory()
    memory.recordInferred(CGPoint(x: -2100, y: 400), for: externalID, displays: displays)
    let byHand = CGPoint(x: -1500, y: 700)
    memory.record(byHand, displays: displays)
    #expect(memory.position(for: externalID, displays: displays) == byHand)
    #expect(memory.hasObserved(externalID))

    // A later inference must not clobber what the user actually did.
    memory.recordInferred(CGPoint(x: -2400, y: 200), for: externalID, displays: displays)
    #expect(memory.position(for: externalID, displays: displays) == byHand)
}

@Test("An inferred point outside the display is rejected")
func inferredMustBeOnTheDisplay() {
    var memory = CursorMemory()
    memory.recordInferred(CGPoint(x: 700, y: 400), for: externalID, displays: displays)
    #expect(memory.position(for: externalID, displays: displays) == nil)
}

@Test("A resized display drops an inferred point that no longer fits")
func resizeInvalidatesInferred() {
    var memory = CursorMemory()
    memory.recordInferred(CGPoint(x: -2400, y: 300), for: externalID, displays: displays)
    var smaller = external
    smaller.frame = CGRect(x: -1280, y: 0, width: 1280, height: 720)
    #expect(memory.position(for: externalID, displays: [builtIn, smaller]) == nil)
}

// MARK: - Persistence

@Test("Memory survives a relaunch, keeping observed and inferred apart")
func memoryPersists() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("glance-memory-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = CursorMemoryStore(url: url)
    #expect(store.load().position(for: builtInID, displays: displays) == nil)

    var memory = CursorMemory()
    memory.record(CGPoint(x: 700, y: 400), displays: displays)
    memory.recordInferred(CGPoint(x: -2100, y: 400), for: externalID, displays: displays)
    #expect(store.save(memory))

    let loaded = store.load()
    #expect(loaded.position(for: builtInID, displays: displays) == CGPoint(x: 700, y: 400))
    #expect(loaded.position(for: externalID, displays: displays) == CGPoint(x: -2100, y: 400))
    #expect(loaded.hasObserved(builtInID))
    #expect(!loaded.hasObserved(externalID))
}

@Test("A corrupt memory file reads as empty rather than crashing")
func corruptMemoryFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("glance-memory-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("not json".utf8).write(to: url)
    #expect(CursorMemoryStore(url: url).load().position(for: builtInID, displays: displays) == nil)
}
