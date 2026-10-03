import AppKit
import GlanceCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let controller: TrackingController
    /// Non-nil for the real engine; nil under --selftest, which uses the stub.
    private let visionEngine: VisionTrackingEngine?

    private let libraryStore = CalibrationLibraryStore()
    private var library = CalibrationLibrary()
    private var active: NamedCalibration?
    private var profile: CalibrationProfile? { active?.profile }
    private var snapshots: [DisplaySnapshot] = []
    private var classifier: YawClassifier?
    private var runner: CalibrationRunner?
    private var wantsCalibration = false
    private var gate = MovementGate()
    private let cursorMemoryStore = CursorMemoryStore()
    private var cursorMemory = CursorMemory()
    /// Where we last warped the pointer, so our own move is not mistaken for
    /// the user's position and recorded as "where you left off".
    private var lastWarpedPoint: CGPoint?
    private var hotKey: EmergencyHotKey?
    private var lastAction: String?
    private let actionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var profilesItem: NSMenuItem?
    private let windowFocusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var enableFocusItem: NSMenuItem?

    private let toggleItem = NSMenuItem(title: "Start Tracking", action: nil, keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cameraItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let poseItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let targetItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let calibrationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var menuIsOpen = false
    private var explainingScreenChange = false

    init(engine: TrackingEngine) {
        visionEngine = engine as? VisionTrackingEngine
        controller = TrackingController(engine: engine)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.menu = buildMenu()

        hotKey = EmergencyHotKey { [weak self] in self?.controller.toggle() }
        cursorMemory = cursorMemoryStore.load()
        reloadCalibration()
        controller.onStateChange = { [weak self] state in self?.stateChanged(state) }
        visionEngine?.isCalibrated = { [weak self] in
            self?.validity().isValid ?? false
        }
        visionEngine?.apply(controller.settings)
        visionEngine?.onCameraStatus = { [weak self] _ in self?.refreshDetails() }
        visionEngine?.onPose = { [weak self] pose in
            guard let self else { return }
            self.runner?.ingest(pose)
            self.considerMoving(pose)
            // Only worth redrawing while someone is looking at the menu.
            if self.menuIsOpen { self.refreshDetails() }
        }

        // A display that moves, changes resolution or disappears invalidates the
        // mapping built against it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        refresh()
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        toggleItem.action = #selector(toggleTracking)
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())
        for item in [stateItem, cameraItem, poseItem, targetItem, calibrationItem, windowFocusItem, actionItem] {
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        // Always built, shown only while the permission is missing. The menu is
        // constructed once, so this has to be hidden rather than omitted.
        let enable = action("Enable Window Focus…", #selector(requestAccessibility))
        enableFocusItem = enable
        menu.addItem(enable)
        menu.addItem(action("Calibrate Displays…", #selector(openCalibration)))
        let profiles = NSMenuItem(title: "Calibration Profile", action: nil, keyEquivalent: "")
        profiles.submenu = profilesMenu()
        profilesItem = profiles
        menu.addItem(profiles)
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))

        menu.addItem(.separator())
        menu.addItem(action("Quit Glance", #selector(quit), key: "q"))
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        refreshDetails()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func refresh() {
        let state = controller.state
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbolName(for: state.indicator),
            accessibilityDescription: "Glance — \(statusText(for: state))"
        )
        toggleItem.title = (state == .disabled ? "Start Tracking" : "Stop Tracking")
            + (hotKey == nil ? "" : "   \(EmergencyHotKey.displayName)")
        refreshDetails()
    }

    private func refreshDetails() {
        stateItem.title = "Status: \(statusText(for: controller.state))"
        cameraItem.title = "Camera: \(visionEngine?.cameraStatus.summary ?? "stub engine (--selftest)")"
        poseItem.title = "Head: \(poseText())"
        targetItem.title = "Target: \(targetText())"
        calibrationItem.title = "Calibration: \(calibrationText())"
        let canRaise = WindowRaiser.isPermitted
        windowFocusItem.title = canRaise
            ? "Window focus: on"
            : "Window focus: off — needs Accessibility"
        enableFocusItem?.isHidden = canRaise
        actionItem.title = "Last move: \(lastAction ?? "none this session")"
        profilesItem?.submenu = profilesMenu()
    }

    /// Head pose, not gaze — the menu says so, because the distinction decides
    /// what the tool can and cannot do.
    private func poseText() -> String {
        guard controller.state != .disabled else { return "—" }
        guard let engine = visionEngine else { return "—" }
        guard let pose = engine.latestPose else { return "no face detected" }
        return String(format: "yaw %+.1f°  pitch %+.1f°", pose.yaw, pose.pitch)
    }

    /// Milestone 3 deliverable: predict the target and show it. Nothing moves.
    private func targetText() -> String {
        guard controller.state == .tracking else { return "—" }
        guard let classifier else { return "not calibrated" }
        guard let pose = visionEngine?.latestPose else { return "no face detected" }
        guard let nearest = classifier.nearest(yaw: pose.yaw) else { return "no calibrated display connected" }

        let gated = classifier.classify(yaw: pose.yaw)
        guard gated != nil else {
            return String(format: "%@ — too close to call (margin %.1f°)",
                          nearest.displayName, nearest.displayMargin)
        }
        var text = nearest.displayName
        if let strip = gated?.strip {
            text += " · strip \(strip + 1) of 3"
        } else if let calibration = profile?.calibration(for: nearest.display), !calibration.stripsEnabled {
            text += " · whole display"
        } else {
            text += " · strip too close to call"
        }
        return text + String(format: "  (margin %.1f°)", nearest.displayMargin)
    }

    private func calibrationText() -> String {
        let validity = validity()
        guard let active else {
            return library.profiles.isEmpty ? "no profiles yet" : "no profile matches these displays"
        }
        guard validity.isValid, let profile else {
            return "\(active.name) — \(validity.explanation)"
        }
        _ = active
        let strips = profile.displays.filter(\.stripsEnabled).count
        var text = "\(active.name)"
        text += String(format: " · displays %.0f%%", profile.displaySeparability * 100)
        text += strips > 0 ? " · strips on \(strips)" : ""
        text += library.pinnedID == nil ? " · auto" : " · pinned"
        return text
    }

    // MARK: - Profiles

    private func profilesMenu() -> NSMenu {
        let menu = NSMenu()

        let auto = NSMenuItem(title: "Match displays automatically",
                              action: #selector(useAutomaticProfile), keyEquivalent: "")
        auto.target = self
        auto.state = library.pinnedID == nil ? .on : .off
        menu.addItem(auto)

        if library.profiles.isEmpty {
            menu.addItem(.separator())
            menu.addItem(info("No profiles yet — run Calibrate Displays…"))
        } else {
            menu.addItem(.separator())
            for entry in library.profiles {
                let fits = entry.profile.validity(against: snapshots).isValid
                let item = NSMenuItem(
                    title: fits ? entry.name : "\(entry.name)  (not these displays)",
                    action: #selector(pinProfile(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry.id
                item.state = entry.id == active?.id ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(action("Rename Current Profile…", #selector(renameProfile)))
            menu.addItem(action("Delete Current Profile…", #selector(deleteProfile)))
        }
        return menu
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func useAutomaticProfile() {
        library.pinnedID = nil
        libraryStore.save(library)
        activateSelection()
    }

    @objc private func pinProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        library.pinnedID = id
        libraryStore.save(library)
        activateSelection()
    }

    /// Switching profiles changes the mapping, so anything derived from the old
    /// one is rebuilt and the gate forgets what it had accepted.
    private func activateSelection() {
        active = library.active(for: snapshots)
        classifier = profile.map { YawClassifier(profile: $0, connected: snapshots) }
        gate.reset()
        cursorMemory.forgetAll()

        let validity = validity()
        if !validity.isValid, controller.state == .tracking {
            controller.apply(.recalibrate)
        }
        refresh()
    }

    @objc private func renameProfile() {
        guard let current = active else { return }
        guard let name = prompt("Rename profile", "What should this setup be called?", current.name)
        else { return }
        var updated = current
        updated.name = name
        library.upsert(updated)
        libraryStore.save(library)
        active = updated
        refresh()
    }

    @objc private func deleteProfile() {
        guard let current = active else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(current.name)”?"
        alert.informativeText = "Its calibration is removed. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        library.remove(current.id)
        libraryStore.save(library)
        activateSelection()
    }

    private func prompt(_ title: String, _ body: String, _ initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        NSApp.activate()
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func symbolName(for indicator: StatusIndicator) -> String {
        switch indicator {
        case .disabled: "eye.slash"
        case .active: "eye"
        case .attentionRequired: "exclamationmark.triangle.fill"
        }
    }

    private func statusText(for state: TrackingState) -> String {
        switch state {
        case .disabled: "Disabled"
        case .initializing: "Starting camera…"
        case .calibrating: "Calibration required"
        case .tracking: "Tracking head pose (no cursor control yet)"
        case .paused(let reason): "Paused — \(reason.rawValue)"
        case .error(let message): "Error — \(message)"
        }
    }

    // MARK: - Actions

    @objc private func toggleTracking() {
        controller.toggle()
    }

    @objc private func requestAccessibility() {
        WindowRaiser.requestPermission()
        let alert = NSAlert()
        alert.messageText = "Allow Glance to focus windows"
        alert.informativeText = """
        Without Accessibility, Glance can activate an application but cannot \
        choose between that application's own windows. With a browser or editor \
        open on both displays, the app is already frontmost, so focus stays on \
        the window you looked away from.

        Turn Glance on in the Accessibility list, then quit and reopen \
        Glance — macOS only applies the change to a fresh launch, which is also \
        why this menu item lingers until then.

        There is nothing to turn off here: only System Settings can withdraw the \
        permission. Nothing else in Glance needs it.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Done")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openCalibration() {
        wantsCalibration = true
        switch controller.state {
        case .disabled:
            // Calibration needs the camera, so bring the engine up first; the
            // state change handler picks it up from there.
            controller.toggle()
        case .tracking:
            controller.apply(.recalibrate)
        case .calibrating:
            break
        default:
            break
        }
    }

    // MARK: - Calibration

    private func reloadCalibration() {
        snapshots = Self.currentDisplays()
        library = libraryStore.load(migrationName: CalibrationLibrary.suggestedName(for: snapshots))
        active = library.active(for: snapshots)
        classifier = profile.map { YawClassifier(profile: $0, connected: snapshots) }
    }

    private func validity() -> CalibrationValidity {
        guard let profile else { return .missing }
        return profile.validity(against: snapshots)
    }

    /// CoreGraphics owns the geometry; AppKit only supplies the human-readable
    /// name, which CoreGraphics has no API for.
    static func currentDisplays() -> [DisplaySnapshot] {
        let names = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return (number.uint32Value, screen.localizedName)
        })
        return DisplayGeometry.current().map {
            var snapshot = $0
            snapshot.name = names[$0.cgID] ?? "Display \($0.cgID)"
            return snapshot
        }
    }

    // MARK: - Movement

    /// The only path that moves anything. Every guard is checked here, in order,
    /// and any one of them failing means nothing happens.
    private func considerMoving(_ pose: HeadPose?) {
        // 1. The state machine must permit movement. Exactly one state does.
        guard controller.state.allowsCursorMovement else {
            gate.reset()
            return
        }
        // 2. Calibration must still describe this desk.
        guard validity().isValid, let classifier else {
            gate.reset()
            return
        }
        // Keep the per-display memory in step with wherever the pointer is,
        // including moves the user made by hand — but never record our own
        // warp, or the memory converges on the fallback it started from and
        // stops tracking where the user actually works.
        let location = Cursor.location
        if location != lastWarpedPoint {
            lastWarpedPoint = nil
            cursorMemory.record(location, displays: snapshots)
        }

        // 3. A trusted face, and 4. a prediction past the margin gate.
        //    A nil prediction still feeds the gate, which drops its candidate.
        let prediction = pose.flatMap { classifier.classify(yaw: $0.yaw) }

        gate.dwell = Double(controller.settings.dwellMs) / 1000
        gate.typingIdle = controller.settings.typingIdleSeconds

        // 5. Dwell, hysteresis, and no repeated moves to the same target.
        guard let decision = gate.update(
            prediction,
            now: ProcessInfo.processInfo.systemUptime,
            keyboardIdle: KeyboardActivity.secondsSinceLastKeystroke()
        ) else { return }

        perform(decision)
    }

    private func perform(_ decision: MovementGate.Decision) {
        guard let snapshot = snapshots.first(where: { $0.id == decision.target.display }) else { return }

        // Before leaving, note which window the user was actually using on the
        // display they are looking away from. This is the only signal available
        // when they drive that display from the keyboard — the pointer there was
        // put by Glance, so it says nothing about intent.
        rememberDepartedDisplay(leavingFor: decision.target.display)

        // An explicit strip prediction wins; otherwise go back to where the user
        // was working on that display, and only fall back to its centre when
        // there is nothing remembered.
        var remembered = controller.settings.restoreCursorPosition
            ? cursorMemory.position(for: decision.target.display, displays: snapshots)
            : nil
        // A remembered point is only useful if something is still there. The
        // menu bar and a closed window's old position both record fine and then
        // focus nothing.
        if let candidate = remembered, FocusActivator.application(at: candidate) == nil {
            remembered = nil
        }
        let point = decision.target.strip.map(snapshot.stripCenter) ?? remembered ?? snapshot.center

        var description = snapshot.name
        if let strip = decision.target.strip {
            description += " · strip \(strip + 1)"
        } else if remembered != nil {
            description += " · where you left off"
        } else {
            description += " · centre"
        }

        if controller.settings.moveCursor {
            Cursor.move(to: point)
            lastWarpedPoint = point
        } else {
            description += " (cursor move off)"
        }

        let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        if controller.settings.activateApp {
            if decision.activateFocus {
                if let result = FocusActivator.focus(at: point) {
                    description += " → " + result.summary
                } else {
                    description += " → no window there"
                }
            } else {
                // Never take focus out from under a keystroke.
                description += " → focus held, you were typing"
            }
        }

        lastAction = description + "  (\(timeString()))"
        cursorMemoryStore.save(cursorMemory)
        logMove(point: point, description: description, frontmostBefore: before)
        if menuIsOpen { refreshDetails() }
    }

    private func rememberDepartedDisplay(leavingFor target: DisplayIdentifier) {
        guard let departed = snapshots.first(where: { $0.frame.contains(Cursor.location) }),
              departed.id != target,
              // An exact pointer position the user chose beats a window centre.
              !cursorMemory.hasObserved(departed.id),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window = FocusActivator.frontmostWindow(of: pid, within: departed.frame)
        else { return }

        // Clamp to the display: a window may straddle two of them.
        let centre = CGPoint(
            x: min(max(window.midX, departed.frame.minX + 1), departed.frame.maxX - 1),
            y: min(max(window.midY, departed.frame.minY + 1), departed.frame.maxY - 1)
        )
        cursorMemory.recordInferred(centre, for: departed.id, displays: snapshots)
    }

    /// Movement leaves no other trace, and "focus did not change" has several
    /// possible causes that look identical from the outside.
    private func logMove(point: CGPoint, description: String, frontmostBefore: String) {
        let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let line = String(
            format: "%@  %@  at (%.0f, %.0f)  frontmost %@ → %@%@\n",
            ISO8601DateFormatter().string(from: Date()), description,
            point.x, point.y, frontmostBefore, after,
            WindowRaiser.isPermitted ? "" : "  [no Accessibility: cannot raise a window]"
        )
        let url = CalibrationStore.directory.appendingPathComponent("movement.log")
        try? FileManager.default.createDirectory(at: CalibrationStore.directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func timeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    private func stateChanged(_ state: TrackingState) {
        if state == .calibrating, runner == nil {
            beginCalibration()
        }
        if state == .tracking, wantsCalibration, runner == nil {
            wantsCalibration = false
            controller.apply(.recalibrate)
            return
        }
        if state == .disabled {
            runner?.cancel()
            gate.reset()
        }
        refresh()
    }

    private func beginCalibration() {
        wantsCalibration = false
        reloadCalibration()
        let runner = CalibrationRunner(
            snapshots: snapshots, allowStrips: controller.settings.enableStrips
        )
        runner.onOutcome = { [weak self] outcome in self?.calibrationFinished(outcome) }
        self.runner = runner
        runner.start()
    }

    private func calibrationFinished(_ outcome: CalibrationRunner.Outcome) {
        runner = nil
        switch outcome {
        case .finished(let saved):
            // Recalibrating keeps the current profile's name and identity;
            // a fresh desk gets a new entry named after its displays.
            // Replace this desk's existing profile even when it was judged
            // unusable, rather than leaving a duplicate behind.
            let existing = active ?? library.entry(coveringDisplaysOf: snapshots)
            let suggested = existing?.name ?? CalibrationLibrary.suggestedName(for: snapshots)
            let name = prompt("Name this setup", "So you can pick it again at another desk.", suggested)
                ?? suggested
            let entry = NamedCalibration(id: existing?.id ?? UUID(), name: name, profile: saved)
            library.upsert(entry)
            library.pinnedID = nil  // let it match automatically from now on
            guard libraryStore.save(library) else {
                controller.apply(.disable)
                warn("Calibration failed", "The profile could not be saved.")
                return
            }
            active = entry
            classifier = YawClassifier(profile: saved, connected: snapshots)

            // A profile that is unusable the moment it is saved would demand
            // calibration again immediately. Say so instead of looping.
            let check = saved.validity(against: snapshots)
            if !check.isValid {
                controller.apply(.disable)
                warn("Calibration is not usable", """
                \(check.explanation)

                The profile was saved, but tracking will not run against it. \
                Recalibrate sitting the way you normally work, and look straight \
                at each dot rather than moving your eyes to it.
                """)
                refresh()
                return
            }
            // A new mapping invalidates whatever the gate had accepted.
            gate.reset()
            cursorMemory.forgetAll()
            controller.apply(.calibrationFinished)
            reportCalibration(saved)
        case .cancelled:
            // Returning to tracking is only honest if a usable profile exists.
            if validity().isValid {
                controller.apply(.calibrationFinished)
            } else {
                controller.apply(.disable)
            }
        case .failed(let message):
            controller.apply(.disable)
            warn("Calibration failed", message)
        }
        refresh()
    }

    private func reportCalibration(_ profile: CalibrationProfile) {
        var lines = ["Saved as “\(active?.name ?? "setup")”.", ""] + profile.displays.map { display in
            String(format: "• %@ — strips %@ (%.0f%% separable)",
                   display.name,
                   display.stripsEnabled ? "enabled" : "disabled",
                   display.stripSeparability * 100)
        }
        if profile.displays.count > 1 {
            lines.insert(String(format: "Displays separate at %.0f%%.",
                                profile.displaySeparability * 100), at: 0)
        }
        if !controller.settings.enableStrips {
            lines.append("")
            lines.append("""
            Strips are off, so each display is targeted as a whole. Repeated \
            measurement found column separability unstable between sessions, so \
            it is measured and reported above but not acted on unless you turn \
            strips on in Settings.
            """)
        }
        warn("Calibration saved", lines.joined(separator: "\n"), style: .informational)
    }

    private func screensChanged() {
        reloadCalibration()
        let validity = validity()
        if !validity.isValid, controller.state == .tracking, !explainingScreenChange {
            // Movement already fails closed on the invalid mapping. Explain
            // before calibrating: the overlay sits at screen-saver level and
            // would hide the alert. One reconnect fires several notifications,
            // and they arrive during the modal, so explain only once.
            explainingScreenChange = true
            warn("Recalibration required", validity.explanation)
            explainingScreenChange = false
            controller.apply(.recalibrate)
        }
        refresh()
    }

    private func warn(_ title: String, _ body: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = style
        NSApp.activate()
        alert.runModal()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: controller.settings) { [weak self] updated in
                self?.controller.settings = updated
                self?.visionEngine?.apply(updated)
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Glance Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        hotKey?.unregister()
        NSApp.terminate(nil)
    }

    // MARK: - Self-check

    // Driving the real menu needs Accessibility permission, which a terminal or
    // CI run will not have. These let `Glance --selftest` verify the menu is
    // actually built and actually re-renders on state change.

    var stateDescription: String { statusText(for: controller.state) }

    var menuTitles: [String] {
        (statusItem?.menu?.items ?? []).map {
            $0.isSeparatorItem ? "---" : $0.title + ($0.action == nil ? "  [info]" : "")
        }
    }

    func simulateToggle() { controller.toggle() }
}
