import AVFAudio
import ClamshellStream
import ClamshellWire
import Synchronization

/// The Mac's sound on the phone (M5): Opus packets → `OpusDecoder` → an `AVAudioPlayerNode`, behind the
/// `AudioJitterPolicy` (starts at 40 ms queued, drops while over 120 ms), so audio never adds latency.
/// Called from the connection's receive task; everything it touches is behind one lock.
///
/// With `microphone` (1.1) the same engine also records: voice processing on, so the Mac's sound coming out
/// of the speaker is cancelled from what the microphone hears; 20 ms Opus packets go to `microphone`.
final class AudioPlayer: Sendable {
    private struct State {
        var decoder: OpusDecoder?
        var policy = AudioJitterPolicy()
        var queuedFrames = 0
        var played = 0
    }
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let state = Mutex(State())
    nonisolated(unsafe) private var running = false

    init(microphone: (@Sendable ([AudioPacket]) -> Void)? = nil) throws {
        let session = AVAudioSession.sharedInstance()
        if microphone != nil {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
        } else {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        guard let format = AudioFormat.pcm else { throw AudioError.formatUnavailable }
        let decoder = try OpusDecoder()
        state.withLock { $0.decoder = decoder }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if let microphone { try Self.record(engine, send: microphone) }
        engine.prepare()
        try engine.start()
        running = true
    }

    /// The microphone, voice-processed, at 48 kHz → Opus (48 kbit/s is plenty for speech).
    private static func record(_ engine: AVAudioEngine, send: @escaping @Sendable ([AudioPacket]) -> Void) throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let from = input.outputFormat(forBus: 0)
        guard from.sampleRate > 0, let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFormat.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: from, to: mono) else { throw AudioError.formatUnavailable }
        let encoder = try OpusEncoder(bitRate: 48_000)
        let mic = MicEncoder(converter: converter, encoder: encoder, format: mono)
        input.installTap(onBus: 0, bufferSize: 960, format: from) { buffer, _ in
            let packets = mic.encode(buffer)
            if !packets.isEmpty { send(packets) }
        }
    }

    var muted: Bool {
        get { engine.mainMixerNode.outputVolume == 0 }
        set { engine.mainMixerNode.outputVolume = newValue ? 0 : 1 }
    }

    var stats: (played: Int, lost: Int, dropped: Int, queuedMs: Double) {
        state.withLock { ($0.played, $0.policy.lost, $0.policy.dropped, Double($0.queuedFrames) / AudioFormat.sampleRate * 1000) }
    }

    func handle(_ p: AudioPacket) {
        guard running else { return }
        let buffer: AVAudioPCMBuffer? = state.withLock { s in
            let queuedMs = Double(s.queuedFrames) / AudioFormat.sampleRate * 1000
            guard s.policy.admit(seq: p.seq, queuedMs: queuedMs) == .play, let pcm = s.decoder?.decode(p.data) else { return nil }
            s.queuedFrames += Int(pcm.frameLength)
            s.played += 1
            return pcm
        }
        guard let buffer else { return }
        let frames = Int(buffer.frameLength)
        node.scheduleBuffer(buffer) { [weak self] in
            self?.state.withLock { $0.queuedFrames -= frames }
        }
        let play: Bool = state.withLock { s in
            s.policy.shouldPlay(queuedMs: Double(s.queuedFrames) / AudioFormat.sampleRate * 1000)
        }
        if play, !node.isPlaying { node.play() }
    }

    func stop() {
        running = false
        engine.inputNode.removeTap(onBus: 0)
        node.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// Microphone buffers (any rate) → 48 kHz mono → Opus. The tap calls it on one thread at a time.
private final class MicEncoder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let encoder: OpusEncoder
    private let format: AVAudioFormat

    init(converter: AVAudioConverter, encoder: OpusEncoder, format: AVAudioFormat) {
        self.converter = converter; self.encoder = encoder; self.format = format
    }

    func encode(_ buffer: AVAudioPCMBuffer) -> [AudioPacket] {
        let ratio = format.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, s in
            if given { s.pointee = .noDataNow; return nil }
            given = true
            s.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let ch = out.floatChannelData else { return [] }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        return encoder.encode(planar: [samples], captureNs: PhoneClock.nowNs())
    }
}
