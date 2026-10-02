import AppKit
import Foundation

/// `--focustest`: finds out which activation method actually moves focus when
/// called from this app, as a background agent that is not itself active.
///
/// macOS 14 replaced unilateral activation with cooperative activation, so the
/// documented API may simply decline. The only trustworthy answer is measured.
@MainActor
enum FocusTest {
    static func run() -> Never {
        func spin(_ seconds: Double) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        func frontmost() -> String {
            NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        }

        let original = NSWorkspace.shared.frontmostApplication
        print("Glance policy: \(NSApp.activationPolicy() == .accessory ? "accessory" : "other")")
        print("Glance is frontmost: \(NSRunningApplication.current.isActive)")
        print("starting frontmost app: \(frontmost())\n")

        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier != original?.processIdentifier
                && $0.processIdentifier != NSRunningApplication.current.processIdentifier
        }
        guard let target = candidates.first(where: { $0.localizedName == "Finder" }) ?? candidates.first else {
            print("no other regular app running to test against")
            exit(1)
        }
        print("target: \(target.localizedName ?? "?")\n")

        func attempt(_ name: String, _ body: () -> Bool) {
            original?.activate()
            spin(0.8)
            let accepted = body()
            spin(1.2)
            let now = frontmost()
            let worked = now == target.localizedName
            print("  \(worked ? "✅" : "❌") \(name)")
            print("     returned \(accepted), frontmost became \(now)")
        }

        attempt("activate()") { target.activate() }
        attempt("activate(from: .current, options: [])") {
            target.activate(from: .current, options: [])
        }
        attempt("activate(options: .activateAllWindows)") {
            target.activate(options: [.activateAllWindows])
        }
        attempt("NSWorkspace.openApplication(at:)") {
            guard let url = target.bundleURL else { return false }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
            return true
        }

        original?.activate()
        spin(0.8)
        print("\nrestored frontmost: \(frontmost())")
        exit(0)
    }
}
