import CoreGraphics

/// Zoom of the Mac's picture on the phone: pinch on the picture to read small text. The Mac doesn't change.
/// - The trackpad over the picture queues pinches (`pinch`); the video view applies them every frame against
///   the picture's fitted rect (`frame`), so the point under the fingers stays under them.
/// - While zoomed the view follows the Mac's pointer: when the pointer moves out of the middle 70% of the
///   view, the picture slides to bring it back. Panning with the pinch moves it too.
/// - It never shows past the picture's edges; pinching back to 1× shows the whole screen again.
@MainActor
final class PictureZoom {
    static let maxScale: CGFloat = 5
    private(set) var scale: CGFloat = 1
    private var origin: CGPoint = .zero
    private var pending: [(factor: CGFloat, at: CGPoint, pan: CGVector)] = []
    private var lastCursor: CGPoint?

    var isZoomed: Bool { scale > 1.001 }

    func pinch(factor: Double, x: Double, y: Double, dx: Double, dy: Double) {
        guard factor.isFinite, factor > 0 else { return }
        pending.append((CGFloat(factor), CGPoint(x: x, y: y), CGVector(dx: dx, dy: dy)))
    }

    func reset() {
        scale = 1
        pending.removeAll()
        lastCursor = nil
    }

    /// Where to draw the picture. `fitted`: its rect at 1×; `cursor`: the Mac pointer as fractions of the
    /// picture (nil when it isn't shown).
    func frame(fitted: CGRect, in bounds: CGRect, cursor: CGPoint?) -> CGRect {
        guard fitted.width > 0, fitted.height > 0 else { return fitted }
        for p in pending {
            let old = rect(fitted)
            let u = (p.at.x - old.minX) / old.width, v = (p.at.y - old.minY) / old.height
            scale = min(max(scale * p.factor, 1), Self.maxScale)
            let w = fitted.width * scale, h = fitted.height * scale
            origin = CGPoint(x: p.at.x - u * w + p.pan.dx, y: p.at.y - v * h + p.pan.dy)
        }
        pending.removeAll()
        guard isZoomed else { scale = 1; lastCursor = cursor; return fitted }

        var r = rect(fitted)
        if let c = cursor, c != lastCursor {
            if lastCursor != nil {
                let px = r.minX + c.x * r.width, py = r.minY + c.y * r.height
                let mx = bounds.width * 0.15, my = bounds.height * 0.15
                if px < bounds.minX + mx { r.origin.x += bounds.minX + mx - px }
                else if px > bounds.maxX - mx { r.origin.x -= px - (bounds.maxX - mx) }
                if py < bounds.minY + my { r.origin.y += bounds.minY + my - py }
                else if py > bounds.maxY - my { r.origin.y -= py - (bounds.maxY - my) }
            }
            lastCursor = c
        }
        r.origin.x = Self.clamp(r.minX, size: r.width, within: bounds.minX, bounds.maxX)
        r.origin.y = Self.clamp(r.minY, size: r.height, within: bounds.minY, bounds.maxY)
        origin = r.origin
        return r
    }

    private func rect(_ fitted: CGRect) -> CGRect {
        isZoomed ? CGRect(x: origin.x, y: origin.y, width: fitted.width * scale, height: fitted.height * scale) : fitted
    }

    /// Bigger than the view: no gap at either edge. Smaller: centred.
    private static func clamp(_ x: CGFloat, size: CGFloat, within lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        size >= hi - lo ? min(lo, max(hi - size, x)) : (lo + hi - size) / 2
    }
}
