import ClamshellStream
import ClamshellWire
import CoreMedia
import Foundation
import ScreenCaptureKit

/// The Mac's system audio for the phone (M5): ScreenCaptureKit audio (this app's own sounds excluded)
/// → 20 ms Opus packets → `send`. Its own SCStream on the main display, so a posture change that rebuilds
/// the virtual display leaves it alone. `CLAMSHELL_TEST_TONE=1` replaces capture with a 440 Hz tone
/// (no Screen Recording needed), for tests.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias Send = @Sendable ([AudioPacket]) -> Void

    private let queue = DispatchQueue(label: "clamshell.audio", qos: .userInteractive)
    private let encoder: OpusEncoder
    private let send: Send
    private var stream: SCStream?
    private var toneTimer: DispatchSourceTimer?
    private(set) var packetsSent = 0

    init(send: @escaping Send) throws {
        encoder = try OpusEncoder()
        self.send = send
    }

    func start() async throws {
        if ProcessInfo.processInfo.environment["CLAMSHELL_TEST_TONE"] == "1" { startTone(); return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = Int(AudioFormat.sampleRate)
        cfg.channelCount = Int(AudioFormat.channels)
        // Video is required by SCK but unused here: as small and slow as it goes.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 1
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        toneTimer?.cancel()
        toneTimer = nil
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sample.isValid, let planar = Self.planar(sample) else { return }
        let pts = sample.presentationTimeStamp
        let captureNs = pts.isValid ? UInt64(max(0, pts.seconds) * 1e9) : HostClock.nowNs()
        emit(encoder.encode(planar: planar, captureNs: captureNs))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        print("audio: capture stopped: \(error.localizedDescription)")
    }

    private func emit(_ packets: [AudioPacket]) {
        guard !packets.isEmpty else { return }
        packetsSent += packets.count
        send(packets)
    }

    /// Float32 samples, one array per channel, from an SCK audio buffer (planar or interleaved).
    static func planar(_ sample: CMSampleBuffer) -> [[Float]]? {
        guard let fd = sample.formatDescription, let asbd = fd.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        var out: [[Float]]?
        try? sample.withAudioBufferList { list, _ in
            if interleaved, let b = list.first, let data = b.mData {
                let n = Int(b.mDataByteSize) / 4 / max(channels, 1)
                let p = data.assumingMemoryBound(to: Float.self)
                out = (0..<channels).map { c in (0..<n).map { p[$0 * channels + c] } }
            } else {
                out = list.compactMap { b in
                    guard let data = b.mData else { return nil }
                    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(b.mDataByteSize) / 4))
                }
            }
        }
        return out?.isEmpty == false ? out : nil
    }

    private func startTone() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        var phase = 0.0
        let chunk = 480                                      // 10 ms
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            var s = [Float](repeating: 0, count: chunk)
            for i in s.indices { s[i] = Float(sin(phase) * 0.3); phase += 2 * .pi * 440 / AudioFormat.sampleRate }
            self.emit(self.encoder.encode(planar: [s, s], captureNs: HostClock.nowNs()))
        }
        t.resume()
        toneTimer = t
    }
}
