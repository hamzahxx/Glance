import Foundation

/// A Glance move the user apparently did not want.
public enum Regret: String, Codable, Equatable, Sendable {
    /// The user's own pointer left the target display soon after the move.
    case handRevert = "hand-revert"
    /// Glance itself moved away from the target soon after.
    case bounce
}

/// A regret and the display (the move's target) it is charged to.
public struct RegretEvent: Equatable, Sendable {
    public var kind: Regret
    public var display: DisplayIdentifier
}

public struct RegretTally: Codable, Equatable, Sendable {
    public var moves = 0
    public var handReverts = 0
    public var bounces = 0

    public init(moves: Int = 0, handReverts: Int = 0, bounces: Int = 0) {
        self.moves = moves
        self.handReverts = handReverts
        self.bounces = bounces
    }

    /// (reverts + bounces) / moves, as a whole percent.
    public var percent: Int {
        moves == 0 ? 0 : (handReverts + bounces) * 100 / moves
    }
}

/// Daily tallies, keyed by day ("yyyy-MM-dd") then display. Display keys are
/// strings because JSON object keys must be.
public struct RegretStats: Codable, Equatable, Sendable {
    public var version = 1
    public var days: [String: [String: RegretTally]] = [:]

    public init() {}

    public static func key(_ id: DisplayIdentifier) -> String {
        "\(id.vendor)-\(id.model)-\(id.serial)-\(id.index)"
    }

    /// Every display's tally for one day, summed.
    public func total(day: String) -> RegretTally {
        (days[day] ?? [:]).values.reduce(into: RegretTally()) {
            $0.moves += $1.moves
            $0.handReverts += $1.handReverts
            $0.bounces += $1.bounces
        }
    }

    /// Drops days before `oldestKept`. ISO dates sort as strings.
    public mutating func prune(keepingFrom oldestKept: String) {
        days = days.filter { $0.key >= oldestKept }
    }
}

/// Counts Glance moves and flags the ones that were regretted. Pure: the
/// caller supplies time (any monotonic clock) and the calendar day.
///
/// Only the latest move is watched, and it can earn at most one regret.
public struct RegretTracker: Sendable {
    public static let handRevertWindow: TimeInterval = 2.0
    public static let bounceWindow: TimeInterval = 1.5

    public private(set) var stats: RegretStats

    private var last: (target: DisplayIdentifier, at: TimeInterval, day: String)?

    public init(stats: RegretStats = RegretStats()) {
        self.stats = stats
    }

    /// Glance moved to `target`. Returns a bounce, charged to the previous
    /// target, when this move leaves it within the bounce window.
    @discardableResult
    public mutating func recordMove(to target: DisplayIdentifier, at time: TimeInterval, day: String) -> RegretEvent? {
        var regret: RegretEvent?
        if let last, last.target != target, time - last.at <= Self.bounceWindow {
            count(.bounce, for: last.target, day: last.day)
            regret = RegretEvent(kind: .bounce, display: last.target)
        }
        stats.days[day, default: [:]][RegretStats.key(target), default: RegretTally()].moves += 1
        last = (target, time, day)
        return regret
    }

    /// The user's own pointer is on `display`. Never pass a position Glance
    /// set itself. Returns a hand revert when it left the last target in time.
    @discardableResult
    public mutating func observeUserPointer(on display: DisplayIdentifier?, at time: TimeInterval) -> RegretEvent? {
        guard let last, let display, display != last.target,
              time - last.at <= Self.handRevertWindow
        else { return nil }
        count(.handRevert, for: last.target, day: last.day)
        self.last = nil
        return RegretEvent(kind: .handRevert, display: last.target)
    }

    private mutating func count(_ regret: Regret, for target: DisplayIdentifier, day: String) {
        let key = RegretStats.key(target)
        switch regret {
        case .handRevert: stats.days[day, default: [:]][key, default: RegretTally()].handReverts += 1
        case .bounce: stats.days[day, default: [:]][key, default: RegretTally()].bounces += 1
        }
    }
}

/// Persists regret stats in ~/.Glance, keeping the last 30 days.
public struct RegretStatsStore {
    public static let defaultURL = CalibrationStore.directory
        .appendingPathComponent("regret-stats.json")
    public static let daysKept = 30

    private let url: URL

    public init(url: URL = RegretStatsStore.defaultURL) {
        self.url = url
    }

    public func load() -> RegretStats {
        guard let data = try? Data(contentsOf: url),
              let stats = try? JSONDecoder().decode(RegretStats.self, from: data)
        else { return RegretStats() }
        return stats
    }

    @discardableResult
    public func save(_ stats: RegretStats, today: Date = Date()) -> Bool {
        var stats = stats
        let oldest = Calendar.current.date(byAdding: .day, value: -(Self.daysKept - 1), to: today) ?? today
        stats.prune(keepingFrom: Self.day(oldest))
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(stats) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Local calendar day, "yyyy-MM-dd".
    public static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
