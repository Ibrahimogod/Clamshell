public enum VideoCodec: Equatable, Sendable {
    case hevc, h264
    case unknown(UInt64)

    init(raw: UInt64) {
        switch raw {
        case 1: self = .hevc
        case 2: self = .h264
        default: self = .unknown(raw)
        }
    }

    var raw: UInt64 {
        switch self {
        case .hevc: 1
        case .h264: 2
        case .unknown(let v): v
        }
    }
}

public enum ChromaFormat: Equatable, Sendable {
    case yuv420, yuv422, yuv444
    case unknown(UInt64)

    init(raw: UInt64) {
        switch raw {
        case 0: self = .yuv420
        case 1: self = .yuv422
        case 2: self = .yuv444
        default: self = .unknown(raw)
        }
    }

    var raw: UInt64 {
        switch self {
        case .yuv420: 0
        case .yuv422: 1
        case .yuv444: 2
        case .unknown(let v): v
        }
    }
}

/// Decoder configuration. Sent before the first keyframe of each format `generation` and repeated
/// with every keyframe (it's small), so a client that lost it can recover from the next keyframe.
public struct VideoFormat: WireMessage {
    public static let channel = Channel.video
    public static let type = MessageType.videoFormat

    public var generation: UInt16
    public var codec: VideoCodec
    public var widthPixels: UInt32
    public var heightPixels: UInt32
    public var chroma: ChromaFormat
    public var fullRange: Bool
    /// HEVC: VPS, SPS, PPS in order (no start codes). H.264: SPS, PPS.
    public var parameterSets: [[UInt8]]

    public init(generation: UInt16, codec: VideoCodec, widthPixels: UInt32, heightPixels: UInt32,
                chroma: ChromaFormat, fullRange: Bool, parameterSets: [[UInt8]]) {
        self.generation = generation
        self.codec = codec
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.chroma = chroma
        self.fullRange = fullRange
        self.parameterSets = parameterSets
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(generation))
        t.uint(2, codec.raw)
        t.uint(3, UInt64(widthPixels))
        t.uint(4, UInt64(heightPixels))
        t.uint(5, chroma.raw)
        t.bool(6, fullRange)
        for ps in parameterSets { t.bytes(7, ps) }
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4, 5, 6, 7])
        generation = try t.requiredUInt(1).narrowed(to: UInt16.self, field: "generation")
        codec = VideoCodec(raw: try t.requiredUInt(2))
        widthPixels = try t.requiredUInt(3).narrowed(to: UInt32.self, field: "width")
        heightPixels = try t.requiredUInt(4).narrowed(to: UInt32.self, field: "height")
        chroma = ChromaFormat(raw: try t.optionalUInt(5) ?? 0)
        fullRange = (try t.optionalUInt(6) ?? 0) != 0
        parameterSets = t.all(7)
        guard !parameterSets.isEmpty else { throw WireError.missingField(tag: 7) }
    }
}

public struct VideoFrameFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let keyframe = VideoFrameFlags(rawValue: 1 << 0)
    /// A re-encode of an unchanged picture at low QP to sharpen static text (ADR-0008 §3).
    public static let refinement = VideoFrameFlags(rawValue: 1 << 1)
    public static let longTermReference = VideoFrameFlags(rawValue: 1 << 2)
    /// 1.1 (`fecXor`): an XOR parity fragment. `index` is the group number and `count` the frame's number of
    /// data fragments. Payload: `groupSize u8 | xor of the group's payload lengths u16 | xor of the payloads`.
    public static let parity = VideoFrameFlags(rawValue: 1 << 3)
}

/// One piece of an encoded frame. Hot path, so a fixed layout instead of TLVs:
/// `frameId u32 | index u16 | count u16 | flags u8 | formatGeneration u16 | captureTimeNs u64 | payload`.
/// A new layout would get a new `MessageType` (e.g. `videoFragment.v2`).
public struct VideoFragment: WireMessage {
    public static let channel = Channel.video
    public static let type = MessageType.videoFragment
    public static let headerSize = 4 + 2 + 2 + 1 + 2 + 8

    public var frameId: UInt32
    public var index: UInt16
    public var count: UInt16
    public var flags: VideoFrameFlags
    public var formatGeneration: UInt16
    /// Mac monotonic capture time (ns). Lets the client compute capture→present latency.
    public var captureTimeNs: UInt64
    public var payload: [UInt8]

    public init(frameId: UInt32, index: UInt16, count: UInt16, flags: VideoFrameFlags,
                formatGeneration: UInt16, captureTimeNs: UInt64, payload: [UInt8]) {
        self.frameId = frameId
        self.index = index
        self.count = count
        self.flags = flags
        self.formatGeneration = formatGeneration
        self.captureTimeNs = captureTimeNs
        self.payload = payload
    }

    public func encodeBody() -> [UInt8] {
        var w = ByteWriter(capacity: Self.headerSize + payload.count)
        w.u32(frameId)
        w.u16(index)
        w.u16(count)
        w.u8(flags.rawValue)
        w.u16(formatGeneration)
        w.u64(captureTimeNs)
        w.raw(payload)
        return w.bytes
    }

    public init(body: [UInt8]) throws {
        var r = ByteReader(body)
        frameId = try r.u32()
        index = try r.u16()
        count = try r.u16()
        flags = VideoFrameFlags(rawValue: try r.u8())
        formatGeneration = try r.u16()
        captureTimeNs = try r.u64()
        payload = r.rest()
        guard count > 0, index < count else { throw WireError.invalidValue("fragment \(index)/\(count)") }
    }
}
