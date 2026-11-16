import AVFAudio
import ClamshellStream
import ClamshellWire
import Synchronization

/// The Mac's sound on the phone (M5): Opus packets → `OpusDecoder` → an `AVAudioPlayerNode`, behind the
/// `AudioJitterPolicy` (starts at 40 ms queued, drops while over 120 ms), so audio never adds latency.
/// Called from the connection's receive task; everything it touches is behind one lock.
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

    init() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        guard let format = AudioFormat.pcm else { throw AudioError.formatUnavailable }
        let decoder = try OpusDecoder()
        state.withLock { $0.decoder = decoder }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        running = true
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
        node.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
