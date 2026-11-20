import ClamshellInput
import ClamshellTransport
import ClamshellWire
import CoreGraphics
import Foundation
import UIKit

/// Phone side of input (ADR-0013): the deck and trackpad call this; it numbers, adds redundancy and sends
/// in order through one task. A 10 ms timer sends the tail copies and the held-state heartbeat.
@MainActor
final class InputClient {
    private var sender = InputSender()
    private let out: AsyncStream<[InnerMessage]>.Continuation
    private let task: Task<Void, Never>
    private var timer: Timer?
    let cursor: CursorModel
    static let layoutChanged = Notification.Name("ClamshellKeyboardLayoutChanged")
    /// 1.6: the Mac's keyboard layout, for the deck's labels and 🌐 (nil from an older Mac).
    var keyboardLayout: KeyboardLayout? {
        didSet { NotificationCenter.default.post(name: Self.layoutChanged, object: self) }
    }

    init(connection: ClientSessionConnection, displaySize: CGSize) {
        let (stream, out) = AsyncStream.makeStream(of: [InnerMessage].self, bufferingPolicy: .unbounded)
        self.out = out
        cursor = CursorModel(displaySize: displaySize)
        task = Task.detached(priority: .userInitiated) {
            for await batch in stream { await connection.send(batch) }
        }
        let t = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        emit(sender.releaseAll(nowNs: PhoneClock.nowNs()))
        timer?.invalidate()
        out.finish()
    }

    var modifiers: KeyModifiers { sender.modifiers }

    func releaseAllHeld() { emit(sender.releaseAll(nowNs: PhoneClock.nowNs())) }

    private func emit(_ m: [InnerMessage]) { if !m.isEmpty { out.yield(m) } }
    private func tick() { emit(sender.tick(nowNs: PhoneClock.nowNs())) }

    func key(_ usage: UInt16, down: Bool, page: UInt16 = HIDUsage.keyboardPage) {
        emit(sender.key(usage: usage, down: down, page: page, nowNs: PhoneClock.nowNs()))
    }

    /// Mac points.
    func move(dx: Double, dy: Double) {
        let m = sender.move(dx: dx, dy: dy, nowNs: PhoneClock.nowNs())
        guard !m.isEmpty else { return }
        cursor.predictMove(dx: dx, dy: dy, seq: sender.lastSeq)
        emit(m)
    }

    /// Fractions of the display (direct touch).
    func moveTo(x: Double, y: Double) {
        emit(sender.moveTo(x: x, y: y, nowNs: PhoneClock.nowNs()))
        cursor.predictAbsolute(x: x, y: y, seq: sender.lastSeq)
    }

    func button(_ b: PointerButton, down: Bool) { emit(sender.button(b, down: down, nowNs: PhoneClock.nowNs())) }

    func scroll(dx: Double, dy: Double, phase: ScrollPhase, vx: Double = 0, vy: Double = 0) {
        emit(sender.scroll(dx: dx, dy: dy, phase: phase, vx: vx, vy: vy, nowNs: PhoneClock.nowNs()))
    }

    func gesture(_ g: GestureKind) { emit(sender.gesture(g, nowNs: PhoneClock.nowNs())) }

    /// A shortcut typed as a chord: modifiers, key, release.
    func chord(_ usage: UInt16, modifiers usages: [UInt16]) {
        for m in usages { key(m, down: true) }
        key(usage, down: true)
        key(usage, down: false)
        for m in usages.reversed() { key(m, down: false) }
    }
}

/// The locally drawn cursor (ADR-0009): moves on the phone's next frame from local deltas, and reconciles
/// with the Mac's reported position. Positions are in Mac points from the display's top-left.
@MainActor
final class CursorModel {
    var displaySize: CGSize
    private(set) var position: CGPoint
    private(set) var visible = true
    private(set) var shapeId: UInt64 = 0
    private(set) var shapes: [UInt64: Shape] = [:]
    private var history: [(seq: UInt32, at: CGPoint)] = []
    private var correction: (from: CGPoint, to: CGPoint, start: CFTimeInterval)?
    /// Whether the Mac sends positions (it draws no cursor into the video then).
    private(set) var active = false

    struct Shape { let image: CGImage; let hotspot: CGPoint; let size: CGSize }

    init(displaySize: CGSize) {
        self.displaySize = displaySize
        position = CGPoint(x: displaySize.width / 2, y: displaySize.height / 2)
    }

    var currentShape: Shape? { shapes[shapeId] }

    func predictMove(dx: Double, dy: Double, seq: UInt32) {
        correction = nil
        position = clamp(CGPoint(x: position.x + dx, y: position.y + dy))
        record(seq)
    }

    func predictAbsolute(x: Double, y: Double, seq: UInt32) {
        correction = nil
        position = clamp(CGPoint(x: x * displaySize.width, y: y * displaySize.height))
        record(seq)
    }

    private func record(_ seq: UInt32) {
        history.append((seq, position))
        if history.count > 256 { history.removeFirst(history.count - 256) }
    }

    func apply(_ p: CursorPosition) {
        active = true
        visible = p.visible
        shapeId = p.shapeId
        let mac = CGPoint(x: Double(p.x) / 16, y: Double(p.y) / 16)
        // Compare with what we predicted after the same move; any error (an edge, a snap, a warp) shifts
        // the cursor by that error, eased over 50 ms. Moves the Mac hasn't applied yet stay on top.
        let predicted: CGPoint
        if let i = history.lastIndex(where: { $0.seq == p.appliedSeq }) {
            predicted = history[i].at
            history.removeFirst(i)
        } else if history.isEmpty || p.appliedSeq > (history.last?.seq ?? 0) {
            predicted = position
            history.removeAll()
        } else {
            return                                     // an old report from before what we have
        }
        let ex = mac.x - predicted.x, ey = mac.y - predicted.y
        guard hypot(ex, ey) > 2 else { return }
        noteSnap(hypot(ex, ey))
        let target = clamp(CGPoint(x: position.x + ex, y: position.y + ey))
        for i in history.indices { history[i].at.x += ex; history[i].at.y += ey }
        correction = (position, target, CACurrentMediaTime())
        position = target
    }

    private var snaps = (count: 0, biggest: 0.0, since: CACurrentMediaTime())
    /// The phone's console: how often the Mac disagreed with the prediction (the pointer jumps), per 5 s.
    private func noteSnap(_ e: Double) {
        snaps.count += 1
        snaps.biggest = max(snaps.biggest, e)
        let now = CACurrentMediaTime()
        guard now - snaps.since >= 5 else { return }
        print(String(format: "# pointer: %d corrections in %.0f s, biggest %.0f pt", snaps.count, now - snaps.since, snaps.biggest))
        snaps = (0, 0, now)
    }

    /// Where to draw this frame (applies the easing).
    func drawPosition(now: CFTimeInterval) -> CGPoint {
        guard let c = correction else { return position }
        let t = min(1, (now - c.start) / 0.05)
        if t >= 1 { correction = nil; return position }
        return CGPoint(x: c.from.x + (c.to.x - c.from.x) * t, y: c.from.y + (c.to.y - c.from.y) * t)
    }

    func add(_ s: CursorShape) {
        guard let provider = CGDataProvider(data: Data(s.png) as CFData),
              let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        shapes[s.shapeId] = Shape(image: image, hotspot: CGPoint(x: Double(s.hotX) / 16, y: Double(s.hotY) / 16),
                                  size: CGSize(width: Double(s.width) / 16, height: Double(s.height) / 16))
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), displaySize.width - 1), y: min(max(p.y, 0), displaySize.height - 1))
    }
}
