import Foundation
import GlanceCore

/// Rebuilds the report from a CSV a previous run wrote, so the analysis can be
/// changed and re-scored without asking anyone to sit through another capture.
enum Replay {
    static func run(path: String) -> Never {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("cannot read \(url.path)")
            exit(1)
        }

        var samples: [Sample] = []
        var names: [Int: String] = [:]
        for row in text.split(separator: "\n").dropFirst() {
            let f = splitCSV(String(row))
            guard f.count >= 7,
                  let round = Int(f[0]), let screen = Int(f[1]), let target = Int(f[3]),
                  let yaw = Double(f[4]), let pitch = Double(f[5]), let roll = Double(f[6])
            else { continue }
            names[screen] = f[2]
            samples.append(Sample(
                round: round, screen: screen, target: target,
                pose: HeadPose(yaw: yaw, pitch: pitch, roll: roll,
                               faceArea: f.count > 7 ? Double(f[7]) ?? 0 : 0)
            ))
        }

        guard !samples.isEmpty else {
            print("no samples parsed from \(url.path)")
            exit(1)
        }

        let ordered = (0...(names.keys.max() ?? 0)).map { names[$0] ?? "?" }
        print(buildReport(
            samples: samples,
            screenNames: ordered,
            framesSeen: 0,  // not recorded in the CSV
            framesWithFace: 0,
            device: "replayed from \(url.lastPathComponent)"
        ))
        exit(0)
    }

    private static func splitCSV(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            switch character {
            case "\"": inQuotes.toggle()
            case "," where !inQuotes: fields.append(current); current = ""
            default: current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}
