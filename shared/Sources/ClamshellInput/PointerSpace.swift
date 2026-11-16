import ClamshellWire

/// The phone's locally drawn cursor (ADR-0009) lives in *picture points*: the stream picture's pixels / its
/// scale. The Mac's display may be bigger than the picture: mirroring a 1335-point screen into a 1600-pixel
/// away picture gives an 800-point picture. Everything the phone and the Mac exchange about the pointer must
/// then use the same space, or the phone's prediction runs ahead of the real pointer and snaps back:
/// - cursor positions are reported in picture points (the injector already does);
/// - relative moves arrive in picture points and are applied as display points (`displayDelta`);
/// - cursor shapes are measured in display points and sent in picture points (`pictureShape`).
/// At home on a full-size picture the two are equal and nothing changes.
public struct PointerSpace: Sendable, Equatable {
    /// Display points per picture point (≥ 1 when the picture is shrunk).
    public let scaleX: Double
    public let scaleY: Double

    public init(pictureWidth: Double, pictureHeight: Double, displayWidth: Double, displayHeight: Double) {
        scaleX = pictureWidth > 0 && displayWidth > 0 ? displayWidth / pictureWidth : 1
        scaleY = pictureHeight > 0 && displayHeight > 0 ? displayHeight / pictureHeight : 1
    }

    public var isIdentity: Bool { abs(scaleX - 1) < 0.001 && abs(scaleY - 1) < 0.001 }

    /// A relative move from the phone (picture points) → the Mac (display points).
    public func displayDelta(dx: Double, dy: Double) -> (dx: Double, dy: Double) {
        (dx * scaleX, dy * scaleY)
    }

    /// A shape measured on the Mac (display points × 16) → the size the phone draws it at in the picture.
    /// The PNG stays as it is; only its drawn size and hotspot shrink with the picture.
    public func pictureShape(_ s: CursorShape) -> CursorShape {
        guard !isIdentity else { return s }
        func x(_ v: UInt32) -> UInt32 { UInt32((Double(v) / scaleX).rounded()) }
        func y(_ v: UInt32) -> UInt32 { UInt32((Double(v) / scaleY).rounded()) }
        return CursorShape(shapeId: s.shapeId, png: s.png, hotX: x(s.hotX), hotY: y(s.hotY), width: max(1, x(s.width)), height: max(1, y(s.height)))
    }
}
