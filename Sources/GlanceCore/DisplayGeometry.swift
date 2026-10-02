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

    public init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
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

        return ids.prefix(Int(count)).map { id in
            DisplaySnapshot(
                id: DisplayIdentifier(
                    vendor: CGDisplayVendorNumber(id),
                    model: CGDisplayModelNumber(id),
                    serial: CGDisplaySerialNumber(id)
                ),
                cgID: id,
                frame: CGDisplayBounds(id)
            )
        }
    }
}
