import Foundation
import Testing
@testable import GlanceCore

private func freshDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    UserDefaults(suiteName: name)!
}

@Test("Defaults match the PRD")
func prdDefaults() {
    let s = Settings()
    #expect(s.dwellMs == 400)
    #expect(s.smoothingEnabled)
}

@Test("Out-of-range values are clamped, not rejected")
func clamping() {
    var s = Settings(dwellMs: 999_999, confidenceThreshold: 5.0)
    s.smoothingEnabled = false
    let v = s.validated()
    #expect(v.dwellMs == Settings.dwellRange.upperBound)
    #expect(v.confidenceThreshold == Settings.confidenceRange.upperBound)
    // Unrelated settings survive a bad neighbour.
    #expect(!v.smoothingEnabled)

    let low = Settings(dwellMs: 0, confidenceThreshold: -1).validated()
    #expect(low.dwellMs == Settings.dwellRange.lowerBound)
    #expect(low.confidenceThreshold == Settings.confidenceRange.lowerBound)

    #expect(Settings(confidenceThreshold: .nan).validated().confidenceThreshold == 0.6)
}

@Test("Round trip")
func roundTrip() {
    let defaults = freshDefaults()
    let store = SettingsStore(defaults: defaults)
    store.save(Settings(dwellMs: 750, confidenceThreshold: 0.8, smoothingEnabled: false))
    let loaded = store.load()
    #expect(loaded.dwellMs == 750)
    #expect(loaded.confidenceThreshold == 0.8)
    #expect(!loaded.smoothingEnabled)
}

@Test("Missing, malformed, and future data all fall back to defaults")
func badDataFallsBack() {
    let missing = SettingsStore(defaults: freshDefaults())
    #expect(missing.load() == Settings())

    let garbage = freshDefaults()
    garbage.set(Data("not json".utf8), forKey: SettingsStore.key)
    #expect(SettingsStore(defaults: garbage).load() == Settings())

    let future = freshDefaults()
    future.set(
        try! JSONEncoder().encode(Settings(version: 99, dwellMs: 1234)),
        forKey: SettingsStore.key
    )
    #expect(SettingsStore(defaults: future).load() == Settings())
}

@Test("Saved settings are validated on the way in")
func saveValidates() {
    let defaults = freshDefaults()
    SettingsStore(defaults: defaults).save(Settings(dwellMs: -50))
    #expect(SettingsStore(defaults: defaults).load().dwellMs == Settings.dwellRange.lowerBound)
}
