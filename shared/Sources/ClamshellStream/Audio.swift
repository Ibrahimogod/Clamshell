import AVFAudio
import ClamshellWire

/// The audio format on both ends: 48 kHz stereo float, Opus packets of 20 ms (docs/video.md §5).
public enum AudioFormat {
    public static let sampleRate = 48_000.0
    public static let channels: AVAudioChannelCount = 2
    public static let framesPerPacket: AVAudioFrameCount = 960

    public static var pcm: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
    }

    public static var opus: AVAudioFormat? {
        var d = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                            mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
                                            mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &d)
    }
}

public enum AudioError: Error { case formatUnavailable, codecUnavailable }

/// PCM in any chunk size → 20 ms Opus packets. Not thread-safe: call it from one queue.
public final class OpusEncoder: @unchecked Sendable {
    private let pcm: AVAudioFormat
    private let opus: AVAudioFormat
    private let converter: AVAudioConverter
    private var fifo: [[Float]]
    private var fifoStartNs: UInt64?
    private var seq: UInt32 = 0

    public init(bitRate: Int = 96_000) throws {
        guard let pcm = AudioFormat.pcm, let opus = AudioFormat.opus else { throw AudioError.formatUnavailable }
        guard let c = AVAudioConverter(from: pcm, to: opus) else { throw AudioError.codecUnavailable }
        c.bitRate = bitRate
        self.pcm = pcm
        self.opus = opus
        converter = c
        fifo = Array(repeating: [], count: Int(AudioFormat.channels))
    }

    /// Appends planar samples (one array per channel, mono is duplicated) captured at `captureNs`, and
    /// returns every whole packet that is now ready.
    public func encode(planar: [[Float]], captureNs: UInt64) -> [AudioPacket] {
        guard let first = planar.first, !first.isEmpty else { return [] }
        if fifoStartNs == nil || fifo[0].isEmpty {
            fifoStartNs = captureNs &- UInt64(Double(fifo[0].count) / AudioFormat.sampleRate * 1e9)
        }
        for c in 0..<fifo.count { fifo[c].append(contentsOf: planar[min(c, planar.count - 1)]) }
        var out: [AudioPacket] = []
        let n = Int(AudioFormat.framesPerPacket)
        while fifo[0].count >= n {
            let startNs = fifoStartNs ?? captureNs
            if let data = encodeOne(n) { out.append(AudioPacket(seq: seq, captureNs: startNs, data: data)); seq &+= 1 }
            for c in 0..<fifo.count { fifo[c].removeFirst(n) }
            fifoStartNs = startNs &+ UInt64(Double(n) / AudioFormat.sampleRate * 1e9)
        }
        return out
    }

    private func encodeOne(_ n: Int) -> [UInt8]? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(n)), let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        for c in 0..<fifo.count { fifo[c].withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            ch[c].update(from: base, count: n)
        } }
        let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true
            s.pointee = .haveData
            return buf
        }
        guard status != .error, out.packetCount > 0, out.byteLength > 0 else { return nil }
        let bytes = UnsafeRawBufferPointer(start: out.data, count: Int(out.byteLength))
        return [UInt8](bytes)
    }
}

/// Opus packets → PCM buffers. Not thread-safe: call it from one queue.
public final class OpusDecoder: @unchecked Sendable {
    public let pcm: AVAudioFormat
    private let opus: AVAudioFormat
    private let converter: AVAudioConverter

    public init() throws {
        guard let pcm = AudioFormat.pcm, let opus = AudioFormat.opus else { throw AudioError.formatUnavailable }
        guard let c = AVAudioConverter(from: opus, to: pcm) else { throw AudioError.codecUnavailable }
        self.pcm = pcm
        self.opus = opus
        converter = c
    }

    public func decode(_ packet: [UInt8]) -> AVAudioPCMBuffer? {
        let input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            input.data.copyMemory(from: base, byteCount: packet.count)
        }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AudioFormat.framesPerPacket * 2) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, s in
            if given { s.pointee = .noDataNow; return nil }
            given = true
            s.pointee = .haveData
            return input
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}

/// The phone's small jitter buffer as a rule (M5): audio must never add latency, so it starts once
/// `startMs` is queued and drops packets while more than `maxMs` is queued, rather than falling behind.
public struct AudioJitterPolicy: Sendable, Equatable {
    public static let startMs = 40.0
    public static let maxMs = 120.0
    /// Packets (20 ms each) a late packet may trail by; a bigger step back is a new stream.
    public static let restartGap: UInt32 = 25

    public private(set) var playing = false
    private var lastSeq: UInt32?
    public private(set) var dropped = 0
    public private(set) var lost = 0

    public init() {}

    public enum Decision: Sendable, Equatable { case play, drop }

    /// A packet arrived with `queuedMs` of audio already scheduled ahead of the speaker.
    public mutating func admit(seq: UInt32, queuedMs: Double) -> Decision {
        if let last = lastSeq {
            let ahead = seq &- last
            let behind = last &- seq
            // A few packets back is reordering (stale); further back is the Mac restarting its audio.
            if ahead == 0 || (ahead > UInt32.max / 2 && behind <= Self.restartGap) { dropped += 1; return .drop }
            if ahead > 1, ahead <= UInt32.max / 2 { lost += Int(ahead - 1) }
        }
        lastSeq = seq
        if queuedMs > Self.maxMs { dropped += 1; return .drop }
        return .play
    }

    /// Whether the player should be running, given what is queued (restarts after an underrun).
    public mutating func shouldPlay(queuedMs: Double) -> Bool {
        if !playing, queuedMs >= Self.startMs { playing = true }
        if playing, queuedMs <= 0 { playing = false }
        return playing
    }
}
