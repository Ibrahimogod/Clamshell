/// Client → Mac, every ~100 ms while video flows (protocol 1.1, capability `receiverReports`).
/// Counts are for the interval since the previous report. The Mac's rate controller (ADR-0008 §5) reads
/// loss and queuing delay from it. Every field is optional on decode (0 if absent).
public struct ReceiverReport: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.receiverReport

    public var intervalMicros: UInt32
    public var bytesReceived: UInt32
    public var framesCompleted: UInt16
    public var framesLost: UInt16
    /// Fragments of completed or lost frames that arrived, and how many those frames had in total.
    public var fragmentsReceived: UInt32
    public var fragmentsExpected: UInt32
    /// How far the latest frames' one-way delay sits above the lowest seen recently (a queue building up).
    public var queuingDelayMicros: UInt32
    public var highestFrameId: UInt32
    public var fecRecovered: UInt16
    /// The phone's latest ping round trip. The Mac sizes its "duplicate keyframe request" window from it.
    public var rttMicros: UInt32

    public init(intervalMicros: UInt32, bytesReceived: UInt32, framesCompleted: UInt16, framesLost: UInt16,
                fragmentsReceived: UInt32, fragmentsExpected: UInt32, queuingDelayMicros: UInt32, highestFrameId: UInt32,
                fecRecovered: UInt16 = 0, rttMicros: UInt32 = 0) {
        self.intervalMicros = intervalMicros
        self.bytesReceived = bytesReceived
        self.framesCompleted = framesCompleted
        self.framesLost = framesLost
        self.fragmentsReceived = fragmentsReceived
        self.fragmentsExpected = fragmentsExpected
        self.queuingDelayMicros = queuingDelayMicros
        self.highestFrameId = highestFrameId
        self.fecRecovered = fecRecovered
        self.rttMicros = rttMicros
    }

    /// Share of expected fragments that never arrived, 0…1.
    public var fragmentLoss: Double {
        fragmentsExpected == 0 ? 0 : Double(fragmentsExpected - min(fragmentsReceived, fragmentsExpected)) / Double(fragmentsExpected)
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(intervalMicros))
        t.uint(2, UInt64(bytesReceived))
        t.uint(3, UInt64(framesCompleted))
        t.uint(4, UInt64(framesLost))
        t.uint(5, UInt64(fragmentsReceived))
        t.uint(6, UInt64(fragmentsExpected))
        t.uint(7, UInt64(queuingDelayMicros))
        t.uint(8, UInt64(highestFrameId))
        t.uint(9, UInt64(fecRecovered))
        t.uint(10, UInt64(rttMicros))
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: Set(1...10))
        func n<T: FixedWidthInteger>(_ tag: UInt64, _ name: String, as: T.Type) throws -> T {
            try (t.optionalUInt(tag) ?? 0).narrowed(to: T.self, field: name)
        }
        intervalMicros = try n(1, "intervalMicros", as: UInt32.self)
        bytesReceived = try n(2, "bytesReceived", as: UInt32.self)
        framesCompleted = try n(3, "framesCompleted", as: UInt16.self)
        framesLost = try n(4, "framesLost", as: UInt16.self)
        fragmentsReceived = try n(5, "fragmentsReceived", as: UInt32.self)
        fragmentsExpected = try n(6, "fragmentsExpected", as: UInt32.self)
        queuingDelayMicros = try n(7, "queuingDelayMicros", as: UInt32.self)
        highestFrameId = try n(8, "highestFrameId", as: UInt32.self)
        fecRecovered = try n(9, "fecRecovered", as: UInt16.self)
        rttMicros = try n(10, "rttMicros", as: UInt32.self)
    }
}

/// What the Mac's own screen is doing. A remote viewer needs to know, because a locked Mac or a running
/// screen saver is what the stream then shows.
public enum MacScreenState: Equatable, Sendable {
    case active, screenSaver, locked
    case unknown(UInt64)

    init(raw: UInt64) {
        switch raw {
        case 1: self = .active
        case 2: self = .screenSaver
        case 3: self = .locked
        default: self = .unknown(raw)
        }
    }

    var raw: UInt64 {
        switch self {
        case .active: 1
        case .screenSaver: 2
        case .locked: 3
        case .unknown(let v): v
        }
    }
}

/// Mac → client, on every change and every 2 s while streaming (protocol 1.1).
public struct HostState: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.hostState

    public var screen: MacScreenState
    /// The host can hold off the screen saver and idle lock for the session (it has Accessibility access).
    public var keepsAwake: Bool
    public var targetBitrateKbps: UInt32
    /// Forward error correction overhead in use, in percent (0 = off).
    public var fecPercent: UInt8
    /// 1.2: whether the host may post keyboard and mouse events (macOS Accessibility). nil from a 1.1 host.
    public var inputAllowed: Bool?
    /// 1.5: someone is using the Mac's own keyboard or mouse, so the phone's input is paused (T9).
    public var localUser: Bool
    /// 1.8: whether the Mac can pass the phone's microphone on (its Clamshell Microphone device is installed).
    /// nil from older Macs.
    public var micReady: Bool?
    /// 1.8: the window being streamed on its own ("App — Title"), nil for the whole screen.
    public var window: String?
    /// 1.8: the frame rate the Mac streams at now (after the phone's cap), 0 if not reported.
    public var fps: UInt16
    /// 1.9: the Mac's own screen is hidden behind the curtain. nil from older Macs.
    public var curtain: Bool?
    /// 1.9: the Mac's own keyboard and trackpad are turned off for the session. nil from older Macs.
    public var localInputBlocked: Bool?

    public init(screen: MacScreenState, keepsAwake: Bool, targetBitrateKbps: UInt32, fecPercent: UInt8 = 0, inputAllowed: Bool? = nil,
                localUser: Bool = false, micReady: Bool? = nil, window: String? = nil, fps: UInt16 = 0,
                curtain: Bool? = nil, localInputBlocked: Bool? = nil) {
        self.curtain = curtain
        self.localInputBlocked = localInputBlocked
        self.localUser = localUser
        self.micReady = micReady
        self.window = window
        self.fps = fps
        self.screen = screen
        self.keepsAwake = keepsAwake
        self.targetBitrateKbps = targetBitrateKbps
        self.fecPercent = fecPercent
        self.inputAllowed = inputAllowed
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, screen.raw)
        t.uint(2, keepsAwake ? 1 : 0)
        t.uint(3, UInt64(targetBitrateKbps))
        t.uint(4, UInt64(fecPercent))
        if let inputAllowed { t.bool(5, inputAllowed) }
        if localUser { t.bool(6, true) }
        if let micReady { t.bool(7, micReady) }
        if let window { t.string(8, window) }
        if fps > 0 { t.uint(9, UInt64(fps)) }
        if let curtain { t.bool(10, curtain) }
        if let localInputBlocked { t.bool(11, localInputBlocked) }
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        curtain = try t.optionalUInt(10).map { $0 != 0 }
        localInputBlocked = try t.optionalUInt(11).map { $0 != 0 }
        micReady = try t.optionalUInt(7).map { $0 != 0 }
        window = try t.optionalString(8)
        fps = try (t.optionalUInt(9) ?? 0).narrowed(to: UInt16.self, field: "fps")
        inputAllowed = try t.optionalUInt(5).map { $0 != 0 }
        localUser = (try t.optionalUInt(6) ?? 0) != 0
        screen = MacScreenState(raw: try t.optionalUInt(1) ?? 1)
        keepsAwake = (try t.optionalUInt(2) ?? 0) != 0
        targetBitrateKbps = try (t.optionalUInt(3) ?? 0).narrowed(to: UInt32.self, field: "targetBitrateKbps")
        fecPercent = try (t.optionalUInt(4) ?? 0).narrowed(to: UInt8.self, field: "fecPercent")
    }
}

/// Mac → phone (1.3): where the Mac can be reached away from home (ADR-0005). Sent at session start and when
/// the Mac learns a new public address. It arrives inside the Mac's authenticated session, so it carries
/// the Mac's static-key authentication without a separate signature; the phone keeps the highest `seq`.
public struct HomeEndpoint: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.homeEndpoint

    public var host: String
    public var udpPort: UInt16
    public var tcpPort: UInt16
    /// Unix seconds when the Mac last confirmed `host`.
    public var observedAt: UInt64
    public var seq: UInt64

    public init(host: String, udpPort: UInt16, tcpPort: UInt16, observedAt: UInt64, seq: UInt64) {
        self.host = host
        self.udpPort = udpPort
        self.tcpPort = tcpPort
        self.observedAt = observedAt
        self.seq = seq
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.string(1, host)
        t.uint(2, UInt64(udpPort))
        t.uint(3, UInt64(tcpPort))
        t.uint(4, observedAt)
        t.uint(5, seq)
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4, 5])
        host = try t.optionalString(1) ?? ""
        udpPort = try (t.optionalUInt(2) ?? 0).narrowed(to: UInt16.self, field: "udpPort")
        tcpPort = try (t.optionalUInt(3) ?? 0).narrowed(to: UInt16.self, field: "tcpPort")
        observedAt = try t.optionalUInt(4) ?? 0
        seq = try t.optionalUInt(5) ?? 0
    }
}

/// Phone → Mac (1.4): the phone's posture changed and held for 600 ms (ADR-0012), so it asks for the
/// virtual display mode that fits. The Mac rebuilds the display and encoder; frame ids and the format
/// generation carry on from the old stream, so the phone keeps its pipeline.
public struct DisplayModeRequest: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.displayModeRequest

    public var mode: DisplayMode

    public init(mode: DisplayMode) { self.mode = mode }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.bytes(1, mode.encode())
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1])
        guard let b = try t.optionalBytes(1) else { throw WireError.missingField(tag: 1) }
        mode = try DisplayMode(encoded: b)
    }
}

/// Mac → phone (1.6): the Mac's current keyboard layout, at session start and whenever it changes
/// (🌐 on the phone, the Mac's input menu, a shortcut at the Mac). The phone labels its keys with what this
/// layout types, so an Arabic layout shows Arabic letters. Keys still go out as positions (ADR-0013).
/// Sent as a bulk transfer: the label table is larger than one packet.
public struct KeyboardLayout: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.keyboardLayout

    public struct Key: Equatable, Sendable {
        public var usage: UInt16
        public var base: String
        public var shifted: String
        public init(usage: UInt16, base: String, shifted: String) { self.usage = usage; self.base = base; self.shifted = shifted }
    }

    /// The input source id, e.g. `com.apple.keylayout.Arabic`.
    public var id: String
    /// Its name in the Mac's language, e.g. "Arabic".
    public var name: String
    /// Its first language, BCP 47 (`ar`, `en`); empty if the Mac doesn't say.
    public var language: String
    /// HID usage → what the key types without and with Shift. Keys that type nothing are left out.
    public var keys: [Key]

    public init(id: String, name: String, language: String, keys: [Key]) {
        self.id = id
        self.name = name
        self.language = language
        self.keys = keys
    }

    public var isRightToLeft: Bool { ["ar", "fa", "he", "ur", "ps", "ug", "yi", "ckb", "sd"].contains(language.split(separator: "-").first.map(String.init) ?? "") }

    public func label(_ usage: UInt16) -> Key? { keys.first { $0.usage == usage } }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.string(1, id)
        t.string(2, name)
        t.string(3, language)
        for k in keys {
            var e = TLVWriter()
            e.uint(1, UInt64(k.usage))
            e.string(2, k.base)
            e.string(3, k.shifted)
            t.bytes(4, e.bytes)
        }
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4])
        id = try t.optionalString(1) ?? ""
        name = try t.optionalString(2) ?? ""
        language = try t.optionalString(3) ?? ""
        guard t.all(4).count <= 256 else { throw WireError.invalidValue("too many keys") }
        keys = try t.all(4).map { b in
            let e = try TLVReader(b, knownTags: [1, 2, 3])
            let base = try e.optionalString(2) ?? "", shifted = try e.optionalString(3) ?? ""
            guard base.utf8.count <= 16, shifted.utf8.count <= 16 else { throw WireError.invalidValue("key label too long") }
            return Key(usage: try (e.optionalUInt(1) ?? 0).narrowed(to: UInt16.self, field: "usage"), base: base, shifted: shifted)
        }
    }
}
