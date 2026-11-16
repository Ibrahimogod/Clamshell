/// RTT and clock-offset probe (NTP-style). Times are the sender's monotonic clock in nanoseconds.
public struct Ping: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.ping

    public var id: UInt32
    public var t1: UInt64

    public init(id: UInt32, t1: UInt64) { self.id = id; self.t1 = t1 }

    /// Reserved for the transport's keepalive, whose `t1` is not on the app's clock. Apps number their
    /// pings from 1 and ignore a `Pong` with this id.
    public static let keepaliveId: UInt32 = 0

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(id))
        t.uint(2, t1)
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2])
        id = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "id")
        t1 = try t.requiredUInt(2)
    }
}

/// Reply to `Ping`: `t2` = receive time, `t3` = send time, both on the responder's monotonic clock.
public struct Pong: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.pong

    public var id: UInt32
    public var t1: UInt64
    public var t2: UInt64
    public var t3: UInt64

    public init(id: UInt32, t1: UInt64, t2: UInt64, t3: UInt64) { self.id = id; self.t1 = t1; self.t2 = t2; self.t3 = t3 }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(id))
        t.uint(2, t1)
        t.uint(3, t2)
        t.uint(4, t3)
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4])
        id = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "id")
        t1 = try t.requiredUInt(2)
        t2 = try t.requiredUInt(3)
        t3 = try t.requiredUInt(4)
    }
}

public enum GoodbyeReason: Equatable, Sendable {
    case userDisconnected, revoked, paused, shuttingDown
    case unknown(UInt64)

    init(raw: UInt64) {
        switch raw {
        case 1: self = .userDisconnected
        case 2: self = .revoked
        case 3: self = .paused
        case 4: self = .shuttingDown
        default: self = .unknown(raw)
        }
    }

    var raw: UInt64 {
        switch self {
        case .userDisconnected: 1
        case .revoked: 2
        case .paused: 3
        case .shuttingDown: 4
        case .unknown(let v): v
        }
    }
}

public struct Goodbye: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.goodbye

    public var reason: GoodbyeReason
    public init(reason: GoodbyeReason) { self.reason = reason }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, reason.raw)
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1])
        reason = GoodbyeReason(raw: try t.requiredUInt(1))
    }
}

public enum KeyframeReason: Equatable, Sendable {
    case sessionStart, frameLost, decoderError, formatChanged
    case unknown(UInt64)

    init(raw: UInt64) {
        switch raw {
        case 1: self = .sessionStart
        case 2: self = .frameLost
        case 3: self = .decoderError
        case 4: self = .formatChanged
        default: self = .unknown(raw)
        }
    }

    var raw: UInt64 {
        switch self {
        case .sessionStart: 1
        case .frameLost: 2
        case .decoderError: 3
        case .formatChanged: 4
        case .unknown(let v): v
        }
    }
}

/// Client → Mac. In M1 a lost frame triggers a keyframe; LTR ACK/NACK replaces most of these in M2+.
public struct KeyframeRequest: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.keyframeRequest

    public var reason: KeyframeReason
    public var lastGoodFrameId: UInt32

    public init(reason: KeyframeReason, lastGoodFrameId: UInt32) {
        self.reason = reason
        self.lastGoodFrameId = lastGoodFrameId
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, reason.raw)
        t.uint(2, UInt64(lastGoodFrameId))
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2])
        reason = KeyframeReason(raw: try t.requiredUInt(1))
        lastGoodFrameId = try (t.optionalUInt(2) ?? 0).narrowed(to: UInt32.self, field: "lastGoodFrameId")
    }
}

/// Mac → client, about twice a second while streaming: the sender's side of the HUD (M1).
/// Counters are totals since the stream started. Every field is optional on decode (0 if absent).
public struct HostStats: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.hostStats

    public var encodeMicros: UInt32        // last frame's encode time
    public var framesSent: UInt32
    public var keyframes: UInt32
    public var refinements: UInt32
    public var bytesSent: UInt64
    public var encoderDrops: UInt32
    public var skippedWhileBusy: UInt32

    public init(encodeMicros: UInt32, framesSent: UInt32, keyframes: UInt32, refinements: UInt32, bytesSent: UInt64,
                encoderDrops: UInt32, skippedWhileBusy: UInt32) {
        self.encodeMicros = encodeMicros
        self.framesSent = framesSent
        self.keyframes = keyframes
        self.refinements = refinements
        self.bytesSent = bytesSent
        self.encoderDrops = encoderDrops
        self.skippedWhileBusy = skippedWhileBusy
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(encodeMicros))
        t.uint(2, UInt64(framesSent))
        t.uint(3, UInt64(keyframes))
        t.uint(4, UInt64(refinements))
        t.uint(5, bytesSent)
        t.uint(6, UInt64(encoderDrops))
        t.uint(7, UInt64(skippedWhileBusy))
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4, 5, 6, 7])
        func u32(_ tag: UInt64, _ name: String) throws -> UInt32 { try (t.optionalUInt(tag) ?? 0).narrowed(to: UInt32.self, field: name) }
        encodeMicros = try u32(1, "encodeMicros")
        framesSent = try u32(2, "framesSent")
        keyframes = try u32(3, "keyframes")
        refinements = try u32(4, "refinements")
        bytesSent = try t.optionalUInt(5) ?? 0
        encoderDrops = try u32(6, "encoderDrops")
        skippedWhileBusy = try u32(7, "skippedWhileBusy")
    }
}
