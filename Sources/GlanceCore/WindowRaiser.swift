import ApplicationServices
import CoreGraphics
import Foundation

/// Raises the specific window under a point, rather than merely activating its
/// application.
///
/// Activating an application cannot choose between that application's own
/// windows. With a browser or editor open on both displays, the app under the
/// target is already frontmost, so activation is a no-op and focus stays on the
/// window you were looking away from. Raising the window is the only way to
/// settle that, and it is the one part of Glance that needs Accessibility.
///
/// Everything degrades without the permission: app activation still works, and
/// only same-application window switching is lost.
public enum WindowRaiser {
    public static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt. Returns the state *before* the user answers.
    @discardableResult
    public static func requestPermission() -> Bool {
        // The global is an unsafe mutable under strict concurrency; its value
        // is a fixed CFString constant.
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Raises and focuses the window under `point`, returning its frame.
    ///
    /// The frame is what tells two windows of the same application apart: with
    /// a terminal open on both displays the application name alone cannot say
    /// which one was raised.
    @discardableResult
    public static func raiseWindow(at point: CGPoint) -> CGRect? {
        guard isPermitted else { return nil }

        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element
        ) == .success, let hit = element else { return nil }

        guard let window = enclosingWindow(of: hit) else { return nil }

        // Raise puts the window in front within its app; main/focused decide
        // which of that app's windows the keyboard talks to.
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)

        var pid: pid_t = 0
        if AXUIElementGetPid(window, &pid) == .success {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        return frame(of: window)
    }

    /// A window's screen rectangle, in CoreGraphics coordinates.
    public static func frame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Walks up from whatever element was hit until a window is found.
    /// Bounded, because a malformed hierarchy must not spin forever.
    private static func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<12 {
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role) == .success,
               (role as? String) == kAXWindowRole {
                return current
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID()
            else { return nil }
            current = (next as! AXUIElement)
        }
        return nil
    }
}
