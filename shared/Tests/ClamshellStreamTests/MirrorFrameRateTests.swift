import ClamshellSession
import ClamshellVideo
import Foundation
import Synchronization
import Testing
@testable import ClamshellStream

/// Frames per second the host pipeline delivers for a screen that changes every 120 Hz refresh, at the
/// mirroring size (2670×1734 4:4:4, real VideoToolbox). The 4:4:4 path converts each frame before encoding.
/// Part of the serialized stream suite: it keeps the encoder busy, and other real-encoder tests would starve.
extension StreamTests {
    static func mirrorFps(width w: Int, height h: Int, is444: Bool, seconds: Double = 2) async throws -> (fps: Double, busy: Int, drops: Int) {
        var cfg = EncoderConfig(width: w, height: h)
        cfg.averageBitrate = 50_000_000
        if is444 { cfg.profile = .named("HEVC_Main444_AutoLevel") }
        let frames = Atomic<Int>(0)
        let host = try HostVideoPipeline(config: cfg, chroma: is444 ? .yuv444 : .yuv420, refinement: [],
                                         sessionOverhead: SecureSession.overhead) { _, _, _ in frames.add(1, ordering: .relaxed) }
        var buffers: [SharedPixelBuffer] = []
        for p in 0..<8 { buffers.append(SharedPixelBuffer(try #require(TestPattern.pixelBuffer(width: w, height: h, phase: p * 7)))) }
        host.start()
        let n = Int(seconds * 120)
        let start = ContinuousClock.now
        for i in 0..<n {
            host.submit(buffers[i % 8], captureTimeNs: UInt64(i), damaged: true)
            try await Task.sleep(until: start + .nanoseconds(Int64(i + 1) * 8_333_333), clock: .continuous)
        }
        let s = host.currentStats
        let delivered = frames.load(ordering: .relaxed)
        host.stop()
        return (Double(delivered) / seconds, s.skippedWhileBusy, s.encoderDrops)
    }

    @Test func mirroringKeepsUp() async throws {
        let r = try await Self.mirrorFps(width: 2670, height: 1734, is444: true)
        print("mirror frame rate: \(Int(r.fps)) fps (screen at 120) · \(r.busy) skipped while busy · \(r.drops) encoder drops")
        #expect(r.drops == 0)
        // Alone on the M5: 79–89 fps with the conversion overlapping the encode, 69–71 without. Other test
        // targets share the media engine in a full run (both about 66 then), so only a floor is checked here.
        #expect(r.fps >= 50)
    }
}
