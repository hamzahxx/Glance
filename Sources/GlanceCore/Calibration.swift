import CoreGraphics
import Foundation

public struct StripCalibration: Codable, Equatable, Sendable {
    public var index: Int
    public var yawMean: Double
    public var yawStd: Double
    public var sampleCount: Int
}

public struct DisplayCalibration: Codable, Equatable, Sendable {
    public var display: DisplayIdentifier
    public var name: String
    public var bounds: CGRect
    /// Display-level yaw centroid. This is what display classification uses.
    public var yawMean: Double
    public var strips: [StripCalibration]
    /// Held-out column accuracy measured during calibration, 0...1.
    public var stripSeparability: Double
    /// Strips are only offered where this display earned them.
    public var stripsEnabled: Bool
}

public enum CalibrationValidity: Equatable, Sendable {
    case valid
    case missing
    case uncalibratedDisplay(String)
    case geometryChanged(String)
    case unusable(String)
    case outdated

    public var isValid: Bool { self == .valid }

    public var explanation: String {
        switch self {
        case .valid: "calibrated"
        case .missing: "no calibration yet"
        case .uncalibratedDisplay(let name): "\(name) is not calibrated"
        case .geometryChanged(let name): "\(name) moved or changed resolution"
        case .unusable(let why): why
        case .outdated: "calibration was saved by an older version"
        }
    }
}

public struct CalibrationProfile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// A display earns vertical strips only at or above this held-out accuracy.
    public static let stripEligibilityThreshold = 0.95
    /// Below this, displays are not separable and nothing should move at all.
    public static let displayUsabilityThreshold = 0.90

    public var version: Int
    public var createdAt: Date
    public var displays: [DisplayCalibration]
    /// Held-out display-classification accuracy measured during calibration.
    public var displaySeparability: Double

    public func calibration(for id: DisplayIdentifier) -> DisplayCalibration? {
        displays.first { $0.display == id }
    }

    /// Fail closed: anything unrecognised means "require calibration", never
    /// "carry on and hope".
    public func validity(against snapshots: [DisplaySnapshot]) -> CalibrationValidity {
        guard version == Self.currentVersion else { return .outdated }
        guard !displays.isEmpty else { return .missing }

        if snapshots.count > 1, displaySeparability < Self.displayUsabilityThreshold {
            return .unusable(String(
                format: "displays separate at only %.0f%% — recalibrate, or move them further apart",
                displaySeparability * 100
            ))
        }

        for snapshot in snapshots {
            guard let calibration = calibration(for: snapshot.id) else {
                return .uncalibratedDisplay(snapshot.name.isEmpty ? "a display" : snapshot.name)
            }
            // A disconnected display's entry is simply unused; a *moved* one
            // invalidates, because its mapping no longer points anywhere real.
            guard calibration.bounds.equalTo(snapshot.frame) else {
                return .geometryChanged(snapshot.name.isEmpty ? calibration.name : snapshot.name)
            }
        }
        return .valid
    }
}

public struct CalibrationStore {
    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".Glance")
    public static let defaultURL = directory.appendingPathComponent("calibration.json")

    private let url: URL

    public init(url: URL = CalibrationStore.defaultURL) {
        self.url = url
    }

    public func load() -> CalibrationProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        // Must match `save`; a mismatch here silently loses every calibration.
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CalibrationProfile.self, from: data)
    }

    @discardableResult
    public func save(_ profile: CalibrationProfile) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(profile) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Building a profile from captured samples

public enum CalibrationBuilder {
    public struct Sample: Equatable, Sendable {
        public var display: DisplayIdentifier
        public var strip: Int
        public var round: Int
        public var yaw: Double

        public init(display: DisplayIdentifier, strip: Int, round: Int, yaw: Double) {
            self.display = display
            self.strip = strip
            self.round = round
            self.yaw = yaw
        }
    }

    public static let minimumSamplesPerStrip = 10

    /// Frames averaged before scoring separability.
    ///
    /// This must match how the app actually decides. At runtime a target has to
    /// hold for the dwell period (~12 frames at 30 fps) before anything moves,
    /// so scoring single frames judges calibration by a far harsher standard
    /// than it is ever held to — the probe measured 97.3% per frame against
    /// 99.7% dwell-averaged for the same data. A good desk scoring 0.89 that way
    /// was then rejected as unusable, which demanded recalibration in a loop.
    public static let dwellFrames = 12

    public enum Failure: Error, Equatable {
        case noSamples
        case tooFewSamples(String)
    }

    /// `allowStrips` defaults to false. Three probe runs on the same desk within
    /// one hour measured the same display's column separability at 97%, 99% and
    /// 79%, so a single calibration session's score over-estimates how durable
    /// strips are. Measuring them is useful; auto-enabling them is not.
    public static func build(
        samples: [Sample],
        snapshots: [DisplaySnapshot],
        allowStrips: Bool = false,
        now: Date = Date()
    ) -> Result<CalibrationProfile, Failure> {
        guard !samples.isEmpty else { return .failure(.noSamples) }

        var calibrations: [DisplayCalibration] = []
        for snapshot in snapshots {
            let mine = samples.filter { $0.display == snapshot.id }
            guard !mine.isEmpty else { continue }

            var strips: [StripCalibration] = []
            for index in 0..<3 {
                let yaws = mine.filter { $0.strip == index }.map(\.yaw)
                guard yaws.count >= minimumSamplesPerStrip else {
                    return .failure(.tooFewSamples(
                        "\(snapshot.name.isEmpty ? "display" : snapshot.name), target \(index + 1)"
                    ))
                }
                strips.append(StripCalibration(
                    index: index,
                    yawMean: Stats.mean(yaws),
                    yawStd: Stats.std(yaws),
                    sampleCount: yaws.count
                ))
            }

            // Held-out: train on the first pass, score the second. Scoring the
            // pass we fitted on would read near-perfect regardless.
            let separability = heldOutAccuracy(
                train: dwellAveraged(mine.filter { $0.round == 0 }, by: \.strip),
                test: dwellAveraged(mine.filter { $0.round > 0 }, by: \.strip)
            )

            calibrations.append(DisplayCalibration(
                display: snapshot.id,
                name: snapshot.name,
                bounds: snapshot.frame,
                yawMean: Stats.mean(mine.map(\.yaw)),
                strips: strips,
                stripSeparability: separability,
                stripsEnabled: allowStrips && separability >= CalibrationProfile.stripEligibilityThreshold
            ))
        }

        guard !calibrations.isEmpty else { return .failure(.noSamples) }

        let displaySeparability: Double
        if calibrations.count < 2 {
            displaySeparability = 1
        } else {
            var train: [Int: [Double]] = [:]
            var test: [Int: [Double]] = [:]
            for (index, calibration) in calibrations.enumerated() {
                let mine = samples.filter { $0.display == calibration.display }
                train[index] = dwellAveraged(mine.filter { $0.round == 0 }, by: { _ in 0 })[0] ?? []
                test[index] = dwellAveraged(mine.filter { $0.round > 0 }, by: { _ in 0 })[0] ?? []
            }
            displaySeparability = heldOutAccuracy(train: train, test: test)
        }

        return .success(CalibrationProfile(
            version: CalibrationProfile.currentVersion,
            createdAt: now,
            displays: calibrations,
            displaySeparability: displaySeparability
        ))
    }

    /// Rolling means over `dwellFrames` consecutive samples of the same target,
    /// grouped by `label`. A burst shorter than the window contributes its own
    /// mean rather than nothing, so a short capture is still scored.
    static func dwellAveraged(
        _ samples: [Sample], by label: (Sample) -> Int
    ) -> [Int: [Double]] {
        var out: [Int: [Double]] = [:]
        for (key, burst) in Dictionary(grouping: samples, by: { "\($0.strip).\($0.round).\(label($0))" }) {
            guard let first = burst.first else { continue }
            let yaws = burst.map(\.yaw)
            let group = label(first)
            guard yaws.count >= dwellFrames else {
                out[group, default: []].append(Stats.mean(yaws))
                continue
            }
            for start in 0...(yaws.count - dwellFrames) {
                out[group, default: []].append(Stats.mean(Array(yaws[start..<(start + dwellFrames)])))
            }
        }
        return out
    }

    /// Nearest-centroid accuracy in one dimension: fit centroids on `train`,
    /// score `test`. Returns 0 when there is nothing held out to score.
    public static func heldOutAccuracy(train: [Int: [Double]], test: [Int: [Double]]) -> Double {
        let centroids = train.compactMapValues { $0.isEmpty ? nil : Stats.mean($0) }
        guard centroids.count > 1 else { return centroids.isEmpty ? 0 : 1 }

        var correct = 0, total = 0
        for (label, values) in test {
            for value in values {
                total += 1
                let predicted = centroids.min { abs(value - $0.value) < abs(value - $1.value) }?.key
                if predicted == label { correct += 1 }
            }
        }
        guard total > 0 else { return 0 }
        return Double(correct) / Double(total)
    }
}
