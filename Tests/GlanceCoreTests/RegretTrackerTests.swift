import Foundation
import Testing
@testable import GlanceCore

private let a = DisplayIdentifier(vendor: 1, model: 1, serial: 1)
private let b = DisplayIdentifier(vendor: 2, model: 2, serial: 2)
private let day = "2026-10-03"

private func tally(_ t: RegretTracker, _ id: DisplayIdentifier) -> RegretTally {
    t.stats.days[day]?[RegretStats.key(id)] ?? RegretTally()
}

@Test("Pointer back on another display within 2 s is a hand revert for the target")
func handRevertWithinWindow() {
    var t = RegretTracker()
    t.recordMove(to: b, at: 10, day: day)
    #expect(t.observeUserPointer(on: a, at: 11) == RegretEvent(kind: .handRevert, display: b))
    #expect(tally(t, b) == RegretTally(moves: 1, handReverts: 1))
}

@Test("Pointer back after the window is not a regret")
func handRevertAfterWindow() {
    var t = RegretTracker()
    t.recordMove(to: b, at: 10, day: day)
    #expect(t.observeUserPointer(on: a, at: 12.5) == nil)
    #expect(tally(t, b) == RegretTally(moves: 1))
}

@Test("Pointer moving within the target is not a regret")
func pointerWithinTarget() {
    var t = RegretTracker()
    t.recordMove(to: b, at: 10, day: day)
    #expect(t.observeUserPointer(on: b, at: 10.5) == nil)
    #expect(t.observeUserPointer(on: b, at: 11) == nil)
    #expect(tally(t, b).handReverts == 0)
}

@Test("Moving away within 1.5 s is a bounce; after it, not")
func bounceWindow() {
    var t = RegretTracker()
    t.recordMove(to: b, at: 10, day: day)
    #expect(t.recordMove(to: a, at: 11, day: day) == RegretEvent(kind: .bounce, display: b))
    #expect(tally(t, b) == RegretTally(moves: 1, bounces: 1))

    var late = RegretTracker()
    late.recordMove(to: b, at: 10, day: day)
    #expect(late.recordMove(to: a, at: 12, day: day) == nil)
    #expect(tally(late, b).bounces == 0)
}

@Test("Only pointer positions the caller passes count; no pointer, no regret")
func onlyUserPointerCounts() {
    // The app never passes Glance's own warp; a pointer off every display is nil.
    var t = RegretTracker()
    t.recordMove(to: b, at: 10, day: day)
    #expect(t.observeUserPointer(on: nil, at: 10.5) == nil)
    #expect(tally(t, b) == RegretTally(moves: 1))
}

@Test("A move both reverted and bounced counts once, as a hand revert")
func revertBeatsBounce() {
    var t = RegretTracker()
    t.recordMove(to: b, at: 10, day: day)
    t.observeUserPointer(on: a, at: 10.5)
    #expect(t.recordMove(to: a, at: 11, day: day) == nil)
    #expect(tally(t, b) == RegretTally(moves: 1, handReverts: 1))
    #expect(t.stats.total(day: day) == RegretTally(moves: 2, handReverts: 1))
    #expect(t.stats.total(day: day).percent == 50)
}

@Test("Stats round-trip, prune past 30 days, and survive a corrupt file")
func regretStatsPersistence() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("regret-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = RegretStatsStore(url: url)
    #expect(store.load() == RegretStats())

    var stats = RegretStats()
    stats.days["2026-10-03"] = ["k": RegretTally(moves: 3, handReverts: 1)]
    stats.days["2026-09-04"] = ["k": RegretTally(moves: 1)]  // 29 days back: kept
    stats.days["2026-09-03"] = ["k": RegretTally(moves: 1)]  // 30 days back: dropped
    let today = try #require(ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z"))
    #expect(store.save(stats, today: today))
    let loaded = store.load()
    #expect(loaded.days["2026-10-03"] == stats.days["2026-10-03"])
    #expect(loaded.days["2026-09-04"] != nil)
    #expect(loaded.days["2026-09-03"] == nil)

    try Data("not json".utf8).write(to: url)
    #expect(store.load() == RegretStats())
}

@Test("With the cursor left behind, nudging it on the old display is not a revert")
func noRevertWithoutLeavingTarget() {
    var t = RegretTracker()
    t.observeUserPointer(on: a, at: 9)
    t.recordMove(to: b, at: 10, day: day, pointerMoved: false)
    #expect(t.observeUserPointer(on: a, at: 10.5) == nil)
    #expect(t.observeUserPointer(on: a, at: 11) == nil)
    #expect(tally(t, b).handReverts == 0)
}

@Test("Pointer on the target, then off it within 2 s, is a revert")
func revertAfterUsingTarget() {
    var t = RegretTracker()
    t.recordMove(to: b, at: 10, day: day, pointerMoved: false)
    #expect(t.observeUserPointer(on: b, at: 10.5) == nil)
    #expect(t.observeUserPointer(on: a, at: 11) == RegretEvent(kind: .handRevert, display: b))
}
