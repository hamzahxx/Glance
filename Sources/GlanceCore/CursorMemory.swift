import CoreGraphics
import Foundation

/// Remembers where the user was working on each display.
///
/// Targeting the centre of a display is a guess that is usually wrong on a wide
/// monitor with windows side by side. This replaces prediction with memory for
/// the within-display question, which is the question head pose answers badly.
///
/// Two sources, in order of trust:
///
/// 1. **observed** — where the pointer sat under the user's own hand. Exact.
/// 2. **inferred** — the centre of the window that was frontmost on that
///    display when the user looked away. Coarser, but it needs no mouse at all,
///    which matters because Glance moves the pointer itself and must not
///    mistake its own warp for the user's intent.
///
/// Without the inferred source, a display the user only ever drives from the
/// keyboard never accumulates a position and falls back to its centre forever.
public struct CursorMemory: Codable, Equatable, Sendable {
    private var observed: [DisplayIdentifier: CGPoint] = [:]
    private var inferred: [DisplayIdentifier: CGPoint] = [:]

    public init() {}

    /// The pointer's current position, against whichever display contains it.
    /// Cheap enough to call every frame; callers must not pass a position
    /// Glance set itself.
    public mutating func record(_ point: CGPoint, displays: [DisplaySnapshot]) {
        guard let display = displays.first(where: { $0.frame.contains(point) }) else { return }
        observed[display.id] = point
    }

    /// The centre of the window the user was last using on that display.
    /// Never overrides an observed position.
    public mutating func recordInferred(
        _ point: CGPoint, for id: DisplayIdentifier, displays: [DisplaySnapshot]
    ) {
        guard let display = displays.first(where: { $0.id == id }),
              display.frame.contains(point)
        else { return }
        inferred[id] = point
    }

    /// The remembered point, if it still falls inside that display's *current*
    /// bounds. A rearranged or resized display invalidates its own memory rather
    /// than sending the pointer somewhere that no longer exists.
    public func position(for id: DisplayIdentifier, displays: [DisplaySnapshot]) -> CGPoint? {
        guard let display = displays.first(where: { $0.id == id }) else { return nil }
        for candidate in [observed[id], inferred[id]] {
            if let candidate, display.frame.contains(candidate) { return candidate }
        }
        return nil
    }

    /// True when this display has only an inferred position, or none.
    public func hasObserved(_ id: DisplayIdentifier) -> Bool {
        observed[id] != nil
    }

    public mutating func forgetAll() {
        observed.removeAll()
        inferred.removeAll()
    }
}

/// Persists cursor memory, so what it learns survives a relaunch.
public struct CursorMemoryStore {
    public static let defaultURL = CalibrationStore.directory
        .appendingPathComponent("cursor-memory.json")

    private let url: URL

    public init(url: URL = CursorMemoryStore.defaultURL) {
        self.url = url
    }

    public func load() -> CursorMemory {
        guard let data = try? Data(contentsOf: url),
              let memory = try? JSONDecoder().decode(CursorMemory.self, from: data)
        else { return CursorMemory() }
        return memory
    }

    @discardableResult
    public func save(_ memory: CursorMemory) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(memory) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
