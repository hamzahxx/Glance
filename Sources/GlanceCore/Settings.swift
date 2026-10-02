import Foundation

/// Persisted user settings.
///
/// Defaults: tracking starts disabled, dwell 400 ms, smoothing on,
/// launch at login off.
public struct Settings: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var dwellMs: Int
    public var confidenceThreshold: Double
    public var smoothingEnabled: Bool
    /// Subdivide a display into three vertical strips where calibration measures
    /// it as separable. Off by default: measured separability has not proven
    /// stable between sessions.
    public var enableStrips: Bool
    /// Move the pointer to the accepted target.
    public var moveCursor: Bool
    /// Give the application under the accepted target keyboard focus. This is
    /// what actually prevents wrong-window typing; cursor movement alone does
    /// not, because macOS focus follows the frontmost app, not the pointer.
    public var activateApp: Bool
    /// Seconds of no keystrokes before focus may change.
    public var typingIdleSeconds: Double
    /// Return the pointer to where it last sat on the target display, instead of
    /// that display's centre.
    public var restoreCursorPosition: Bool

    public init(
        version: Int = Settings.currentVersion,
        dwellMs: Int = 400,
        confidenceThreshold: Double = 0.6,
        smoothingEnabled: Bool = true,
        enableStrips: Bool = false,
        moveCursor: Bool = true,
        activateApp: Bool = true,
        typingIdleSeconds: Double = 0.5,
        restoreCursorPosition: Bool = true
    ) {
        self.version = version
        self.dwellMs = dwellMs
        self.confidenceThreshold = confidenceThreshold
        self.smoothingEnabled = smoothingEnabled
        self.enableStrips = enableStrips
        self.moveCursor = moveCursor
        self.activateApp = activateApp
        self.typingIdleSeconds = typingIdleSeconds
        self.restoreCursorPosition = restoreCursorPosition
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Settings.currentVersion
        dwellMs = try c.decodeIfPresent(Int.self, forKey: .dwellMs) ?? 400
        confidenceThreshold = try c.decodeIfPresent(Double.self, forKey: .confidenceThreshold) ?? 0.6
        smoothingEnabled = try c.decodeIfPresent(Bool.self, forKey: .smoothingEnabled) ?? true
        enableStrips = try c.decodeIfPresent(Bool.self, forKey: .enableStrips) ?? false
        moveCursor = try c.decodeIfPresent(Bool.self, forKey: .moveCursor) ?? true
        activateApp = try c.decodeIfPresent(Bool.self, forKey: .activateApp) ?? true
        typingIdleSeconds = try c.decodeIfPresent(Double.self, forKey: .typingIdleSeconds) ?? 0.5
        restoreCursorPosition = try c.decodeIfPresent(Bool.self, forKey: .restoreCursorPosition) ?? true
    }

    public static let dwellRange = 100...2000
    public static let confidenceRange = 0.1...0.99
    public static let typingIdleRange = 0.2...3.0

    /// Clamps out-of-range values rather than rejecting the whole file — a bad
    /// dwell value should not cost the user their other settings.
    public func validated() -> Settings {
        var s = self
        s.version = Settings.currentVersion
        s.dwellMs = min(max(dwellMs, Settings.dwellRange.lowerBound), Settings.dwellRange.upperBound)
        s.confidenceThreshold = min(
            max(confidenceThreshold.isFinite ? confidenceThreshold : 0.6, Settings.confidenceRange.lowerBound),
            Settings.confidenceRange.upperBound
        )
        s.typingIdleSeconds = min(
            max(typingIdleSeconds.isFinite ? typingIdleSeconds : 0.5, Settings.typingIdleRange.lowerBound),
            Settings.typingIdleRange.upperBound
        )
        return s
    }
}

/// UserDefaults-backed store. Missing, malformed, or future-versioned data all
/// fall back to defaults rather than throwing.
public struct SettingsStore {
    static let key = "com.glance.settings"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Settings {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data),
              decoded.version <= Settings.currentVersion
        else { return Settings() }
        return decoded.validated()
    }

    public func save(_ settings: Settings) {
        guard let data = try? JSONEncoder().encode(settings.validated()) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
