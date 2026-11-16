import ClamshellRateControl
import ClamshellSession
import ClamshellVideo
import ClamshellWire
import CoreVideo
import Foundation
import Synchronization
import Testing
@testable import ClamshellStream

/// The remote-path pieces through the real pipelines: FEC, the keyframe throttle, receiver reports.
/// Nested in no other suite, so it may run beside `StreamTests`: assertions don't assume an idle encoder.
@Suite("Stream pipelines on a lossy path", .serialized, .timeLimit(.minutes(1)))
struct RemotePathStreamTests {
    let base = StreamTests()

    @Test func fecRebuildsALostFragment() async throws {
        let link = Link()
        let host = try base.makeHost(link)
        host.setRate(bitrate: 10_000_000, parityGroup: 4)
        host.start()
        link.client.start()
        let src = try base.frames(4)
        link.dropFrame(1)                                   // the keyframe loses a fragment
        link.dropFrame(3)
        for f in src {
            host.submit(f, captureTimeNs: 0, damaged: true)
            try await Task.sleep(for: .milliseconds(30))
        }
        // A busy encoder may replace a frame (never queue), so compare with what was actually sent.
        try await Task.sleep(for: .milliseconds(200))
        let sent = host.currentStats.framesSent
        #expect(sent >= 2)
        #expect(await base.waitUntil { link.client.currentStats.framesDecoded == sent })
        #expect(link.client.currentStats.framesLost == 0)
        #expect(link.client.currentStats.keyframeRequests == 1, "only the session-start request")
        #expect(host.currentStats.keyframes == 1)
        #expect(host.currentStats.parityGroup == 4)
        host.stop(); link.client.stop()
    }

    /// A slow (paced) sender holds encoding back instead of dropping encoded frames: nothing reaches the
    /// network out of chain, and the newest capture goes out once the sender confirms.
    @Test func sendBacklogHoldsEncodingBack() async throws {
        let handed = Mutex(0)
        let host = try HostVideoPipeline(config: { var c = EncoderConfig(width: base.w, height: base.h); c.averageBitrate = 10_000_000; return c }(),
                                         refinement: [], sessionOverhead: SecureSession.overhead, maxUnsentFrames: 1) { _, _, _ in
            handed.withLock { $0 += 1 }
        }
        host.start()
        let src = try base.frames(6)
        for f in src {
            host.submit(f, captureTimeNs: 0, damaged: true)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(handed.withLock { $0 } == 1)               // the sender never confirmed the first frame
        #expect(host.currentStats.skippedSendBacklog >= 4)
        host.frameSent()
        #expect(await base.waitUntil { handed.withLock { $0 } == 2 })   // the newest waiting capture, not a replay
        try await Task.sleep(for: .milliseconds(100))
        #expect(handed.withLock { $0 } == 2)
        host.stop()
    }

    @Test func keyframeRequestStormIsThrottled() async throws {
        let link = Link()
        let host = try HostVideoPipeline(config: { var c = EncoderConfig(width: base.w, height: base.h); c.averageBitrate = 10_000_000; return c }(),
                                         refinement: [], sessionOverhead: SecureSession.overhead,
                                         minKeyframeInterval: .milliseconds(300)) { p, id, key in link.deliver(p, frameId: id, isKeyframe: key) }
        link.attach(host)
        host.start()
        let src = try base.frames(1)
        host.submit(src[0], captureTimeNs: 0, damaged: true)
        #expect(await base.waitUntil { host.currentStats.keyframes == 1 })
        for _ in 0..<10 {                                   // a new request every 20 ms, each claiming a real loss
            host.requestKeyframe(lastGoodFrameId: 1)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(host.currentStats.keyframes == 1)
        #expect(host.currentStats.throttledKeyframes >= 5)
        #expect(await base.waitUntil { host.currentStats.keyframes == 2 })   // served once the interval passed
        try await Task.sleep(for: .milliseconds(400))
        #expect(host.currentStats.keyframes == 2)
        host.stop()
    }

    @Test func clientSendsReceiverReports() async throws {
        let reports = Mutex<[ReceiverReport]>([])
        let client = ClientVideoPipeline(requestKeyframe: { _ in }, sendReport: { r in reports.withLock { $0.append(r) } })
        client.setRoundTrip(nanoseconds: 42_000_000)
        client.start()
        let f = Fragmenter(maxFragmentPayload: 100)
        for id: UInt32 in [1, 2, 4] {
            let frags = try f.fragments(frameId: id, flags: id == 1 ? .keyframe : [], formatGeneration: 1, captureTimeNs: UInt64(id) * 16_000_000,
                                        data: Array(repeating: 7, count: 250))
            client.handle(frags.map(\.message))
        }
        try await Task.sleep(for: .milliseconds(350))
        client.stop()
        let all = reports.withLock { $0 }
        #expect(all.count >= 2)
        #expect(all.reduce(0) { $0 + Int($1.framesCompleted) } == 3)
        #expect(all.reduce(0) { $0 + Int($1.framesLost) } == 1)
        #expect(all.reduce(0) { $0 + Int($1.fragmentsExpected) } == 9)
        #expect(all.last?.highestFrameId == 4)
        #expect(all.last?.rttMicros == 42_000)
    }
}
