/// One Opus packet of the Mac's system audio (M5, protocol 1.5): 20 ms of 48 kHz stereo.
/// Unreliable and never retransmitted: a late packet is worse than a gap.
public struct AudioPacket: WireMessage {
    public static let channel = Channel.audio
    public static let type = MessageType.audioPacket

    /// Counts packets from 0; a jump is loss, a step back a reordered (stale) packet.
    public var seq: UInt32
    /// The Mac's capture time of the first sample (HostClock ns), for drift and latency checks.
    public var captureNs: UInt64
    public var data: [UInt8]

    public init(seq: UInt32, captureNs: UInt64, data: [UInt8]) {
        self.seq = seq
        self.captureNs = captureNs
        self.data = data
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(seq))
        t.uint(2, captureNs)
        t.bytes(3, data)
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3])
        let s = try t.requiredUInt(1)
        guard s <= UInt64(UInt32.max) else { throw WireError.invalidValue("seq \(s)") }
        seq = UInt32(s)
        captureNs = try t.requiredUInt(2)
        data = try t.requiredBytes(3)
        guard !data.isEmpty, data.count <= 1500 else { throw WireError.invalidValue("opus packet of \(data.count) bytes") }
    }
}
