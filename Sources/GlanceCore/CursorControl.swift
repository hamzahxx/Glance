import AppKit
import CoreGraphics
import Foundation

/// Moves the pointer. Nothing else — no clicks, ever.
public enum Cursor {
    public static func move(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Warping briefly decouples the hardware mouse from the cursor;
        // reassociating immediately keeps the user's own movement working.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Where the pointer is now, in CoreGraphics coordinates.
    public static var location: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}

/// Gives keyboard focus to whatever application owns the window under a point.
///
/// Deliberately not a synthetic click. A click lands on whatever pixel is under
/// it — a link, a tab close button, a canvas — inside an application we do not
/// control and cannot undo. Activating the owning application moves keyboard
/// focus, which is all the goal requires, and delivers no event to window
/// content.
public enum FocusActivator {
    public struct Result: Equatable, Sendable {
        public var applicationName: String
        public var alreadyFrontmost: Bool
        /// The window raised under the point, if any. Nil means only the
        /// application was activated, which cannot move focus between two
        /// windows of that same application.
        public var raisedWindow: CGRect?

        public var summary: String {
            if let raisedWindow {
                return String(format: "focused %@ window (%.0f, %.0f %.0fx%.0f)",
                              applicationName, raisedWindow.minX, raisedWindow.minY,
                              raisedWindow.width, raisedWindow.height)
            }
            if alreadyFrontmost { return "\(applicationName) already frontmost — window not raised" }
            return "activated \(applicationName)"
        }
    }

    /// Picks the frontmost activatable application window containing `point`.
    ///
    /// Split out from the live lookup so the z-order, bounds and filtering rules
    /// can be tested against a synthetic window list.
    public static func owner(
        in windows: [[String: Any]],
        at point: CGPoint,
        excluding ownPID: pid_t,
        isActivatable: (pid_t) -> Bool
    ) -> pid_t? {
        // The list is front-to-back, so the first acceptable hit is the window
        // the user would see and click.
        for window in windows {
            // Layer 0 is ordinary application windows; anything else is the menu
            // bar, the Dock or other system chrome.
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = rect(from: bounds),
                  rect.contains(point)
            else { continue }

            // Layer 0 is not enough on its own: com.apple.WindowManager owns
            // layer-0 windows covering the desktop, and activating it focuses
            // nothing while hiding the app the user actually wanted. Requiring a
            // regular activation policy skips those without blocklisting names.
            guard isActivatable(pid) else { continue }
            return pid
        }
        return nil
    }

    /// The frontmost window belonging to `pid` that lies within `frame`.
    ///
    /// Used to infer where the user was working on a display they are leaving,
    /// which needs no mouse movement — the signal cursor position cannot give
    /// when Glance is the one moving the pointer.
    public static func frontmostWindow(of pid: pid_t, within frame: CGRect) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = rect(from: bounds),
                  frame.intersects(rect)
            else { continue }
            return rect
        }
        return nil
    }

    /// Window bounds and owner PID need no additional permission; only window
    /// *titles* would require Screen Recording, and none are read.
    @MainActor
    public static func application(at point: CGPoint) -> pid_t? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        return owner(
            in: windows,
            at: point,
            excluding: ProcessInfo.processInfo.processIdentifier,
            isActivatable: { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular }
        )
    }

    @discardableResult
    @MainActor
    public static func focus(at point: CGPoint) -> Result? {
        guard let pid = application(at: point),
              let app = NSRunningApplication(processIdentifier: pid)
        else { return nil }

        let name = app.localizedName ?? "pid \(pid)"
        let wasFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid

        if !wasFrontmost {
            // macOS 14 replaced unilateral activation with cooperative
            // activation. Plain `activate()` returns true from a background
            // agent and does nothing at all — measured with `--focustest`.
            // `activate(from:)` offers this app's own activation to the target.
            if !app.activate(from: .current, options: []) {
                // Last resort: LaunchServices. Heavier, but does not depend on
                // cooperative activation being granted.
                if let url = app.bundleURL {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                }
            }
        }

        // Always attempt the window raise, including when the app was already
        // frontmost: that is exactly the case activation cannot fix, because the
        // wrong window of the right app currently has focus.
        let raised = WindowRaiser.raiseWindow(at: point)
        return Result(applicationName: name, alreadyFrontmost: wasFrontmost, raisedWindow: raised)
    }

    private static func rect(from bounds: [String: CGFloat]) -> CGRect? {
        guard let x = bounds["X"], let y = bounds["Y"],
              let width = bounds["Width"], let height = bounds["Height"]
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Seconds since the last key press, across the whole session.
///
/// The guard that matters most: a false cursor jump is an annoyance, but
/// stealing focus mid-sentence sends the rest of your keystrokes into another
/// window, which is worse than the problem being solved.
public enum KeyboardActivity {
    public static func secondsSinceLastKeystroke() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }
}
