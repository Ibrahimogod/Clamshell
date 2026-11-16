import ClamshellBench
import ClamshellStream
import ClamshellWire
import CoreVideo
import Metal
import QuartzCore
import SwiftUI
import UIKit

struct VideoSurface: UIViewRepresentable {
    let client: ClientController
    /// Flat, book and cover: a touch on the picture clicks there; edge swipes change Spaces.
    var directTouch = false
    /// Centre the picture in spare space (not in the laptop posture, where it sits against the top edge).
    var centered = false
    func makeUIView(context: Context) -> VideoLayerView { VideoLayerView(client: client) }
    func updateUIView(_ view: VideoLayerView, context: Context) {
        view.directTouch = directTouch
        view.centered = centered
    }
    static func dismantleUIView(_ view: VideoLayerView, coordinator: ()) { view.stop() }
}

/// CAMetalLayer showing the newest decoded picture at 1:1 device pixels, top-centred (the Duo's top
/// half). A 120 Hz display link takes the latest picture each refresh; nothing is queued, and if no new
/// picture arrived the layer simply keeps the previous one.
@MainActor
final class VideoLayerView: UIView {
    /// A sublayer, not the view's backing layer: SwiftUI owns the view's frame, and the backing layer
    /// would be stretched to it. This one is sized and placed 1:1 by `tick`.
    private let metal = CAMetalLayer()
    private let client: ClientController
    private let renderer: Renderer?
    private var link: CADisplayLink?
    private var lastFrameId: UInt32 = 0
    /// The Mac's cursor, drawn here (ADR-0009) so it moves on the phone's next frame.
    private let cursorLayer = CALayer()
    var directTouch = false {
        didSet { isMultipleTouchEnabled = directTouch; edges.forEach { $0.isEnabled = directTouch } }
    }
    var centered = false
    private var edges: [UIScreenEdgePanGestureRecognizer] = []
    private var touch = DirectTouch()

    init(client: ClientController) {
        self.client = client
        renderer = Renderer()
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        layer.addSublayer(metal)
        cursorLayer.isHidden = true
        cursorLayer.magnificationFilter = .linear
        layer.addSublayer(cursorLayer)
        if let renderer {
            metal.device = renderer.device
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = true
            metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metal.magnificationFilter = .nearest
            metal.minificationFilter = .nearest
            metal.maximumDrawableCount = 3
            metal.presentsWithTransaction = false
        }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        for edge in [UIRectEdge.left, .right] {
            let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwipe(_:)))
            g.edges = edge
            g.isEnabled = false
            addGestureRecognizer(g)
            edges.append(g)
        }
        isAccessibilityElement = true
        accessibilityLabel = "The Mac's screen"
        accessibilityTraits = .allowsDirectInteraction
    }

    /// A swipe in from the left edge shows the Space on the left, from the right the one on the right,
    /// as a four-finger swipe does on a trackpad.
    @objc private func edgeSwipe(_ g: UIScreenEdgePanGestureRecognizer) {
        guard g.state == .ended, let input = client.input else { return }
        apply(touch.cancel())
        input.gesture(g.edges == .left ? .spaceLeft : .spaceRight)
    }

    required init?(coder: NSCoder) { nil }

    func stop() { link?.invalidate(); link = nil }

    @objc private func tick(_ link: CADisplayLink) {
        drawCursor()
        if directTouch, touch.isPending { feed(lastPoints) }      // a finger held still: the 0.5 s right click
        guard let renderer,
              let pic = client.pipeline?.latest.take(), pic.frameId != lastFrameId else { return }
        lastFrameId = pic.frameId
        let presentNs = PhoneClock.ns(fromMediaTime: link.targetTimestamp)
        if let value = BarcodeReader.read(pic.pixelBuffer) { client.recordBarcode(macMicros: value.timeMicros, presentNs: presentNs) }
        if client.flashTestRunning, let level = StreamFlashReader.level(pic.pixelBuffer) {
            client.recordStreamFlash(level: level, presentNs: presentNs)
        }

        let w = CVPixelBufferGetWidth(pic.pixelBuffer), h = CVPixelBufferGetHeight(pic.pixelBuffer)
        // The Mac reports the cursor in picture points (pixels / 2); a mirrored Mac screen keeps its own
        // aspect, so take the size from the picture, not from the posture's mode.
        let picturePoints = CGSize(width: Double(w) / 2, height: Double(h) / 2)
        if let cursor = client.input?.cursor, cursor.displaySize != picturePoints { cursor.displaySize = picturePoints }
        let scale = window?.windowScene?.screen.nativeScale ?? traitCollection.displayScale
        // 1:1: the layer is exactly picture-pixels / native scale points, at the top, centred horizontally.
        // On a phone narrower than the picture (not the Duo's top half), fit it to the width instead.
        var size = CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        // Fit inside the view (the flat and book modes can be bigger than the area for them).
        let fit = min(bounds.width > 0 ? bounds.width / size.width : 1, bounds.height > 0 ? bounds.height / size.height : 1, 1)
        if fit < 0.999 {
            size = CGSize(width: size.width * fit, height: size.height * fit)
            metal.minificationFilter = .linear
        } else {
            metal.minificationFilter = .nearest
        }
        let origin = CGPoint(x: max((bounds.width - size.width) / 2, 0), y: centered ? max((bounds.height - size.height) / 2, 0) : 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.contentsScale = scale
        metal.frame = CGRect(origin: origin, size: size)
        metal.drawableSize = CGSize(width: w, height: h)
        CATransaction.commit()
        if renderer.draw(pic.pixelBuffer, on: metal) { client.presentedFrames += 1 }
    }

    private var cursorImageId: UInt64 = .max

    // MARK: direct touch

    /// A point in this view → fractions of the Mac display.
    private func fraction(_ p: CGPoint) -> (x: Double, y: Double)? {
        let f = metal.frame
        guard f.width > 0, f.height > 0 else { return nil }
        return (Double(min(max((p.x - f.minX) / f.width, 0), 1)), Double(min(max((p.y - f.minY) / f.height, 0), 1)))
    }

    private func current(_ event: UIEvent?) -> [CGPoint] {
        (event?.allTouches ?? []).filter { $0.view === self && $0.phase != .ended && $0.phase != .cancelled }.map { $0.location(in: self) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard directTouch else { return super.touchesBegan(touches, with: event) }
        feed(current(event))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard directTouch else { return super.touchesMoved(touches, with: event) }
        feed(current(event))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard directTouch else { return super.touchesEnded(touches, with: event) }
        feed(current(event))
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard directTouch else { return super.touchesCancelled(touches, with: event) }
        apply(touch.cancel())
        lastPoints = []
        apply(touch.update([], now: CACurrentMediaTime()))
    }

    private var lastPoints: [CGPoint] = []
    private func feed(_ points: [CGPoint]) {
        lastPoints = points
        apply(touch.update(points, now: CACurrentMediaTime()))
    }

    private func apply(_ out: [DirectTouch.Output]) {
        guard let input = client.input else { return }
        for o in out {
            switch o {
            case .moveTo(let p): if let f = fraction(p) { input.moveTo(x: f.x, y: f.y) }
            case .button(let b, let d): input.button(b, down: d)
            case .scroll(let dx, let dy, let phase):
                let k = metal.frame.width > 0 ? Double(cursorDisplayWidth / metal.frame.width) : 1
                input.scroll(dx: dx * k, dy: dy * k, phase: phase)
            }
        }
    }

    private var cursorDisplayWidth: CGFloat { client.input?.cursor.displaySize.width ?? metal.frame.width }

    private func drawCursor() {
        guard let cursor = client.input?.cursor, cursor.active, cursor.visible, !metal.frame.isEmpty,
              let shape = cursor.currentShape else {
            if !cursorLayer.isHidden { cursorLayer.isHidden = true }
            return
        }
        // Mac points → this view: the video layer shows the whole Mac display.
        let k = metal.frame.width / cursor.displaySize.width
        let p = cursor.drawPosition(now: CACurrentMediaTime())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if cursorImageId != cursor.shapeId {
            cursorImageId = cursor.shapeId
            cursorLayer.contents = shape.image
        }
        cursorLayer.isHidden = false
        cursorLayer.frame = CGRect(x: metal.frame.minX + (p.x - shape.hotspot.x) * k, y: metal.frame.minY + (p.y - shape.hotspot.y) * k,
                                   width: shape.size.width * k, height: shape.size.height * k)
        CATransaction.commit()
    }

}

/// Direct touch on the picture: tap = click, touch-and-move = drag, hold 0.5 s = right click,
/// two fingers = scroll. Pure, so the rules are easy to follow.
struct DirectTouch {
    enum Output { case moveTo(CGPoint), button(PointerButton, Bool), scroll(Double, Double, ClamshellWire.ScrollPhase) }
    private enum State { case idle, pending(start: CGPoint, at: CFTimeInterval), dragging, held, scrolling(last: CGPoint), done }
    private var state = State.idle
    static let slop: CGFloat = 8
    static let hold: CFTimeInterval = 0.5

    /// Ends whatever is in progress (an edge swipe took over, or the touches were cancelled).
    mutating func cancel() -> [Output] {
        defer { state = .done }
        switch state {
        case .dragging: return [.button(.left, false)]
        case .scrolling: return [.scroll(0, 0, .cancelled)]
        default: return []
        }
    }

    var isPending: Bool { if case .pending = state { true } else { false } }

    mutating func update(_ points: [CGPoint], now: CFTimeInterval) -> [Output] {
        let centroid = points.isEmpty ? nil : CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                                                      y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        switch state {
        case .idle:
            guard let c = centroid else { return [] }
            if points.count >= 2 { state = .scrolling(last: c); return [.scroll(0, 0, .began)] }
            state = .pending(start: c, at: now)
            return [.moveTo(c)]
        case .pending(let start, let at):
            guard let c = centroid else { state = .idle; return [.button(.left, true), .button(.left, false)] }
            if points.count >= 2 { state = .scrolling(last: c); return [.scroll(0, 0, .began)] }
            if hypot(c.x - start.x, c.y - start.y) > Self.slop {
                state = .dragging
                return [.button(.left, true), .moveTo(c)]
            }
            if now - at >= Self.hold { state = .held; return [.button(.right, true), .button(.right, false)] }
            return []
        case .dragging:
            guard let c = centroid else { state = .idle; return [.button(.left, false)] }
            return [.moveTo(c)]
        case .held, .done:
            if points.isEmpty { state = .idle }
            return []
        case .scrolling(let last):
            guard let c = centroid, points.count >= 2 else {
                state = points.isEmpty ? .idle : .done
                return [.scroll(0, 0, .ended)]
            }
            state = .scrolling(last: c)
            return [.scroll(Double(c.x - last.x), Double(c.y - last.y), .changed)]
        }
    }
}

/// Y'CbCr bi-planar pixel buffer → BGRA drawable via CVMetalTextureCache (zero copy).
@MainActor
final class Renderer {
    /// Compiled at launch (a few ms) so the build needs no Metal toolchain download.
    static let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

// One triangle covering the drawable.
vertex VOut fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

struct Params { float fullRange; };

// BT.709 Y'CbCr → R'G'B'. Luma is read texel-exact (drawable == picture size, 1:1, no filtering);
// chroma is upsampled bilinearly from its own plane (4:2:0) or read 1:1 (4:4:4).
fragment float4 ycbcr709(VOut in [[stage_in]],
                         texture2d<float, access::sample> lumaTex [[texture(0)]],
                         texture2d<float, access::sample> chromaTex [[texture(1)]],
                         constant Params &params [[buffer(0)]]) {
    constexpr sampler chromaSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    uint2 px = uint2(in.pos.xy);
    float y = lumaTex.read(px).r;
    float2 c = chromaTex.sample(chromaSampler, in.uv).rg;
    if (params.fullRange < 0.5) {
        y = (y - 16.0 / 255.0) * (255.0 / 219.0);
        c = (c - 128.0 / 255.0) * (255.0 / 224.0);
    } else {
        c = c - 0.5;
    }
    float r = y + 1.5748 * c.y;
    float g = y - 0.18732 * c.x - 0.46812 * c.y;
    float b = y + 1.8556 * c.x;
    return float4(saturate(float3(r, g, b)), 1.0);
}
"""#

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Renderer.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "fullscreen"), let fragment = library.makeFunction(name: "ycbcr709") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.device = device
        self.queue = queue
        pipeline = state
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    func draw(_ buffer: CVPixelBuffer, on layer: CAMetalLayer) -> Bool {
        guard CVPixelBufferGetPlaneCount(buffer) == 2, let cache,
              let luma = texture(buffer, plane: 0, format: .r8Unorm, cache: cache),
              let chroma = texture(buffer, plane: 1, format: .rg8Unorm, cache: cache),
              let lumaTex = CVMetalTextureGetTexture(luma), let chromaTex = CVMetalTextureGetTexture(chroma),
              let drawable = layer.nextDrawable(), let cmd = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return false }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var fullRange: Float = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
                                kCVPixelFormatType_422YpCbCr8BiPlanarFullRange].contains(format) ? 1 : 0
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(lumaTex, index: 0)
        enc.setFragmentTexture(chromaTex, index: 1)
        enc.setFragmentBytes(&fullRange, length: MemoryLayout<Float>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        let keep = TextureRefs(luma: luma, chroma: chroma)         // CVMetalTextures must outlive the GPU work
        cmd.addCompletedHandler { _ in _ = keep }
        cmd.present(drawable)
        cmd.commit()
        return true
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> CVMetalTexture? {
        var tex: CVMetalTexture?
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane), h = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, w, h, plane, &tex)
        return status == kCVReturnSuccess ? tex : nil
    }
}

private struct TextureRefs: @unchecked Sendable {
    let luma: CVMetalTexture
    let chroma: CVMetalTexture
}

/// Harness A reader: samples the centre of each 8 px cell of the Mac's barcode patch in the luma plane.
enum BarcodeReader {
    static let cellPixels = 8

    static func read(_ buffer: CVPixelBuffer) -> BarcodePatch.Value? {
        let n = BarcodePatch.cells
        guard CVPixelBufferGetWidthOfPlane(buffer, 0) >= n * cellPixels, CVPixelBufferGetHeightOfPlane(buffer, 0) >= n * cellPixels,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var cells: [Bool] = []
        cells.reserveCapacity(BarcodePatch.bitCount)
        for i in 0..<BarcodePatch.bitCount {
            let x = (i % n) * cellPixels + cellPixels / 2, y = (i / n) * cellPixels + cellPixels / 2
            cells.append(bytes[y * stride + x] > 128)
        }
        return BarcodePatch.decode(cells)
    }
}
