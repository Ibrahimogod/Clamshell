import ClamshellWire
import Foundation

/// What the Mac should post. `InputReceiver` is pure; the host turns these into `CGEvent`s.
public enum InputAction: Equatable, Sendable {
    /// `code` is a macOS virtual key code. `flags` are the modifiers held *with* this event.
    case key(code: UInt16, down: Bool, flags: KeyModifiers, isRepeat: Bool)
    case media(MediaKey, down: Bool)
    /// Relative motion in points, with the buttons held (a drag when non-empty).
    case move(dx: Double, dy: Double, buttons: MouseButtons)
    /// Absolute position as a fraction (0…1) of the display.
    case moveTo(x: Double, y: Double, buttons: MouseButtons)
    case button(PointerButton, down: Bool, clickCount: Int, flags: KeyModifiers)
    /// Deltas in points, macOS convention (positive y = content moves down), after natural scrolling.
    case scroll(dx: Double, dy: Double, phase: ScrollPhase, momentum: MomentumPhase, flags: KeyModifiers)
    case gesture(GestureKind)
    /// 1.6: switch the Mac to its next keyboard input source (🌐 on the phone).
    case nextInputSource
}

public enum MomentumPhase: Equatable, Sendable { case none, begin, `continue`, end }

public struct InputConfig: Sendable {
    public var keyRepeatInitialNs: UInt64 = 500_000_000
    public var keyRepeatIntervalNs: UInt64 = 83_000_000
    public var doubleClickNs: UInt64 = 500_000_000
    /// The Mac's "natural scrolling" setting (`com.apple.swipescrolldirection`).
    public var naturalScroll = true
    public var watchdogNs: UInt64 = 2_000_000_000
    /// Momentum decay per millisecond (UIScrollView's normal rate is 0.998).
    public var momentumDecayPerMs = 0.997
    public var momentumStopSpeed = 20.0
    public init() {}

    /// From the Mac's `InitialKeyRepeat` / `KeyRepeat` defaults, which are in 15 ms ticks.
    public init(initialKeyRepeatTicks: Int?, keyRepeatTicks: Int?, doubleClickSeconds: Double?, naturalScroll: Bool?) {
        if let t = initialKeyRepeatTicks, t > 0 { keyRepeatInitialNs = UInt64(t) * 15_000_000 }
        if let t = keyRepeatTicks, t > 0 { keyRepeatIntervalNs = UInt64(t) * 15_000_000 }
        if let s = doubleClickSeconds, s > 0 { doubleClickNs = UInt64(s * 1e9) }
        if let n = naturalScroll { self.naturalScroll = n }
    }
}

/// Mac side of the input channel (ADR-0013): dedupe, modifier reconciliation, Mac-side key repeat, click
/// counting, scroll momentum, and the stuck-input watchdog. Call `receive` with each batch and `tick`
/// every ~8 ms.
public struct InputReceiver: Sendable {
    public let config: InputConfig
    private var dedupe = InputDeduper()
    private var newestSeq: UInt32?
    private var lastInputNs: UInt64 = 0
    private var keySeq: [UInt16: UInt32] = [:]
    public private(set) var modifiers: KeyModifiers = []
    public private(set) var heldKeys: Set<UInt16> = []          // HID usages (page 7, non-modifier)
    public private(set) var buttons: MouseButtons = []
    public private(set) var appliedPointerSeq: UInt32 = 0
    private var repeating: (usage: UInt16, code: UInt16, nextNs: UInt64)?
    private var lastDown: (button: PointerButton, atNs: UInt64, count: Int)?
    private var travelSinceDown = 0.0
    private var scrolling = false
    private var momentum: (vx: Double, vy: Double, lastNs: UInt64, began: Bool, flags: KeyModifiers)?

    public init(config: InputConfig = InputConfig()) { self.config = config }

    public var isIdle: Bool { repeating == nil && momentum == nil && !holdsAnything }
    private var holdsAnything: Bool { !heldKeys.isEmpty || !modifiers.subtracting(.capsLock).isEmpty || !buttons.isEmpty || scrolling }

    public mutating func receive(_ messages: [InnerMessage], nowNs: UInt64) -> [InputAction] {
        let input = messages.compactMap { m -> (UInt32, InnerMessage)? in m.inputSeq.map { ($0, m) } }
            .sorted { Int32(bitPattern: $0.0 &- $1.0) < 0 }
        var out: [InputAction] = []
        for (seq, m) in input where dedupe.accept(seq) {
            lastInputNs = nowNs
            let newest = newestSeq.map { Int32(bitPattern: seq &- $0) > 0 } ?? true
            if newest { newestSeq = seq }
            switch m.type {
            case .keyEvent:
                if let e = try? KeyEvent(m) { key(e, newest: newest, nowNs: nowNs, into: &out) }
            case .pointerMove:
                guard let e = try? PointerMove(m) else { continue }
                if newest { appliedPointerSeq = seq }
                if let a = e.absolute {
                    out.append(.moveTo(x: Double(a.x) / 65535, y: Double(a.y) / 65535, buttons: buttons))
                    travelSinceDown += 100
                } else if e.dx != 0 || e.dy != 0 {
                    let dx = Double(e.dx) / 16, dy = Double(e.dy) / 16
                    travelSinceDown += abs(dx) + abs(dy)
                    out.append(.move(dx: dx, dy: dy, buttons: buttons))
                }
            case .pointerButton:
                if let e = try? PointerButtonEvent(m) { button(e, newest: newest, nowNs: nowNs, into: &out) }
            case .scroll:
                if let e = try? ScrollEvent(m) { scroll(e, nowNs: nowNs, into: &out) }
            case .gesture:
                if let e = try? GestureEvent(m) { stopMomentum(into: &out); out.append(.gesture(e.kind)) }
            case .inputState:
                if newest, let s = try? InputState(m) { reconcile(s, into: &out) }
            default:
                continue
            }
        }
        return out
    }

    public mutating func tick(nowNs: UInt64) -> [InputAction] {
        var out: [InputAction] = []
        if holdsAnything, nowNs > lastInputNs + config.watchdogNs {
            releaseAll(into: &out)
            return out
        }
        if let r = repeating, nowNs >= r.nextNs {
            out.append(.key(code: r.code, down: true, flags: modifiers, isRepeat: true))
            // A late tick doesn't burst: one repeat, then the next interval from now.
            repeating?.nextNs = max(r.nextNs + config.keyRepeatIntervalNs, nowNs + config.keyRepeatIntervalNs / 2)
        }
        if var m = momentum, nowNs > m.lastNs {
            let dtMs = Double(nowNs - m.lastNs) / 1e6
            let decay = pow(config.momentumDecayPerMs, dtMs)
            m.vx *= decay; m.vy *= decay
            m.lastNs = nowNs
            if hypot(m.vx, m.vy) < config.momentumStopSpeed {
                out.append(.scroll(dx: 0, dy: 0, phase: .none, momentum: .end, flags: m.flags))
                momentum = nil
            } else {
                let s = scrollSign
                out.append(.scroll(dx: s * m.vx * dtMs / 1000, dy: s * m.vy * dtMs / 1000, phase: .none,
                                   momentum: m.began ? .continue : .begin, flags: m.flags))
                m.began = true
                momentum = m
            }
        }
        return out
    }

    /// Everything up (session end, watchdog).
    public mutating func releaseAll(into out: inout [InputAction]) {
        stopMomentum(into: &out)
        if scrolling { out.append(.scroll(dx: 0, dy: 0, phase: .cancelled, momentum: .none, flags: modifiers)); scrolling = false }
        for usage in heldKeys.sorted() { if let code = KeyMap.virtualKey(usage: usage) { out.append(.key(code: code, down: false, flags: modifiers, isRepeat: false)) } }
        heldKeys.removeAll()
        repeating = nil
        for b in [PointerButton.left, .right, .middle] where buttons.contains(b.mask) {
            out.append(.button(b, down: false, clickCount: lastDown?.count ?? 1, flags: modifiers))
        }
        buttons = []
        setModifiers(modifiers.intersection(.capsLock), into: &out)
    }

    public mutating func releaseAll() -> [InputAction] {
        var out: [InputAction] = []
        releaseAll(into: &out)
        return out
    }

    // MARK: -

    private var scrollSign: Double { config.naturalScroll ? 1 : -1 }

    private mutating func key(_ e: KeyEvent, newest: Bool, nowNs: UInt64, into out: inout [InputAction]) {
        if e.page == HIDUsage.consumerPage {
            if let k = MediaKey(rawValue: e.usage) { out.append(.media(k, down: e.down)) }
            return
        }
        if e.page == HIDUsage.clamshellPage {
            if e.usage == HIDUsage.nextInputSource, e.down { out.append(.nextInputSource) }
            return
        }
        guard e.page == HIDUsage.keyboardPage else { return }
        // A reordered packet: an older event for a key that already moved on must not undo it.
        if let last = keySeq[e.usage], Int32(bitPattern: e.seq &- last) <= 0 { return }
        keySeq[e.usage] = e.seq
        stopMomentum(into: &out)
        if KeyModifiers.forUsage(e.usage) != nil {
            if newest { setModifiers(e.modifiers, into: &out) }
            return
        }
        if newest { setModifiers(e.modifiers, into: &out) }
        guard let code = KeyMap.virtualKey(usage: e.usage) else { return }
        if e.down {
            heldKeys.insert(e.usage)
            out.append(.key(code: code, down: true, flags: modifiers, isRepeat: false))
            repeating = (e.usage, code, nowNs + config.keyRepeatInitialNs)
        } else {
            guard heldKeys.remove(e.usage) != nil else { return }
            out.append(.key(code: code, down: false, flags: modifiers, isRepeat: false))
            if repeating?.usage == e.usage { repeating = nil }
        }
    }

    /// Emits modifier key changes until the held set equals `target`.
    private mutating func setModifiers(_ target: KeyModifiers, into out: inout [InputAction]) {
        guard target != modifiers else { return }
        for (bit, code) in KeyMap.modifierKeys {
            let want = target.contains(bit), have = modifiers.contains(bit)
            guard want != have else { continue }
            if want { modifiers.insert(bit) } else { modifiers.remove(bit) }
            out.append(.key(code: code, down: want, flags: modifiers, isRepeat: false))
        }
    }

    private mutating func button(_ e: PointerButtonEvent, newest: Bool, nowNs: UInt64, into out: inout [InputAction]) {
        if newest { setModifiers(e.modifiers, into: &out) }
        stopMomentum(into: &out)
        if e.down {
            guard !buttons.contains(e.button.mask) else { return }
            var count = 1
            if let last = lastDown, last.button == e.button, nowNs - last.atNs <= config.doubleClickNs, travelSinceDown < 5 {
                count = min(last.count + 1, 3)
            }
            lastDown = (e.button, nowNs, count)
            travelSinceDown = 0
            buttons.insert(e.button.mask)
            out.append(.button(e.button, down: true, clickCount: count, flags: modifiers))
        } else {
            guard buttons.contains(e.button.mask) else { return }
            buttons.remove(e.button.mask)
            out.append(.button(e.button, down: false, clickCount: lastDown?.count ?? 1, flags: modifiers))
        }
    }

    private mutating func scroll(_ e: ScrollEvent, nowNs: UInt64, into out: inout [InputAction]) {
        let s = scrollSign, dx = Double(e.dx) / 16 * s, dy = Double(e.dy) / 16 * s
        switch e.phase {
        case .began:
            stopMomentum(into: &out)
            scrolling = true
            out.append(.scroll(dx: dx, dy: dy, phase: .began, momentum: .none, flags: e.modifiers))
        case .changed:
            if !scrolling {                                      // the "began" was lost
                stopMomentum(into: &out)
                scrolling = true
                out.append(.scroll(dx: 0, dy: 0, phase: .began, momentum: .none, flags: e.modifiers))
            }
            out.append(.scroll(dx: dx, dy: dy, phase: .changed, momentum: .none, flags: e.modifiers))
        case .ended, .cancelled:
            guard scrolling else { return }
            scrolling = false
            out.append(.scroll(dx: dx, dy: dy, phase: e.phase, momentum: .none, flags: e.modifiers))
            let vx = Double(e.velocityX), vy = Double(e.velocityY)
            if e.phase == .ended, hypot(vx, vy) > config.momentumStopSpeed * 2.5 {
                momentum = (vx, vy, nowNs, false, e.modifiers)
            }
        case .none:
            stopMomentum(into: &out)
            out.append(.scroll(dx: dx, dy: dy, phase: .none, momentum: .none, flags: e.modifiers))
        }
    }

    private mutating func stopMomentum(into out: inout [InputAction]) {
        guard let m = momentum else { return }
        momentum = nil
        if m.began { out.append(.scroll(dx: 0, dy: 0, phase: .none, momentum: .end, flags: m.flags)) }
    }

    private mutating func reconcile(_ s: InputState, into out: inout [InputAction]) {
        for usage in heldKeys.subtracting(s.keys).sorted() {
            heldKeys.remove(usage)
            if repeating?.usage == usage { repeating = nil }
            if let code = KeyMap.virtualKey(usage: usage) { out.append(.key(code: code, down: false, flags: modifiers, isRepeat: false)) }
        }
        setModifiers(s.modifiers, into: &out)
        for b in [PointerButton.left, .right, .middle] where buttons.contains(b.mask) && !s.buttons.contains(b.mask) {
            buttons.remove(b.mask)
            out.append(.button(b, down: false, clickCount: lastDown?.count ?? 1, flags: modifiers))
        }
    }
}

extension PointerButton {
    public var mask: MouseButtons {
        switch self {
        case .left: .left
        case .right: .right
        case .middle: .middle
        }
    }
}
