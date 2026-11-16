import ClamshellWire

/// Phone side of the input channel: numbers messages, tracks what is held, and adds redundancy.
///
/// Each call returns the messages for one packet: the new message plus copies of the previous two (flag
/// `redundant`), so one lost packet loses nothing. `tick` resends the tail once 30 ms after the last
/// event, and sends an `InputState` every 250 ms while anything is held (and once after release).
public struct InputSender: Sendable {
    public private(set) var modifiers: KeyModifiers = []
    public private(set) var keys: [UInt16] = []
    public private(set) var buttons: MouseButtons = []
    private var seq: UInt32 = 0
    private var recent: [InnerMessage] = []
    private var lastSendNs: UInt64 = 0
    private var tailSent = true
    private var lastStateNs: UInt64 = 0
    private var stateAfterRelease = false
    public static let redundancy = 2

    public init() {}

    public var lastSeq: UInt32 { seq }

    private mutating func next() -> UInt32 {
        seq &+= 1
        return seq
    }

    private mutating func packet(_ m: InnerMessage, nowNs: UInt64) -> [InnerMessage] {
        var copies = recent.suffix(Self.redundancy).map { r -> InnerMessage in
            var c = r
            c.flags.insert(.redundant)
            return c
        }
        copies.append(m)
        recent.append(m)
        if recent.count > Self.redundancy { recent.removeFirst(recent.count - Self.redundancy) }
        lastSendNs = nowNs
        tailSent = false
        return copies
    }

    public mutating func key(usage: UInt16, down: Bool, page: UInt16 = HIDUsage.keyboardPage, nowNs: UInt64) -> [InnerMessage] {
        if page == HIDUsage.keyboardPage {
            if let bit = KeyModifiers.forUsage(usage) {
                if bit == .capsLock {
                    if down { modifiers.formSymmetricDifference(.capsLock) }    // a toggle: the "down" flips it
                } else if down {
                    modifiers.insert(bit)
                } else {
                    modifiers.remove(bit)
                }
            } else if down {
                if !keys.contains(usage) { keys.append(usage) }
            } else {
                keys.removeAll { $0 == usage }
            }
            if !held { stateAfterRelease = true }
        }
        return packet(KeyEvent(seq: next(), page: page, usage: usage, down: down, modifiers: modifiers).message, nowNs: nowNs)
    }

    /// `dx`/`dy` in Mac points.
    public mutating func move(dx: Double, dy: Double, nowNs: UInt64) -> [InnerMessage] {
        let x = Int32(clamping: Int((dx * 16).rounded())), y = Int32(clamping: Int((dy * 16).rounded()))
        guard x != 0 || y != 0 else { return [] }
        return packet(PointerMove(seq: next(), dx: x, dy: y).message, nowNs: nowNs)
    }

    /// Direct touch: `x`, `y` as fractions of the display.
    public mutating func moveTo(x: Double, y: Double, nowNs: UInt64) -> [InnerMessage] {
        let f = { (v: Double) in UInt16(clamping: Int((min(max(v, 0), 1) * 65535).rounded())) }
        return packet(PointerMove(seq: next(), dx: 0, dy: 0, absolute: (f(x), f(y))).message, nowNs: nowNs)
    }

    public mutating func button(_ b: PointerButton, down: Bool, nowNs: UInt64) -> [InnerMessage] {
        if down { buttons.insert(b.mask) } else { buttons.remove(b.mask) }
        if !held { stateAfterRelease = true }
        return packet(PointerButtonEvent(seq: next(), button: b, down: down, modifiers: modifiers).message, nowNs: nowNs)
    }

    public mutating func scroll(dx: Double, dy: Double, phase: ScrollPhase, vx: Double = 0, vy: Double = 0, nowNs: UInt64) -> [InnerMessage] {
        let q = { (v: Double) in Int32(clamping: Int((v * 16).rounded())) }
        let c = { (v: Double) in Int32(clamping: Int(v.rounded())) }
        return packet(ScrollEvent(seq: next(), dx: q(dx), dy: q(dy), phase: phase, velocityX: c(vx), velocityY: c(vy), modifiers: modifiers).message,
                      nowNs: nowNs)
    }

    public mutating func gesture(_ kind: GestureKind, nowNs: UInt64) -> [InnerMessage] {
        packet(GestureEvent(seq: next(), kind: kind).message, nowNs: nowNs)
    }

    public var held: Bool { !keys.isEmpty || !modifiers.subtracting(.capsLock).isEmpty || !buttons.isEmpty }

    /// Call every ~10 ms.
    public mutating func tick(nowNs: UInt64) -> [InnerMessage] {
        if held || stateAfterRelease, nowNs >= lastStateNs + 250_000_000 {
            lastStateNs = nowNs
            stateAfterRelease = false
            return packet(InputState(seq: next(), modifiers: modifiers, keys: keys, buttons: buttons).message, nowNs: nowNs)
        }
        if !tailSent, nowNs >= lastSendNs + 30_000_000 {
            tailSent = true
            return recent.map { var c = $0; c.flags.insert(.redundant); return c }
        }
        return []
    }

    /// Lets go of everything (the deck disappears, the app goes to the background).
    public mutating func releaseAll(nowNs: UInt64) -> [InnerMessage] {
        var out: [InnerMessage] = []
        for k in keys { out += key(usage: k, down: false, nowNs: nowNs).suffix(1) }
        for (bit, _) in KeyMap.modifierKeys where bit != .capsLock && modifiers.contains(bit) {
            if let usage = (0xE0...0xE7).first(where: { KeyModifiers.forUsage(UInt16($0)) == bit }) {
                out += key(usage: UInt16(usage), down: false, nowNs: nowNs).suffix(1)
            } else if bit == .function {
                out += key(usage: HIDUsage.function, down: false, nowNs: nowNs).suffix(1)
            }
        }
        for b in [PointerButton.left, .right, .middle] where buttons.contains(b.mask) { out += button(b, down: false, nowNs: nowNs).suffix(1) }
        lastStateNs = 0
        stateAfterRelease = true
        out += tick(nowNs: nowNs)
        return out
    }
}

/// Sticky modifiers (ADR-0013): one tap latches a modifier for the next key, a double tap locks it, a tap
/// on a locked one releases it. Returns what to send.
public struct StickyModifiers: Sendable {
    public enum State: Equatable, Sendable { case off, latched, locked }
    public private(set) var states: [UInt16: State] = [:]
    private var lastTap: (usage: UInt16, atNs: UInt64)?
    public var doubleTapNs: UInt64 = 350_000_000

    public init() {}

    public func state(_ usage: UInt16) -> State { states[usage] ?? .off }

    /// A tap on a modifier key. `.down`/`.up` tell the caller to send the modifier's down or up.
    public enum Effect: Equatable, Sendable { case down, up, none }

    public mutating func tap(_ usage: UInt16, nowNs: UInt64) -> Effect {
        defer { lastTap = (usage, nowNs) }
        switch state(usage) {
        case .off:
            states[usage] = .latched
            return .down
        case .latched:
            if let t = lastTap, t.usage == usage, nowNs - t.atNs <= doubleTapNs {
                states[usage] = .locked
                return .none
            }
            states[usage] = .off
            return .up
        case .locked:
            states[usage] = .off
            return .up
        }
    }

    /// After a non-modifier key goes up: latched modifiers release. Returns the usages to send "up" for.
    public mutating func keyReleased() -> [UInt16] {
        let latched = states.filter { $0.value == .latched }.map(\.key).sorted()
        for u in latched { states[u] = .off }
        return latched
    }
}
