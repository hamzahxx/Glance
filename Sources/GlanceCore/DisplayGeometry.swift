import CoreGraphics
import Foundation

/// Identifies a physical display across reconnects and rearrangement.
///
/// Deliberately excludes position and size: moving a monitor must not create a
/// new identity, while a *changed* arrangement must still invalidate the
/// calibration built against it. Those are separate concerns and are checked
/// separately.
public struct DisplayIdentifier: Codable, Hashable, Sendable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    /// Tiebreaker for displays that report the same vendor, model and serial —
    /// identical monitors often report serial 0. 0 for the first (leftmost) of
    /// such a group, so a display without a twin keeps the identity profiles
    /// saved before this field existed.
    public var index: UInt32

    public init(vendor: UInt32, model: UInt32, serial: UInt32, index: UInt32 = 0) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.index = index
    }

    private enum CodingKeys: String, CodingKey { case vendor, model, serial, index }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vendor = try c.decode(UInt32.self, forKey: .vendor)
        model = try c.decode(UInt32.self, forKey: .model)
        serial = try c.decode(UInt32.self, forKey: .serial)
        index = try c.decodeIfPresent(UInt32.self, forKey: .index) ?? 0
    }
}

public struct DisplaySnapshot: Sendable, Equatable {
    public var id: DisplayIdentifier
    /// CGDirectDisplayID. Runtime only — it is not stable across reconnects and
    /// is never persisted.
    public var cgID: UInt32
    /// CoreGraphics global coordinates, origin top-left. Mixing AppKit and
    /// CoreGraphics coordinate spaces is the classic bug here; this is the one
    /// source of truth for geometry.
    public var frame: CGRect
    public var name: String

    public init(id: DisplayIdentifier, cgID: UInt32, frame: CGRect, name: String = "") {
        self.id = id
        self.cgID = cgID
        self.frame = frame
        self.name = name
    }

    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// Centre of one of three vertical strips, in CoreGraphics coordinates.
    public func stripCenter(_ index: Int) -> CGPoint {
        let clamped = min(max(index, 0), 2)
        let width = frame.width / 3
        return CGPoint(x: frame.minX + width * (Double(clamped) + 0.5), y: frame.midY)
    }
}

public enum DisplayGeometry {
    public static func current() -> [DisplaySnapshot] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        return disambiguated(ids.prefix(Int(count)).map { id in
            DisplaySnapshot(
                id: DisplayIdentifier(
                    vendor: CGDisplayVendorNumber(id),
                    model: CGDisplayModelNumber(id),
                    serial: CGDisplaySerialNumber(id)
                ),
                cgID: id,
                frame: CGDisplayBounds(id)
            )
        })
    }

    /// Gives displays that share vendor, model and serial distinct identities,
    /// numbered left to right (then top to bottom). Two identical monitors
    /// cannot be told apart by hardware, so position is the only stable
    /// handle; swapping them is indistinguishable from not swapping them.
    public static func disambiguated(_ snapshots: [DisplaySnapshot]) -> [DisplaySnapshot] {
        var result = snapshots
        let groups = Dictionary(grouping: result.indices) { result[$0].id }
        for indices in groups.values where indices.count > 1 {
            let ordered = indices.sorted {
                let a = result[$0].frame, b = result[$1].frame
                return (a.minX, a.minY, result[$0].cgID) < (b.minX, b.minY, result[$1].cgID)
            }
            for (n, i) in ordered.enumerated() { result[i].id.index = UInt32(n) }
        }
        return result
    }
}
