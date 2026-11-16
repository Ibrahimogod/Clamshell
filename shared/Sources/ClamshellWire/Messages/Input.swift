/// Input channel messages (protocol 1.2, capability `inputV1`, ADR-0013).
///
/// - Every message has a sequence number from one counter per session. The phone resends each message in
///   the next packets (flag `redundant`), and the Mac applies a sequence number once (`InputDeduper`).
/// - Every key, button and scroll message carries the full modifier bitmap, and `InputState` repeats what
///   is held every 250 ms, so a lost packet can't leave ⌘ or a mouse button stuck. The Mac also releases
///   everything after 2 s without input.
/// - Distances are in Mac points × 16 (sub-point precision), velocities in points per second.

/// Modifier bitmap. Bits 0–7 are the HID modifier byte (usages 0xE0–0xE7), so a HID report maps directly.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let leftControl = KeyModifiers(rawValue: 1 << 0)
    public static let leftShift = KeyModifiers(rawValue: 1 << 1)
    public static let leftOption = KeyModifiers(rawValue: 1 << 2)
    public static let leftCommand = KeyModifiers(rawValue: 1 << 3)
    public static let rightControl = KeyModifiers(rawValue: 1 << 4)
    public static let rightShift = KeyModifiers(rawValue: 1 << 5)
    public static let rightOption = KeyModifiers(rawValue: 1 << 6)
    public static let rightCommand = KeyModifiers(rawValue: 1 << 7)
    public static let capsLock = KeyModifiers(rawValue: 1 << 8)
    public static let function = KeyModifiers(rawValue: 1 << 9)

    public var control: Bool { !isDisjoint(with: [.leftControl, .rightControl]) }
    public var shift: Bool { !isDisjoint(with: [.leftShift, .rightShift]) }
    public var option: Bool { !isDisjoint(with: [.leftOption, .rightOption]) }
    public var command: Bool { !isDisjoint(with: [.leftCommand, .rightCommand]) }

    /// The modifier a HID keyboard usage (page 7) stands for, if it is one.
    public static func forUsage(_ usage: UInt16) -> KeyModifiers? {
        switch usage {
        case 0xE0...0xE7: KeyModifiers(rawValue: 1 << UInt32(usage - 0xE0))
        case HIDUsage.capsLock: .capsLock
        case HIDUsage.function: .function
        default: nil
        }
    }
}

public enum HIDUsage {
    /// Page 7 (keyboard). `function` is Apple's vendor usage for fn/🌐, carried on page 7 here.
    public static let keyboardPage: UInt16 = 0x07
    public static let consumerPage: UInt16 = 0x0C
    public static let capsLock: UInt16 = 0x39
    public static let function: UInt16 = 0x03   // unused by the HID table (ErrorUndefined), reserved for fn
    /// 1.6: Clamshell's own vendor page (0xFF00–0xFFFF are vendor-defined) for actions that are not keys.
    public static let clamshellPage: UInt16 = 0xFF43
    /// On `clamshellPage`: switch the Mac to its next keyboard input source (🌐 tapped alone, e.g. English ⇄ Arabic).
    public static let nextInputSource: UInt16 = 0x01
}

public struct KeyEvent: WireMessage {
    public static let channel = Channel.input
    public static let type = MessageType.keyEvent

    public var seq: UInt32
    /// HID usage page: 7 keyboard, 12 consumer (media keys).
    public var page: UInt16
    public var usage: UInt16
    public var down: Bool
    /// Modifiers held after this event.
    public var modifiers: KeyModifiers

    public init(seq: UInt32, page: UInt16 = HIDUsage.keyboardPage, usage: UInt16, down: Bool, modifiers: KeyModifiers) {
        self.seq = seq; self.page = page; self.usage = usage; self.down = down; self.modifiers = modifiers
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(seq))
        if page != HIDUsage.keyboardPage { t.uint(2, UInt64(page)) }
        t.uint(3, UInt64(usage))
        t.bool(4, down)
        t.uint(5, UInt64(modifiers.rawValue))
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4, 5])
        seq = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "seq")
        page = try (t.optionalUInt(2) ?? UInt64(HIDUsage.keyboardPage)).narrowed(to: UInt16.self, field: "page")
        usage = try t.requiredUInt(3).narrowed(to: UInt16.self, field: "usage")
        down = try t.requiredUInt(4) != 0
        modifiers = KeyModifiers(rawValue: try (t.optionalUInt(5) ?? 0).narrowed(to: UInt32.self, field: "modifiers"))
    }
}

public struct MouseButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left = MouseButtons(rawValue: 1 << 0)
    public static let right = MouseButtons(rawValue: 1 << 1)
    public static let middle = MouseButtons(rawValue: 1 << 2)
}

/// Relative pointer motion (trackpad), or an absolute position on the display (direct touch).
public struct PointerMove: WireMessage {
    public static let channel = Channel.input
    public static let type = MessageType.pointerMove

    public var seq: UInt32
    /// Points × 16.
    public var dx: Int32
    public var dy: Int32
    /// Direct touch: position as a fraction of the display, 0…65535 on each axis. Replaces dx/dy.
    public var absolute: (x: UInt16, y: UInt16)?

    public init(seq: UInt32, dx: Int32, dy: Int32, absolute: (x: UInt16, y: UInt16)? = nil) {
        self.seq = seq; self.dx = dx; self.dy = dy; self.absolute = absolute
    }

    public static func == (a: PointerMove, b: PointerMove) -> Bool {
        a.seq == b.seq && a.dx == b.dx && a.dy == b.dy && a.absolute?.x == b.absolute?.x && a.absolute?.y == b.absolute?.y
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(seq))
        if dx != 0 { t.sint(2, Int64(dx)) }
        if dy != 0 { t.sint(3, Int64(dy)) }
        if let a = absolute { t.uint(4, UInt64(a.x)); t.uint(5, UInt64(a.y)) }
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4, 5])
        seq = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "seq")
        dx = try Int32(exactlyOrThrow: t.optionalSInt(2) ?? 0, field: "dx")
        dy = try Int32(exactlyOrThrow: t.optionalSInt(3) ?? 0, field: "dy")
        if let x = try t.optionalUInt(4), let y = try t.optionalUInt(5) {
            absolute = (try x.narrowed(to: UInt16.self, field: "x"), try y.narrowed(to: UInt16.self, field: "y"))
        } else {
            absolute = nil
        }
    }
}

public enum PointerButton: UInt8, Sendable {
    case left = 0, right = 1, middle = 2
}

public struct PointerButtonEvent: WireMessage {
    public static let channel = Channel.input
    public static let type = MessageType.pointerButton

    public var seq: UInt32
    public var button: PointerButton
    public var down: Bool
    public var modifiers: KeyModifiers

    public init(seq: UInt32, button: PointerButton, down: Bool, modifiers: KeyModifiers = []) {
        self.seq = seq; self.button = button; self.down = down; self.modifiers = modifiers
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(seq))
        t.uint(2, UInt64(button.rawValue))
        t.bool(3, down)
        t.uint(4, UInt64(modifiers.rawValue))
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4])
        seq = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "seq")
        guard let b = PointerButton(rawValue: try t.requiredUInt(2).narrowed(to: UInt8.self, field: "button")) else {
            throw WireError.invalidValue("unknown button")
        }
        button = b
        down = try t.requiredUInt(3) != 0
        modifiers = KeyModifiers(rawValue: try (t.optionalUInt(4) ?? 0).narrowed(to: UInt32.self, field: "modifiers"))
    }
}

public enum ScrollPhase: UInt8, Sendable {
    /// A discrete step (wheel-like); no phase.
    case none = 0, began = 1, changed = 2, ended = 3, cancelled = 4
}

/// Two-finger scroll. Deltas follow the fingers ("content moves with the finger"); the Mac applies its
/// own natural-scrolling setting. `ended` carries the release velocity, from which the Mac generates
/// momentum events like a real trackpad.
public struct ScrollEvent: WireMessage {
    public static let channel = Channel.input
    public static let type = MessageType.scroll

    public var seq: UInt32
    public var dx: Int32
    public var dy: Int32
    public var phase: ScrollPhase
    public var velocityX: Int32
    public var velocityY: Int32
    public var modifiers: KeyModifiers

    public init(seq: UInt32, dx: Int32, dy: Int32, phase: ScrollPhase, velocityX: Int32 = 0, velocityY: Int32 = 0, modifiers: KeyModifiers = []) {
        self.seq = seq; self.dx = dx; self.dy = dy; self.phase = phase
        self.velocityX = velocityX; self.velocityY = velocityY; self.modifiers = modifiers
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(seq))
        if dx != 0 { t.sint(2, Int64(dx)) }
        if dy != 0 { t.sint(3, Int64(dy)) }
        t.uint(4, UInt64(phase.rawValue))
        if velocityX != 0 { t.sint(5, Int64(velocityX)) }
        if velocityY != 0 { t.sint(6, Int64(velocityY)) }
        if !modifiers.isEmpty { t.uint(7, UInt64(modifiers.rawValue)) }
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: Set(1...7))
        seq = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "seq")
        dx = try Int32(exactlyOrThrow: t.optionalSInt(2) ?? 0, field: "dx")
        dy = try Int32(exactlyOrThrow: t.optionalSInt(3) ?? 0, field: "dy")
        phase = ScrollPhase(rawValue: try (t.optionalUInt(4) ?? 0).narrowed(to: UInt8.self, field: "phase")) ?? .none
        velocityX = try Int32(exactlyOrThrow: t.optionalSInt(5) ?? 0, field: "velocityX")
        velocityY = try Int32(exactlyOrThrow: t.optionalSInt(6) ?? 0, field: "velocityY")
        modifiers = KeyModifiers(rawValue: try (t.optionalUInt(7) ?? 0).narrowed(to: UInt32.self, field: "modifiers"))
    }
}

/// Trackpad gestures the Mac turns into the same outcome as on a MacBook (ADR-0013 table).
public enum GestureKind: UInt16, Sendable, CaseIterable {
    case spaceLeft = 1, spaceRight = 2, missionControl = 3, appExpose = 4
    case appSwitcherBegin = 5, appSwitcherNext = 6, appSwitcherPrevious = 7, appSwitcherEnd = 8
    case zoomIn = 9, zoomOut = 10, smartZoom = 11, showDesktop = 12, launchpad = 13, lookUp = 14
}

public struct GestureEvent: WireMessage {
    public static let channel = Channel.input
    public static let type = MessageType.gesture

    public var seq: UInt32
    public var kind: GestureKind

    public init(seq: UInt32, kind: GestureKind) { self.seq = seq; self.kind = kind }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(seq))
        t.uint(2, UInt64(kind.rawValue))
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2])
        seq = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "seq")
        guard let k = GestureKind(rawValue: try t.requiredUInt(2).narrowed(to: UInt16.self, field: "kind")) else {
            throw WireError.invalidValue("unknown gesture")
        }
        kind = k
    }
}

/// What the phone holds right now, every 250 ms while anything is held (and once when it lets go). The
/// Mac releases anything it holds that isn't listed: a lost "up" can't leave a key down.
public struct InputState: WireMessage {
    public static let channel = Channel.input
    public static let type = MessageType.inputState

    public var seq: UInt32
    public var modifiers: KeyModifiers
    /// Non-modifier keyboard usages held down (page 7).
    public var keys: [UInt16]
    public var buttons: MouseButtons

    public init(seq: UInt32, modifiers: KeyModifiers, keys: [UInt16], buttons: MouseButtons) {
        self.seq = seq; self.modifiers = modifiers; self.keys = keys; self.buttons = buttons
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(seq))
        t.uint(2, UInt64(modifiers.rawValue))
        for k in keys { t.uint(3, UInt64(k)) }
        t.uint(4, UInt64(buttons.rawValue))
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4])
        seq = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "seq")
        modifiers = KeyModifiers(rawValue: try (t.optionalUInt(2) ?? 0).narrowed(to: UInt32.self, field: "modifiers"))
        keys = try t.all(3).map { b in
            var r = ByteReader(b)
            return try r.varint().narrowed(to: UInt16.self, field: "key")
        }
        buttons = MouseButtons(rawValue: try (t.optionalUInt(4) ?? 0).narrowed(to: UInt8.self, field: "buttons"))
    }
}

/// Mac → phone (input channel, unreliable, ~60 Hz while it moves): where the Mac's pointer really is, so
/// the phone's locally drawn cursor can reconcile (ADR-0009).
public struct CursorPosition: WireMessage {
    public static let channel = Channel.input
    public static let type = MessageType.cursorPosition

    /// The last `PointerMove` sequence number the Mac had applied.
    public var appliedSeq: UInt32
    /// Points × 16 from the display's top-left corner.
    public var x: Int32
    public var y: Int32
    public var visible: Bool
    public var shapeId: UInt64

    public init(appliedSeq: UInt32, x: Int32, y: Int32, visible: Bool, shapeId: UInt64) {
        self.appliedSeq = appliedSeq; self.x = x; self.y = y; self.visible = visible; self.shapeId = shapeId
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(appliedSeq))
        t.sint(2, Int64(x))
        t.sint(3, Int64(y))
        t.bool(4, visible)
        t.uint(5, shapeId)
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4, 5])
        appliedSeq = try (t.optionalUInt(1) ?? 0).narrowed(to: UInt32.self, field: "appliedSeq")
        x = try Int32(exactlyOrThrow: t.optionalSInt(2) ?? 0, field: "x")
        y = try Int32(exactlyOrThrow: t.optionalSInt(3) ?? 0, field: "y")
        visible = (try t.optionalUInt(4) ?? 1) != 0
        shapeId = try t.optionalUInt(5) ?? 0
    }
}

/// Mac → phone (control channel): a cursor image, sent once per shape (the phone caches by `shapeId`).
public struct CursorShape: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.cursorShape

    public var shapeId: UInt64
    /// PNG at 2× the point size.
    public var png: [UInt8]
    /// Hotspot and size in points × 16.
    public var hotX: UInt32
    public var hotY: UInt32
    public var width: UInt32
    public var height: UInt32

    public init(shapeId: UInt64, png: [UInt8], hotX: UInt32, hotY: UInt32, width: UInt32, height: UInt32) {
        self.shapeId = shapeId; self.png = png; self.hotX = hotX; self.hotY = hotY; self.width = width; self.height = height
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, shapeId)
        t.bytes(2, png)
        t.uint(3, UInt64(hotX))
        t.uint(4, UInt64(hotY))
        t.uint(5, UInt64(width))
        t.uint(6, UInt64(height))
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: Set(1...6))
        shapeId = try t.requiredUInt(1)
        png = try t.requiredBytes(2)
        hotX = try (t.optionalUInt(3) ?? 0).narrowed(to: UInt32.self, field: "hotX")
        hotY = try (t.optionalUInt(4) ?? 0).narrowed(to: UInt32.self, field: "hotY")
        width = try (t.optionalUInt(5) ?? 0).narrowed(to: UInt32.self, field: "width")
        height = try (t.optionalUInt(6) ?? 0).narrowed(to: UInt32.self, field: "height")
    }
}

extension Int32 {
    init(exactlyOrThrow v: Int64, field: String) throws {
        guard let x = Int32(exactly: v) else { throw WireError.invalidValue("\(field) out of range: \(v)") }
        self = x
    }
}

/// Mac side: applies each input sequence number once. Redundant copies and reordered packets are dropped
/// when already seen; a window of 1024 numbers.
public struct InputDeduper: Sendable {
    private var highest: UInt32?
    private var seen = Set<UInt32>()

    public init() {}

    /// True the first time `seq` is offered.
    public mutating func accept(_ seq: UInt32) -> Bool {
        if let h = highest {
            let ahead = Int32(bitPattern: seq &- h)
            if ahead <= -1024 { return false }              // too old to know: drop rather than replay
            if seen.contains(seq) { return false }
            if ahead > 0 {
                highest = seq
                if seen.count > 2048 { seen = seen.filter { Int32(bitPattern: seq &- $0) < 1024 } }
            }
        } else {
            highest = seq
        }
        seen.insert(seq)
        return true
    }
}

extension InnerMessage {
    /// The input sequence number, for any input-channel message (nil for other messages).
    public var inputSeq: UInt32? {
        guard channel == .input, let t = try? TLVReader(body, knownTags: []), let f = t.fields.first(where: { $0.tag == 1 }) else { return nil }
        var r = ByteReader(f.value)
        return (try? r.varint()).flatMap { UInt32(exactly: $0) }
    }
}
