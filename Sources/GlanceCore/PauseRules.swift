import CoreGraphics

/// Why movement is held even though tracking is running. Kept out of the state
/// machine on purpose: `reduce` resumes any pause on `.inputReacquired`, so a
/// face coming back would lift a rule the user set.
public enum Suppression: Equatable, Sendable {
    case app(String)
    case fullscreen
}

public enum PauseRules {
    /// The pause list wins over fullscreen, so the status names the rule the
    /// user wrote.
    public static func suppression(
        frontmostBundleID: String?, frontmostIsFullscreen: Bool, settings: Settings
    ) -> Suppression? {
        if let id = frontmostBundleID, settings.pausedApps.contains(id) { return .app(id) }
        if settings.pauseWhenFullscreen, frontmostIsFullscreen { return .fullscreen }
        return nil
    }

    /// The rects a fullscreen window may occupy on one display: the whole
    /// frame, and on a notched display the frame below the notch, which is
    /// where apps that do not opt into the notch area are put.
    public static func fullscreenRects(frame: CGRect, topInset: CGFloat) -> [CGRect] {
        guard topInset > 0 else { return [frame] }
        return [frame, CGRect(x: frame.minX, y: frame.minY + topInset,
                              width: frame.width, height: frame.height - topInset)]
    }

    /// A window is fullscreen when it covers one of `displayFrames` exactly
    /// (see `fullscreenRects`). A maximised window leaves the menu bar
    /// visible and so does not count.
    public static func isFullscreen(windowBounds: [CGRect], displayFrames: [CGRect]) -> Bool {
        windowBounds.contains { window in
            displayFrames.contains { $0.integral == window.integral }
        }
    }
}
