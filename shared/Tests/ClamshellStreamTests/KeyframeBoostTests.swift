import ClamshellSession
import ClamshellVideo
import Foundation
import Synchronization
import Testing
@testable import ClamshellStream

/// A keyframe at a low target must not cost the frames after it (real VideoToolbox). With low-latency rate
/// control the encoder pays a keyframe back by dropping the next frames: at 4 Mbit/s and 2670×1734 4:4:4
/// the M5 dropped 19–33 of them per keyframe, the "dropped N encoder" bursts in the host log.
@Suite("Keyframe boost (real VideoToolbox)", .serialized, .timeLimit(.minutes(1)))
struct KeyframeBoostTests {
    /// Encoder drops over 90 frames of a nearly still screen (a blinking caret) with keyframes at 30 and 60.
    func drops(width w: Int, height h: Int, is444: Bool, target: Int, ceiling: Int?) async throws -> (drops: Int, keyframes: Int) {
        var cfg = EncoderConfig(width: w, height: h)
        cfg.averageBitrate = target
        if is444 { cfg.profile = .named("HEVC_Main444_AutoLevel") }
        let host = try HostVideoPipeline(config: cfg, chroma: is444 ? .yuv444 : .yuv420, refinement: [],
                                         sessionOverhead: SecureSession.overhead, keyframeBitrateCeiling: ceiling) { _, _, _ in }
        let a = SharedPixelBuffer(try #require(TestPattern.pixelBuffer(width: w, height: h, cursorOn: true)))
        let b = SharedPixelBuffer(try #require(TestPattern.pixelBuffer(width: w, height: h, cursorOn: false)))
        host.start()
        for i in 0..<90 {
            if i == 30 || i == 60 { host.requestKeyframe() }
            host.submit(i % 2 == 0 ? a : b, captureTimeNs: UInt64(i), damaged: true)
            try await Task.sleep(for: .milliseconds(12))
        }
        try await Task.sleep(for: .milliseconds(100))
        let s = host.currentStats
        host.stop()
        return (s.encoderDrops, s.keyframes)
    }

    @Test func keyframesAtALowTargetDropNothing() async throws {
        let mac = try await drops(width: 2670, height: 1734, is444: true, target: 4_000_000, ceiling: 50_000_000)
        let away = try await drops(width: 1600, height: 1038, is444: false, target: 3_000_000, ceiling: 50_000_000)
        let unboosted = try await drops(width: 2670, height: 1734, is444: true, target: 4_000_000, ceiling: nil)
        print("keyframe boost: drops \(mac.drops) (mirroring, 4 Mbit/s), \(away.drops) (away, 3 Mbit/s), \(unboosted.drops) without the boost")
        #expect(mac.keyframes >= 3 && away.keyframes >= 3)
        #expect(mac.drops == 0 && away.drops == 0)
    }

    @Test func boostRule() {
        let mac = HostVideoPipeline.keyframeBitrate(target: 4_000_000, width: 2670, height: 1734, ceiling: 50_000_000)
        #expect(mac >= 25_000_000 && mac <= 50_000_000)
        #expect(HostVideoPipeline.keyframeBitrate(target: 3_000_000, width: 1600, height: 1038, ceiling: 50_000_000) >= 12_000_000)
        #expect(HostVideoPipeline.keyframeBitrate(target: 40_000_000, width: 2670, height: 1734, ceiling: 50_000_000) == 50_000_000)
        #expect(HostVideoPipeline.keyframeBitrate(target: 60_000_000, width: 2670, height: 1734, ceiling: 50_000_000) == 60_000_000,
                "never below the target")
    }
}
