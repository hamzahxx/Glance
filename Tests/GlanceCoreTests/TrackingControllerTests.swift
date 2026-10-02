import Foundation
import Testing
@testable import GlanceCore

/// Engine that emits only what a test tells it to.
@MainActor
private final class ScriptedEngine: TrackingEngine {
    var onEvent: ((TrackingEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func emit(_ event: TrackingEvent) { onEvent?(event) }
}

@MainActor
private func makeController() -> (TrackingController, ScriptedEngine) {
    let engine = ScriptedEngine()
    let controller = TrackingController(
        engine: engine,
        store: SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    )
    return (controller, engine)
}

@Test @MainActor
func startsDisabledAndStartsEngineOnToggle() {
    let (controller, engine) = makeController()
    #expect(controller.state == .disabled)
    #expect(!controller.state.allowsCursorMovement)

    controller.toggle()
    #expect(controller.state == .initializing)
    #expect(engine.startCount == 1)

    engine.emit(.engineReady(calibrated: true))
    #expect(controller.state == .tracking)
}

@Test @MainActor
func toggleOffStopsEngineFromAnyLiveState() {
    let (controller, engine) = makeController()
    controller.toggle()
    engine.emit(.engineReady(calibrated: true))

    controller.toggle()
    #expect(controller.state == .disabled)
    #expect(engine.stopCount == 1)
}

@Test @MainActor
func toggleClearsAnError() {
    let (controller, engine) = makeController()
    controller.toggle()
    engine.emit(.failed("camera exploded"))
    #expect(controller.state == .error("camera exploded"))
    #expect(!controller.state.allowsCursorMovement)

    controller.toggle()
    #expect(controller.state == .disabled)
}

@Test @MainActor
func stateChangesAreObservedOnceEach() {
    let (controller, engine) = makeController()
    var observed: [TrackingState] = []
    controller.onStateChange = { observed.append($0) }

    controller.toggle()
    engine.emit(.engineReady(calibrated: true))
    // Ignored: already tracking.
    engine.emit(.engineReady(calibrated: true))
    engine.emit(.inputLost(.faceLost))

    #expect(observed == [.initializing, .tracking, .paused(.faceLost)])
}

@Test @MainActor
func settingsPersistThroughTheController() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let store = SettingsStore(defaults: defaults)
    let controller = TrackingController(engine: ScriptedEngine(), store: store)

    controller.settings.dwellMs = 600
    #expect(store.load().dwellMs == 600)
}
