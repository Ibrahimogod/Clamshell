import AVFAudio
import ClamshellStream
import ClamshellWire
import CoreAudio
import Synchronization

/// The phone's microphone on the Mac (1.1): its Opus packets are decoded and played into the
/// "Clamshell Microphone" device, a loopback audio driver (mac-host/Driver, installed with
/// tools/scripts/install-microphone.sh). Whatever plays into the device comes out of its input, which is what
/// apps record from. Without the driver there is nowhere to play, so the player isn't made at all (never the
/// Mac's speakers). Same jitter rule as the phone's player: start at 40 ms queued, drop over 120 ms.
final class MicPlayer: Sendable {
    /// The driver's device UID (mac-host/Driver/ClamshellMicrophone.c).
    static let deviceUID = "ClamshellMicrophone_UID"

    private struct State {
        var decoder: OpusDecoder?
        var policy = AudioJitterPolicy()
        var queuedFrames = 0
        var played = 0
    }
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let state = Mutex(State())
    private let running = Atomic<Bool>(false)

    /// The driver's device, if it's installed and loaded.
    static var deviceID: AudioDeviceID? {
        var uid = deviceUID as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &uid) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), p, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static var deviceAvailable: Bool { deviceID != nil }

    enum MicError: Error, CustomStringConvertible {
        case noDevice
        var description: String { "the Clamshell Microphone driver isn't installed (tools/scripts/install-microphone.sh)" }
    }

    init() throws {
        guard let device = Self.deviceID else { throw MicError.noDevice }
        guard let format = AudioFormat.pcm else { throw AudioError.formatUnavailable }
        let decoder = try OpusDecoder()
        state.withLock { $0.decoder = decoder }
        try engine.outputNode.auAudioUnit.setDeviceID(device)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        running.store(true, ordering: .relaxed)
    }

    func handle(_ p: AudioPacket) {
        guard running.load(ordering: .relaxed) else { return }
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
        let play: Bool = state.withLock { s in s.policy.shouldPlay(queuedMs: Double(s.queuedFrames) / AudioFormat.sampleRate * 1000) }
        if play, !node.isPlaying { node.play() }
    }

    var played: Int { state.withLock { $0.played } }

    func stop() {
        running.store(false, ordering: .relaxed)
        node.stop()
        engine.stop()
    }
}
