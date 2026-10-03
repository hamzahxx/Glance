import CoreGraphics
import Foundation
import Testing
@testable import GlanceCore

@Test("An app in the pause list holds movement")
func pausedAppHolds() {
    let settings = Settings(pausedApps: ["us.zoom.xos"])
    #expect(PauseRules.suppression(frontmostBundleID: "us.zoom.xos", frontmostIsFullscreen: false,
                                   settings: settings) == .app("us.zoom.xos"))
    #expect(PauseRules.suppression(frontmostBundleID: "com.apple.Safari", frontmostIsFullscreen: false,
                                   settings: settings) == nil)
    #expect(PauseRules.suppression(frontmostBundleID: nil, frontmostIsFullscreen: false,
                                   settings: settings) == nil)
}

@Test("Fullscreen holds movement only while the setting is on")
func fullscreenFollowsSetting() {
    #expect(PauseRules.suppression(frontmostBundleID: "com.apple.Keynote", frontmostIsFullscreen: true,
                                   settings: Settings()) == .fullscreen)
    #expect(PauseRules.suppression(frontmostBundleID: "com.apple.Keynote", frontmostIsFullscreen: true,
                                   settings: Settings(pauseWhenFullscreen: false)) == nil)
}

@Test("A window covering a display's full frame is fullscreen; a maximised one is not")
func fullscreenBounds() {
    let displays = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                    CGRect(x: 1440, y: 0, width: 2560, height: 1440)]
    #expect(PauseRules.isFullscreen(windowBounds: [CGRect(x: 1440, y: 0, width: 2560, height: 1440)],
                                    displayFrames: displays))
    // Maximised: below the 25 pt menu bar.
    #expect(!PauseRules.isFullscreen(windowBounds: [CGRect(x: 0, y: 25, width: 1440, height: 875)],
                                     displayFrames: displays))
    #expect(!PauseRules.isFullscreen(windowBounds: [], displayFrames: displays))
}

@Test("Settings saved before pause rules load with fullscreen on and no apps")
func pauseRulesDecodeDefaults() throws {
    let old = Data(#"{"version":1,"dwellMs":500}"#.utf8)
    let settings = try JSONDecoder().decode(Settings.self, from: old)
    #expect(settings.pauseWhenFullscreen)
    #expect(settings.pausedApps.isEmpty)
    #expect(settings.dwellMs == 500)
}
