import ClamshellWire
import Foundation

/// Pointer acceleration (ADR-0013): `out = in · gain · max(1, v/v0)^γ`, linear in a low-speed
/// precision zone below `v0`.
public struct PointerAcceleration: Sendable, Equatable {
    public var gain: Double
    public var exponent: Double
    public var precisionSpeed: Double
    public var maxScale: Double

    public init(gain: Double, exponent: Double, precisionSpeed: Double = 60, maxScale: Double = 6) {
        self.gain = gain; self.exponent = exponent; self.precisionSpeed = precisionSpeed; self.maxScale = maxScale
    }

    public static let macLike = PointerAcceleration(gain: 1.0, exponent: 0.55)
    public static let linear = PointerAcceleration(gain: 1.6, exponent: 0)
    public static let fast = PointerAcceleration(gain: 1.4, exponent: 0.8)

    public func scale(speed v: Double) -> Double {
        min(maxScale, gain * pow(max(1, v / precisionSpeed), exponent))
    }

    /// Deltas over `dt` seconds.
    public func apply(dx: Double, dy: Double, dt: Double) -> (Double, Double) {
        let v = hypot(dx, dy) / max(dt, 1.0 / 240)
        let s = scale(speed: v)
        return (dx * s, dy * s)
    }
}

public enum TrackpadOutput: Equatable, Sendable {
    case move(dx: Double, dy: Double)
    case button(PointerButton, down: Bool)
    /// Finger convention (content follows the fingers); velocity in points per second on `ended`.
    case scroll(dx: Double, dy: Double, phase: ScrollPhase, vx: Double, vy: Double)
    case gesture(GestureKind)
    case haptic(Haptic)
    /// With `Settings.continuousZoom`: a pinch as it happens, for zooming the phone's own view. `factor` is the
    /// change since the last one, (x, y) the fingers' centre and (dx, dy) how far it moved, in pad points.
    case zoom(factor: Double, x: Double, y: Double, dx: Double, dy: Double)

    public enum Haptic: Equatable, Sendable { case click, dragStart, step }
}

/// Turns raw multi-touch on the phone's trackpad area into MacBook trackpad outcomes (ADR-0013 table).
/// Pure: feed it the full set of touches after every touch event, and `tick` every frame.
///
/// - 1 finger: move (accelerated); tap = click; press and hold 0.4 s = button down for a drag;
/// - 2 fingers: scroll with phases and release velocity; tap = right click; pinch = zoom in/out steps;
/// - 3 fingers: swipe left/right = switch Space, up = Mission Control, down = App Exposé; tap = look up;
/// - 4 fingers: left/right = app switcher (a step per 80 pt), up = Mission Control, down = show desktop.
public struct TrackpadInterpreter: Sendable {
    public struct Settings: Sendable, Equatable {
        public var acceleration: PointerAcceleration = .macLike
        public var tapToClick = true
        public var holdToDrag = true
        public var holdSeconds = 0.4
        public var slop = 4.0
        public var tapSeconds = 0.25
        public var swipeDistance = 50.0
        public var switcherStep = 80.0
        /// Pinch zooms the phone's view (`.zoom`, continuous, picked up sooner) instead of sending ⌘= / ⌘- steps.
        public var continuousZoom = false
        public init() {}
    }

    private enum Mode: Equatable { case undecided, pointing, dragging, scrolling, pinching, swiped, switcher, done }

    public var settings: Settings
    private var touches: [Int: (x: Double, y: Double)] = [:]
    private var start: [Int: (x: Double, y: Double)] = [:]
    private var startTime = 0.0
    private var lastTime = 0.0
    private var maxFingers = 0
    private var mode: Mode = .undecided
    private var travel = 0.0
    private var lastCentroid: (x: Double, y: Double)?
    private var startCentroid: (x: Double, y: Double)?
    private var startSpread = 0.0
    private var zoomRef = 0.0
    private var switcherOffset = 0.0
    private var samples: [(t: Double, x: Double, y: Double)] = []

    public init(settings: Settings = Settings()) { self.settings = settings }

    public var active: Bool { !touches.isEmpty }

    /// `points`: every touch currently on the trackpad, by a stable id, in phone points.
    public mutating func update(_ points: [Int: (x: Double, y: Double)], at t: Double) -> [TrackpadOutput] {
        var out: [TrackpadOutput] = []
        if touches.isEmpty && !points.isEmpty { begin(at: t) }
        let previous = touches
        touches = points
        for (id, p) in points where start[id] == nil { start[id] = p }
        maxFingers = max(maxFingers, points.count)
        let dt = max(t - lastTime, 1e-4)
        lastTime = t

        if points.isEmpty {
            end(at: t, into: &out)
            return out
        }
        // Fingers added or removed: re-base the centroid so the change itself isn't a movement.
        let common = Set(points.keys).intersection(previous.keys)
        if Set(points.keys) != Set(previous.keys) {
            if mode == .scrolling && points.count < 2 { endScroll(at: t, into: &out); mode = .done }
            if mode == .switcher && points.count < 3 { out.append(.gesture(.appSwitcherEnd)); mode = .done }
            lastCentroid = centroid(points)
            if mode == .undecided { startCentroid = lastCentroid; startSpread = spread(points); zoomRef = startSpread }
            return out
        }
        guard !common.isEmpty, let c = centroid(points), let last = lastCentroid else { return out }
        let dx = c.x - last.x, dy = c.y - last.y
        lastCentroid = c
        travel += hypot(dx, dy)
        samples.append((t, c.x, c.y))
        samples.removeAll { t - $0.t > 0.08 }

        switch mode {
        case .undecided:
            decide(points: points, c: c, at: t, into: &out)
        case .pointing, .dragging:
            if points.count == 1 {
                let (ax, ay) = settings.acceleration.apply(dx: dx, dy: dy, dt: dt)
                out.append(.move(dx: ax, dy: ay))
            }
        case .scrolling:
            out.append(.scroll(dx: dx, dy: dy, phase: .changed, vx: 0, vy: 0))
        case .pinching:
            pinch(points, c: c, moved: (dx, dy), into: &out)
        case .switcher:
            switcherOffset += dx
            while switcherOffset >= settings.switcherStep { switcherOffset -= settings.switcherStep; out.append(.gesture(.appSwitcherNext)); out.append(.haptic(.step)) }
            while switcherOffset <= -settings.switcherStep { switcherOffset += settings.switcherStep; out.append(.gesture(.appSwitcherPrevious)); out.append(.haptic(.step)) }
        case .swiped, .done:
            break
        }
        return out
    }

    /// Call every frame: the hold-to-drag timer.
    public mutating func tick(at t: Double) -> [TrackpadOutput] {
        guard settings.holdToDrag, mode == .undecided, touches.count == 1, maxFingers == 1,
              travel < settings.slop, t - startTime >= settings.holdSeconds else { return [] }
        mode = .dragging
        return [.button(.left, down: true), .haptic(.dragStart)]
    }

    // MARK: -

    private mutating func begin(at t: Double) {
        startTime = t
        lastTime = t
        maxFingers = 0
        mode = .undecided
        travel = 0
        start = [:]
        lastCentroid = nil
        startCentroid = nil
        switcherOffset = 0
        samples = []
    }

    private mutating func decide(points: [Int: (x: Double, y: Double)], c: (x: Double, y: Double), at t: Double, into out: inout [TrackpadOutput]) {
        guard let s = startCentroid ?? lastCentroid else { return }
        let tx = c.x - s.x, ty = c.y - s.y
        switch points.count {
        case 1 where maxFingers == 1:
            guard travel >= settings.slop else { return }
            mode = .pointing
            let (ax, ay) = settings.acceleration.apply(dx: tx, dy: ty, dt: max(t - startTime, 1.0 / 120))
            out.append(.move(dx: ax, dy: ay))
        case 2:
            let sp = spread(points)
            let stretch = abs(sp - zoomRef)
            let threshold = settings.continuousZoom ? max(12, zoomRef * 0.08) : max(40, zoomRef * 0.25)
            if zoomRef > 0, stretch > threshold, hypot(tx, ty) < stretch {
                mode = .pinching
                pinch(points, c: c, moved: (0, 0), into: &out)
            } else if hypot(tx, ty) >= settings.slop, !(settings.continuousZoom && stretch >= hypot(tx, ty)) {
                mode = .scrolling
                out.append(.scroll(dx: tx, dy: ty, phase: .began, vx: 0, vy: 0))
            }
        case 3:
            if abs(tx) >= settings.swipeDistance && abs(tx) > abs(ty) {
                mode = .swiped
                out.append(.gesture(tx > 0 ? .spaceLeft : .spaceRight))
            } else if abs(ty) >= settings.swipeDistance {
                mode = .swiped
                out.append(.gesture(ty < 0 ? .missionControl : .appExpose))
            }
        case 4...:
            if abs(tx) >= 40 && abs(tx) > abs(ty) {
                mode = .switcher
                switcherOffset = 0
                out.append(.gesture(.appSwitcherBegin))
                out.append(.haptic(.step))
            } else if abs(ty) >= settings.swipeDistance {
                mode = .swiped
                out.append(.gesture(ty < 0 ? .missionControl : .showDesktop))
            }
        default:
            break
        }
    }

    private mutating func pinch(_ points: [Int: (x: Double, y: Double)], c: (x: Double, y: Double), moved: (Double, Double),
                                into out: inout [TrackpadOutput]) {
        let sp = spread(points)
        guard zoomRef > 0 else { zoomRef = sp; return }
        if settings.continuousZoom {
            out.append(.zoom(factor: sp / zoomRef, x: c.x, y: c.y, dx: moved.0, dy: moved.1))
            zoomRef = sp
            return
        }
        if sp > zoomRef * 1.25 { zoomRef = sp; out.append(.gesture(.zoomIn)) }
        else if sp < zoomRef / 1.25 { zoomRef = sp; out.append(.gesture(.zoomOut)) }
    }

    private mutating func end(at t: Double, into out: inout [TrackpadOutput]) {
        let quick = t - startTime <= settings.tapSeconds && travel < settings.slop * 2
        switch mode {
        case .undecided where quick && settings.tapToClick:
            switch maxFingers {
            case 1: out += [.button(.left, down: true), .button(.left, down: false), .haptic(.click)]
            case 2: out += [.button(.right, down: true), .button(.right, down: false), .haptic(.click)]
            case 3: out.append(.gesture(.lookUp))
            default: break
            }
        case .dragging:
            out.append(.button(.left, down: false))
        case .scrolling:
            endScroll(at: t, into: &out)
        case .switcher:
            out.append(.gesture(.appSwitcherEnd))
        default:
            break
        }
        mode = .undecided
        start = [:]
        maxFingers = 0
        lastCentroid = nil
    }

    private mutating func endScroll(at t: Double, into out: inout [TrackpadOutput]) {
        var vx = 0.0, vy = 0.0
        // Velocity over the last 80 ms; none if the fingers had already stopped before lifting.
        if let first = samples.first, let last = samples.last, last.t - first.t > 0.01, t - last.t < 0.05 {
            vx = (last.x - first.x) / (last.t - first.t)
            vy = (last.y - first.y) / (last.t - first.t)
        }
        out.append(.scroll(dx: 0, dy: 0, phase: .ended, vx: vx, vy: vy))
    }

    private func centroid(_ p: [Int: (x: Double, y: Double)]) -> (x: Double, y: Double)? {
        guard !p.isEmpty else { return nil }
        let n = Double(p.count)
        return (p.values.reduce(0) { $0 + $1.x } / n, p.values.reduce(0) { $0 + $1.y } / n)
    }

    private func spread(_ p: [Int: (x: Double, y: Double)]) -> Double {
        guard let c = centroid(p), p.count >= 2 else { return 0 }
        return p.values.reduce(0) { $0 + hypot($1.x - c.x, $1.y - c.y) } / Double(p.count) * 2
    }
}
