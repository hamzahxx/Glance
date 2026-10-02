import CoreGraphics
import Foundation
import Testing
@testable import GlanceCore

private func window(pid: pid_t, layer: Int = 0, x: CGFloat, y: CGFloat, w: CGFloat = 100, h: CGFloat = 100) -> [String: Any] {
    [
        kCGWindowLayer as String: layer,
        kCGWindowOwnerPID as String: pid,
        kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h],
    ]
}

private func anythingActivates(_: pid_t) -> Bool { true }

@Test("The frontmost window containing the point wins")
func frontmostWins() {
    // List is front-to-back, and both cover the point.
    let windows = [window(pid: 10, x: 0, y: 0), window(pid: 20, x: 0, y: 0)]
    #expect(FocusActivator.owner(in: windows, at: CGPoint(x: 50, y: 50),
                                 excluding: 99, isActivatable: anythingActivates(_:)) == 10)
}

@Test("A window that does not contain the point is skipped")
func boundsMustContainPoint() {
    let windows = [window(pid: 10, x: 500, y: 500), window(pid: 20, x: 0, y: 0)]
    #expect(FocusActivator.owner(in: windows, at: CGPoint(x: 50, y: 50),
                                 excluding: 99, isActivatable: anythingActivates(_:)) == 20)
}

@Test("System chrome above layer 0 is ignored")
func nonZeroLayersIgnored() {
    let windows = [window(pid: 10, layer: 25, x: 0, y: 0), window(pid: 20, x: 0, y: 0)]
    #expect(FocusActivator.owner(in: windows, at: CGPoint(x: 50, y: 50),
                                 excluding: 99, isActivatable: anythingActivates(_:)) == 20)
}

@Test("Glance never focuses itself")
func ownWindowExcluded() {
    let windows = [window(pid: 99, x: 0, y: 0), window(pid: 20, x: 0, y: 0)]
    #expect(FocusActivator.owner(in: windows, at: CGPoint(x: 50, y: 50),
                                 excluding: 99, isActivatable: anythingActivates(_:)) == 20)
}

@Test("A layer-0 window owned by a non-activatable process is skipped")
func nonActivatableSkipped() {
    // This is the real WindowManager case: layer 0, covers the point, but
    // activating it focuses nothing and hides the app behind it.
    let windowManager: pid_t = 300
    let windows = [window(pid: windowManager, x: 0, y: 0), window(pid: 20, x: 0, y: 0)]
    #expect(FocusActivator.owner(in: windows, at: CGPoint(x: 50, y: 50), excluding: 99) {
        $0 != windowManager
    } == 20)
}

@Test("No usable window under the point yields nil rather than a wrong guess")
func nothingThereIsNil() {
    let windows = [window(pid: 300, x: 0, y: 0)]
    #expect(FocusActivator.owner(in: windows, at: CGPoint(x: 50, y: 50), excluding: 99) {
        $0 != 300
    } == nil)
    #expect(FocusActivator.owner(in: [], at: .zero, excluding: 99, isActivatable: anythingActivates(_:)) == nil)
}

@Test("A point exactly on the window edge counts as inside")
func edgeIsInside() {
    let windows = [window(pid: 10, x: 0, y: 0, w: 100, h: 100)]
    #expect(FocusActivator.owner(in: windows, at: CGPoint(x: 0, y: 0),
                                 excluding: 99, isActivatable: anythingActivates(_:)) == 10)
    // CGRect.contains excludes the far edge, which is the correct half-open rule.
    #expect(FocusActivator.owner(in: windows, at: CGPoint(x: 100, y: 100),
                                 excluding: 99, isActivatable: anythingActivates(_:)) == nil)
}

@Test("Negative coordinates work — a display left of the built-in one")
func negativeCoordinates() {
    let windows = [window(pid: 10, x: -2560, y: -256, w: 2560, h: 1080)]
    #expect(FocusActivator.owner(in: windows, at: CGPoint(x: -1280, y: 284),
                                 excluding: 99, isActivatable: anythingActivates(_:)) == 10)
}
