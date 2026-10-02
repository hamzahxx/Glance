// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Glance",
    platforms: [.macOS(.v14)],
    targets: [
        // Engine and logic: no AppKit. The testable half of the app.
        .target(name: "GlanceCore"),
        .executableTarget(name: "GlanceApp", dependencies: ["GlanceCore"]),
        // Feasibility probe (PRD §12 critical unknown). Not part of the app.
        .executableTarget(name: "GlanceProbe", dependencies: ["GlanceCore"]),
        .testTarget(name: "GlanceCoreTests", dependencies: ["GlanceCore"]),
    ]
)
