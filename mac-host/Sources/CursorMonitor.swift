import AppKit
import ClamshellWire

/// Watches the system cursor's shape (10 Hz) and hands each new shape over once, as a 2× PNG, for the
/// phone's locally drawn cursor (ADR-0009). Shapes are identified by an FNV-1a hash of the PNG.
@MainActor
final class CursorMonitor {
    private var timer: Timer?
    private var lastKey: String?
    private var sent: Set<UInt64> = []
    private let onShape: (CursorShape, _ isNew: Bool) -> Void

    init(onShape: @escaping (CursorShape, Bool) -> Void) { self.onShape = onShape }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { self.poll() } }
        poll()
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image, hot = cursor.hotSpot
        let size = image.size
        guard size.width > 0, size.height > 0, size.width <= 256, size.height <= 256 else { return }
        // Cheap change check before rendering: the image object and hotspot.
        let key = "\(ObjectIdentifier(image).hashValue):\(hot.x),\(hot.y):\(size.width)x\(size.height)"
        guard key != lastKey else { return }
        lastKey = key
        guard let png = Self.png(image, scale: 2) else { return }
        let id = Self.fnv1a(png)
        let shape = CursorShape(shapeId: id, png: png, hotX: UInt32(max(0, hot.x) * 16), hotY: UInt32(max(0, hot.y) * 16),
                                width: UInt32(size.width * 16), height: UInt32(size.height * 16))
        let isNew = sent.insert(id).inserted
        onShape(shape, isNew)
    }

    /// Forget what the phone has (a new session).
    func reset() { sent.removeAll(); lastKey = nil }

    static func png(_ image: NSImage, scale: CGFloat) -> [UInt8]? {
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]).map { [UInt8]($0) }
    }

    static func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 }
        return h == 0 ? 1 : h
    }
}
