import GlanceCore
import SwiftUI

// SwiftUI also exports a `Settings` scene type; disambiguate for this file.
typealias Settings = GlanceCore.Settings

/// Controls that depend on unbuilt behaviour
/// are shown disabled with the milestone named, rather than faked.
struct SettingsView: View {
    @State private var settings: Settings
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    private let onChange: (Settings) -> Void

    init(settings: Settings, onChange: @escaping (Settings) -> Void) {
        _settings = State(initialValue: settings)
        self.onChange = onChange
    }

    private static func name(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }

    private static func icon(for bundleID: String) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }

    /// Running regular apps not already listed, by name.
    private static func addableApps(excluding listed: [String]) -> [(id: String, name: String)] {
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (id: String, name: String)? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier, !listed.contains(id)
            else { return nil }
            return (id, app.localizedName ?? id)
        }
        return Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            .values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Tracking") {
                Stepper(
                    "Dwell: \(settings.dwellMs) ms",
                    value: $settings.dwellMs,
                    in: Settings.dwellRange,
                    step: 50
                )
                VStack(alignment: .leading) {
                    Text("Confidence threshold: \(settings.confidenceThreshold, format: .number.precision(.fractionLength(2)))")
                    Slider(
                        value: $settings.confidenceThreshold,
                        in: Settings.confidenceRange.lowerBound...Settings.confidenceRange.upperBound
                    )
                }
                Toggle("Smoothing", isOn: $settings.smoothingEnabled)
                Toggle("Vertical strips where measured (experimental)", isOn: $settings.enableStrips)
                Text("""
                Subdivides a display into three columns when calibration measures \
                it as separable. Measured separability has varied between 79% and \
                99% on the same display in one hour, so this is off by default and \
                whole-display targeting is the reliable mode.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Cursor") {
                Toggle("Move the cursor to the target display", isOn: $settings.moveCursor)
                Toggle("Give that display's app keyboard focus", isOn: $settings.activateApp)
                Toggle("Return to where you left off on that display", isOn: $settings.restoreCursorPosition)
                Text("""
                Without this the cursor goes to the middle of the display, which \
                on a wide monitor is the wrong window whenever you were working \
                off to one side.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("""
                Focus is what stops wrong-window typing: on macOS the keyboard \
                follows the frontmost app, not the pointer, so moving the cursor \
                alone changes nothing. Glance activates the app under the \
                target and never clicks.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Hold focus while typing: \(settings.typingIdleSeconds, format: .number.precision(.fractionLength(1)))s")
                    Slider(
                        value: $settings.typingIdleSeconds,
                        in: Settings.typingIdleRange.lowerBound...Settings.typingIdleRange.upperBound
                    )
                }
                Text("Focus never changes within this long of your last keystroke.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pause automatically") {
                Toggle("When the active app is fullscreen", isOn: $settings.pauseWhenFullscreen)
                Text("Presentations, games and videos. This is judged per app: any fullscreen window of the active app holds, so a fullscreen Safari video on one display holds glancing even from another Safari window. Click a different app to resume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(settings.pausedApps, id: \.self) { id in
                    HStack {
                        Image(nsImage: Self.icon(for: id))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(Self.name(for: id))
                        Spacer()
                        Button("Remove") { settings.pausedApps.removeAll { $0 == id } }
                    }
                }
                Menu("Add app…") {
                    ForEach(Self.addableApps(excluding: settings.pausedApps), id: \.id) { app in
                        Button(app.name) { settings.pausedApps.append(app.id) }
                    }
                }
                Text("Nothing moves while one of these apps is frontmost, e.g. zoom.us while sharing your screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open Glance at login", isOn: $launchAtLogin)
                Text(loginItemError ?? LoginItem.explanation)
                    .font(.caption)
                    .foregroundStyle(loginItemError == nil ? .secondary : .primary)
                if LoginItem.status == .requiresApproval {
                    Button("Open Login Items…") { LoginItem.openSettings() }
                }
                if LoginItem.isInBuildDirectory {
                    Text("""
                    Glance is running from \(Bundle.main.bundlePath). Registering \
                    works from here, but a login item points at this exact path — \
                    move or clean the folder and macOS will silently stop launching \
                    it. Keep the app in Applications if you rely on this.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text("Tracking always starts switched off, however Glance was launched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Displays") {
                Text("Display detection and per-display calibration arrive in Milestone 3.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy & Permissions") {
                Text(WindowRaiser.isPermitted
                     ? "Accessibility granted — Glance can focus the specific window under the target."
                     : "Accessibility not granted. Glance can activate an app but cannot choose between that app's own windows, so a browser open on both displays will keep focus on the window you looked away from.")
                    .font(.caption)
                    .foregroundStyle(WindowRaiser.isPermitted ? .secondary : .primary)
                Text("""
                Glance has not requested camera access. No camera is opened and \
                no frames are captured in this build. Camera handling arrives in \
                Milestone 2; cursor control and its Accessibility permission arrive \
                in Milestone 4.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 400)
        .onChange(of: settings) { _, updated in onChange(updated) }
        .onChange(of: launchAtLogin) { _, wanted in
            // Reverting on failure re-enters here, but by then the value already
            // matches the system and this returns immediately.
            guard wanted != LoginItem.isEnabled else { return }
            do {
                try LoginItem.set(wanted)
                loginItemError = nil
            } catch {
                loginItemError = "Could not change this: \(error.localizedDescription)"
                launchAtLogin = LoginItem.isEnabled
            }
        }
        .onAppear {
            // The user may have changed it in System Settings since this window
            // was last opened.
            launchAtLogin = LoginItem.isEnabled
        }
    }
}
