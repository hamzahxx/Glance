import AppKit

// Feasibility probe for the question the whole design rests on: can the webcam
// distinguish broad screen regions from head pose alone, in the user's real
// posture? Not part of the shipping app.

func argument(_ name: String, default fallback: Double) -> Double {
    guard let i = CommandLine.arguments.firstIndex(of: "--\(name)"),
          i + 1 < CommandLine.arguments.count,
          let value = Double(CommandLine.arguments[i + 1])
    else { return fallback }
    return value
}

if CommandLine.arguments.contains("--verify") {
    Verify.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--replay"), i + 1 < CommandLine.arguments.count {
    Replay.run(path: CommandLine.arguments[i + 1])
}

var config = Sequencer.Config()
config.rounds = max(1, Int(argument("rounds", default: 2)))
config.settle = argument("settle", default: 0.8)
config.collect = argument("collect", default: 1.5)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let sequencer = Sequencer(config: config)
Task { @MainActor in await sequencer.run() }

app.run()
