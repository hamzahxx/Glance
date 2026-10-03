import Foundation

/// Owns the state machine and the engine lifecycle. The AppKit layer talks only
/// to this; it never touches `reduce` directly.
@MainActor
public final class TrackingController {
    public private(set) var state: TrackingState = .disabled {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    public var onStateChange: ((TrackingState) -> Void)?

    public var settings: Settings {
        didSet { store.save(settings) }
    }

    private let engine: TrackingEngine
    private let store: SettingsStore

    public init(engine: TrackingEngine, store: SettingsStore = SettingsStore()) {
        self.engine = engine
        self.store = store
        self.settings = store.load()
        engine.onEvent = { [weak self] event in self?.apply(event) }
    }

    /// The menu's primary control.
    public func toggle() {
        if state == .disabled {
            apply(.enable)
            engine.start()
        } else {
            apply(.disable)
        }
    }

    public func apply(_ event: TrackingEvent) {
        guard let next = reduce(state, event) else { return }
        // Every route into Disabled releases the camera, whoever asked for it.
        // Otherwise the engine keeps running and the next start is ignored.
        if next == .disabled { engine.stop() }
        state = next
    }
}
