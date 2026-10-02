import Foundation

public struct NamedCalibration: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var profile: CalibrationProfile

    public init(id: UUID = UUID(), name: String, profile: CalibrationProfile) {
        self.id = id
        self.name = name
        self.profile = profile
    }
}

/// Several named calibrations — one per desk.
///
/// A profile already identifies its displays by vendor, model and serial, so the
/// right one for the desk you are sitting at can be recognised rather than
/// chosen. Pinning exists for the cases recognition cannot settle: two desks
/// with identical monitor models, or wanting to test one setup's numbers from
/// somewhere else.
public struct CalibrationLibrary: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var profiles: [NamedCalibration]
    /// nil means "match the connected displays automatically".
    public var pinnedID: UUID?

    public init(
        version: Int = CalibrationLibrary.currentVersion,
        profiles: [NamedCalibration] = [],
        pinnedID: UUID? = nil
    ) {
        self.version = version
        self.profiles = profiles
        self.pinnedID = pinnedID
    }

    /// The calibration to use right now.
    ///
    /// A pinned profile is returned even when it does not fit the displays
    /// present: the caller checks validity and explains the mismatch, rather
    /// than this quietly substituting a different desk's numbers.
    public func active(for snapshots: [DisplaySnapshot]) -> NamedCalibration? {
        if let pinnedID, let pinned = profiles.first(where: { $0.id == pinnedID }) {
            return pinned
        }
        return profiles
            .filter { $0.profile.validity(against: snapshots).isValid }
            .max { $0.profile.createdAt < $1.profile.createdAt }
    }

    /// Profiles that would work at this desk, newest first.
    public func candidates(for snapshots: [DisplaySnapshot]) -> [NamedCalibration] {
        profiles
            .filter { $0.profile.validity(against: snapshots).isValid }
            .sorted { $0.profile.createdAt > $1.profile.createdAt }
    }

    /// The entry covering exactly this set of displays, whatever its validity.
    ///
    /// Recalibrating a desk must replace that desk's profile. Matching on
    /// validity instead would create a duplicate every time the old profile was
    /// judged unusable, which is how two profiles for one desk appeared.
    public func entry(coveringDisplaysOf snapshots: [DisplaySnapshot]) -> NamedCalibration? {
        let wanted = Set(snapshots.map(\.id))
        guard !wanted.isEmpty else { return nil }
        return profiles.first { Set($0.profile.displays.map(\.display)) == wanted }
    }

    public mutating func upsert(_ entry: NamedCalibration) {
        if let index = profiles.firstIndex(where: { $0.id == entry.id }) {
            profiles[index] = entry
        } else {
            profiles.append(entry)
        }
    }

    public mutating func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if pinnedID == id { pinnedID = nil }
    }

    /// A default name for a new profile, from the displays it was built against.
    public static func suggestedName(for snapshots: [DisplaySnapshot]) -> String {
        let names = snapshots.map(\.name).filter { !$0.isEmpty }
        guard !names.isEmpty else { return "Setup" }
        return names.joined(separator: " + ")
    }
}

public struct CalibrationLibraryStore {
    public static let defaultURL = CalibrationStore.directory
        .appendingPathComponent("calibrations.json")

    private let url: URL
    private let legacy: CalibrationStore

    public init(
        url: URL = CalibrationLibraryStore.defaultURL,
        legacy: CalibrationStore = CalibrationStore()
    ) {
        self.url = url
        self.legacy = legacy
    }

    /// Loads the library, adopting a single pre-library calibration if one is
    /// the only thing on disk. The old file is left alone rather than deleted.
    public func load(migrationName: @autoclosure () -> String = "Imported setup") -> CalibrationLibrary {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let library = try? decoder.decode(CalibrationLibrary.self, from: data),
               library.version == CalibrationLibrary.currentVersion {
                return library
            }
        }
        guard let old = legacy.load() else { return CalibrationLibrary() }
        var library = CalibrationLibrary(profiles: [
            NamedCalibration(name: migrationName(), profile: old)
        ])
        library.pinnedID = nil
        save(library)
        return library
    }

    @discardableResult
    public func save(_ library: CalibrationLibrary) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(library) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
