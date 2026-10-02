import AppKit
import Foundation
import ServiceManagement

/// Whether Glance starts when the user logs in.
///
/// Deliberately not stored in `Settings`. macOS owns this state — the user can
/// change it in System Settings, and approval can be pending — so a copy of it
/// in our own preferences would be a second answer that is sometimes wrong.
/// Everything here reads the system.
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    static var explanation: String {
        switch status {
        case .enabled:
            "Glance will start when you log in."
        case .requiresApproval:
            "Waiting for your approval in System Settings › General › Login Items."
        case .notRegistered, .notFound:
            // `.notFound` is what macOS reports for an app that has simply never
            // been registered — measured with `--loginitem`. Treating it as an
            // error told the user their app was missing when nothing was wrong.
            "Glance will not start on login."
        @unknown default:
            "Login item status is unknown."
        }
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// A login item records *this* bundle's location. One sitting in a build
    /// directory will break the first time the folder is cleaned or moved, and
    /// macOS will quietly stop launching it, so say so rather than let that
    /// happen silently.
    static var isInBuildDirectory: Bool {
        let path = Bundle.main.bundlePath
        let applications = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        return !applications.contains { path.hasPrefix($0) }
    }
}

extension LoginItem {
    /// `--loginitem`: registers, reports, then restores the previous state.
    ///
    /// `SMAppService` reports `.notFound` in situations where the honest answer
    /// is "never registered", so the only way to know what a given macOS build
    /// does is to perform the round trip and watch.
    static func selfTest() -> Never {
        func report(_ label: String) {
            print("  \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(name(of: status))")
        }
        print("bundle: \(Bundle.main.bundlePath)")
        let wasEnabled = isEnabled
        report("initial")

        do {
            try set(true)
            report("registered")
        } catch {
            print("  register failed: \(error.localizedDescription)")
            exit(1)
        }

        // Leave the machine as it was found.
        if !wasEnabled {
            do {
                try set(false)
                report("restored")
            } catch {
                print("  unregister failed: \(error.localizedDescription) — remove it in System Settings")
                exit(1)
            }
        }
        exit(0)
    }

    static func name(of status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notRegistered: "notRegistered"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}
