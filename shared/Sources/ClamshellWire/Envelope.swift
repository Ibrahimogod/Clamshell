/// Protocol version carried in `Hello` (ADR-0011). Bump `minor` for additive changes;
/// bump `major` only for incompatible ones (and give old peers a clean `Incompatible`).
public enum ProtocolVersion {
    public static let major: UInt16 = 1
    public static let minor: UInt16 = 6
}

/// First byte of every packet on every path (outer layer, ADR-0011 §1).
/// `0xF0...0xFF` is reserved. Unknown values are dropped silently by the receiver.
public enum OuterPacketType: Equatable, Sendable {
    case handshakeInitiation   // 0x01
    case handshakeResponse     // 0x02
    case cookieReply           // 0x03 (reserved for M3 DoS cookies)
    case transport             // 0x04
    case pairing               // 0x05 (XXpsk3 pairing, LAN only, ADR-0014)
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0x01: self = .handshakeInitiation
        case 0x02: self = .handshakeResponse
        case 0x03: self = .cookieReply
        case 0x04: self = .transport
        case 0x05: self = .pairing
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .handshakeInitiation: 0x01
        case .handshakeResponse: 0x02
        case .cookieReply: 0x03
        case .transport: 0x04
        case .pairing: 0x05
        case .unknown(let v): v
        }
    }
}

/// Logical channels inside a session (ADR-0001). Each has its own reliability mode.
public enum Channel: Equatable, Hashable, Sendable {
    case control     // reliable (ARQ from M3; M1 relies on LAN + retries at the app level)
    case video       // unreliable, latest-wins
    case input       // unreliable, sent redundantly
    case clipboard   // reliable, opt-in
    case files       // reliable, opt-in
    case audio       // unreliable
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .control
        case 1: self = .video
        case 2: self = .input
        case 3: self = .clipboard
        case 4: self = .files
        case 5: self = .audio
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .control: 0
        case .video: 1
        case .input: 2
        case .clipboard: 3
        case .files: 4
        case .audio: 5
        case .unknown(let v): v
        }
    }
}

/// Message type numbers. A new incompatible layout of a message gets a *new* number; numbers are
/// never reused. Unknown types decode to `.unknown` and are skipped by the dispatcher.
public enum MessageType: Equatable, Hashable, Sendable {
    // control
    case hello              // 0x0001
    case incompatible       // 0x0002
    case ping               // 0x0003
    case pong               // 0x0004
    case goodbye            // 0x0005
    case keyframeRequest    // 0x0010
    case receiverReport     // 0x0011 (1.1)
    case hostStats          // 0x0020
    case hostState          // 0x0021 (1.1)
    case homeEndpoint       // 0x0022 (1.3)
    case displayModeRequest // 0x0023 (1.4)
    case keyboardLayout     // 0x0024 (1.6)
    case cursorShape        // 0x0030 (1.2)
    case bulkChunk          // 0x0040 (1.2)
    case bulkAck            // 0x0041 (1.2)
    case keyEvent           // 0x0201 (1.2)
    case pointerMove        // 0x0202 (1.2)
    case pointerButton      // 0x0203 (1.2)
    case scroll             // 0x0204 (1.2)
    case gesture            // 0x0205 (1.2)
    case inputState         // 0x0206 (1.2)
    case cursorPosition     // 0x0210 (1.2)
    case clipboardOffer     // 0x0301 (1.2)
    case fileOffer          // 0x0302 (1.5)
    case audioPacket        // 0x0401 (1.5)
    // video
    case videoFormat        // 0x0101
    case videoFragment      // 0x0102
    case unknown(UInt16)

    public init(rawValue: UInt16) {
        switch rawValue {
        case 0x0001: self = .hello
        case 0x0002: self = .incompatible
        case 0x0003: self = .ping
        case 0x0004: self = .pong
        case 0x0005: self = .goodbye
        case 0x0010: self = .keyframeRequest
        case 0x0011: self = .receiverReport
        case 0x0020: self = .hostStats
        case 0x0021: self = .hostState
        case 0x0022: self = .homeEndpoint
        case 0x0023: self = .displayModeRequest
        case 0x0024: self = .keyboardLayout
        case 0x0030: self = .cursorShape
        case 0x0040: self = .bulkChunk
        case 0x0041: self = .bulkAck
        case 0x0201: self = .keyEvent
        case 0x0202: self = .pointerMove
        case 0x0203: self = .pointerButton
        case 0x0204: self = .scroll
        case 0x0205: self = .gesture
        case 0x0206: self = .inputState
        case 0x0210: self = .cursorPosition
        case 0x0301: self = .clipboardOffer
        case 0x0302: self = .fileOffer
        case 0x0401: self = .audioPacket
        case 0x0101: self = .videoFormat
        case 0x0102: self = .videoFragment
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt16 {
        switch self {
        case .hello: 0x0001
        case .incompatible: 0x0002
        case .ping: 0x0003
        case .pong: 0x0004
        case .goodbye: 0x0005
        case .keyframeRequest: 0x0010
        case .receiverReport: 0x0011
        case .hostStats: 0x0020
        case .hostState: 0x0021
        case .homeEndpoint: 0x0022
        case .displayModeRequest: 0x0023
        case .keyboardLayout: 0x0024
        case .cursorShape: 0x0030
        case .bulkChunk: 0x0040
        case .bulkAck: 0x0041
        case .keyEvent: 0x0201
        case .pointerMove: 0x0202
        case .pointerButton: 0x0203
        case .scroll: 0x0204
        case .gesture: 0x0205
        case .inputState: 0x0206
        case .cursorPosition: 0x0210
        case .clipboardOffer: 0x0301
        case .fileOffer: 0x0302
        case .audioPacket: 0x0401
        case .videoFormat: 0x0101
        case .videoFragment: 0x0102
        case .unknown(let v): v
        }
    }
}

public struct MessageFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// This copy is a redundant resend (input channel); receivers dedupe by sequence.
    public static let redundant = MessageFlags(rawValue: 1 << 0)
}

/// Inner message inside a decrypted transport payload (ADR-0011 §1.2):
/// `channel(1) | msgType(2) | flags(1) | len(varint) | body`.
/// One payload may hold several messages back to back.
public struct InnerMessage: Equatable, Sendable {
    public var channel: Channel
    public var type: MessageType
    public var flags: MessageFlags
    public var body: [UInt8]

    public init(channel: Channel, type: MessageType, flags: MessageFlags = [], body: [UInt8]) {
        self.channel = channel
        self.type = type
        self.flags = flags
        self.body = body
    }

    public func encode(into w: inout ByteWriter) {
        w.u8(channel.rawValue)
        w.u16(type.rawValue)
        w.u8(flags.rawValue)
        w.lengthPrefixed(body)
    }

    public var encoded: [UInt8] {
        var w = ByteWriter(capacity: body.count + 8)
        encode(into: &w)
        return w.bytes
    }

    public static func decode(from r: inout ByteReader) throws -> InnerMessage {
        let channel = Channel(rawValue: try r.u8())
        let type = MessageType(rawValue: try r.u16())
        let flags = MessageFlags(rawValue: try r.u8())
        let body = try r.lengthPrefixed()
        return InnerMessage(channel: channel, type: type, flags: flags, body: body)
    }

    public static func decodeAll(_ payload: [UInt8]) throws -> [InnerMessage] {
        var r = ByteReader(payload)
        var out: [InnerMessage] = []
        while !r.isAtEnd { out.append(try decode(from: &r)) }
        return out
    }

    public static func encodeAll(_ messages: [InnerMessage]) -> [UInt8] {
        var w = ByteWriter(capacity: messages.reduce(0) { $0 + $1.body.count + 8 })
        for m in messages { m.encode(into: &w) }
        return w.bytes
    }
}

/// Every concrete message type conforms; `channel`/`type` route it, `encodeBody`/`init(body:)` are
/// covered by golden-byte fixtures (shared/Tests/ClamshellWireTests/Fixtures).
public protocol WireMessage: Equatable, Sendable {
    static var channel: Channel { get }
    static var type: MessageType { get }
    func encodeBody() -> [UInt8]
    init(body: [UInt8]) throws
}

extension WireMessage {
    public var message: InnerMessage { InnerMessage(channel: Self.channel, type: Self.type, body: encodeBody()) }

    public init(_ m: InnerMessage) throws {
        guard m.type == Self.type else { throw WireError.invalidValue("expected \(Self.type), got \(m.type)") }
        try self.init(body: m.body)
    }
}
