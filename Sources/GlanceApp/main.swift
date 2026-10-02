import AppKit
import GlanceCore

// Menu-bar only: no Dock icon, no main window.
let app = NSApplication.shared
// --selftest must not open a camera, so it runs against the stub engine.
let isSelfTest = CommandLine.arguments.contains("--selftest")
let engine: TrackingEngine = isSelfTest ? StubTrackingEngine() : VisionTrackingEngine()
let delegate = AppDelegate(engine: engine)
app.delegate = delegate
app.setActivationPolicy(.accessory)

if CommandLine.arguments.contains("--loginitem") {
    LoginItem.selfTest()
}

if CommandLine.arguments.contains("--focustest") {
    FocusTest.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--diagnose") {
    let seconds = i + 1 < CommandLine.arguments.count
        ? Double(CommandLine.arguments[i + 1]) ?? 8 : 8
    Diagnostics.run(seconds: seconds)
}

if isSelfTest {
    func dump(_ label: String) {
        print("\n\(label) — state: \(delegate.stateDescription)")
        for title in delegate.menuTitles { print("  \(title)") }
    }

    delegate.applicationDidFinishLaunching(Notification(name: .init("selftest")))
    dump("initial")

    delegate.simulateToggle()
    // Let the stub engine deliver .engineReady on the main queue.
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    dump("after first toggle")

    delegate.simulateToggle()
    dump("after second toggle")

    print("\nactivation policy: \(app.activationPolicy() == .accessory ? "accessory (no Dock icon)" : "WRONG")")
    exit(0)
}

app.run()
