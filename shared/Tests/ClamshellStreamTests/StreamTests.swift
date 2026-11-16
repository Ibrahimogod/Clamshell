import ClamshellRateControl
import ClamshellSession
import ClamshellVideo
import ClamshellWire
import CoreVideo
import Foundation
import Synchronization
import Testing
@testable import ClamshellStream

/// In-process link between the pipelines: decodes each payload into inner messages like the transport
/// would, optionally dropping datagrams.
final class LinkState: Sendable {
    let state = Mutex<(drop: Set<UInt32>, sentFrames: [UInt32], keyframes: [UInt32], requests: [KeyframeRequest])>(([], [], [], []))
    let host = Mutex<HostVideoPipeline?>(nil)
}

final class Link: Sendable {
    private let shared = LinkState()
    let client: ClientVideoPipeline

    init() {
        let shared = self.shared
        client = ClientVideoPipeline { req in
            shared.state.withLock { $0.requests.append(req) }
            shared.host.withLock { $0 }?.requestKeyframe()
        }
    }

    func attach(_ host: HostVideoPipeline) { shared.host.withLock { $0 = host } }

    func dropFrame(_ id: UInt32) { shared.state.withLock { _ = $0.drop.insert(id) } }
    var sentFrames: [UInt32] { shared.state.withLock { $0.sentFrames } }
    var keyframes: [UInt32] { shared.state.withLock { $0.keyframes } }
    var requests: [KeyframeRequest] { shared.state.withLock { $0.requests } }

    func deliver(_ payloads: [[UInt8]], frameId: UInt32, isKeyframe: Bool) {
        let drop = shared.state.withLock { s -> Bool in
            s.sentFrames.append(frameId)
            if isKeyframe { s.keyframes.append(frameId) }
            return s.drop.contains(frameId)
        }
        // Drop one fragment in the middle (the frame can't complete), keep the rest.
        var messages: [InnerMessage] = []
        for (i, p) in payloads.enumerated() {
            if drop && i == payloads.count / 2 && payloads.count > 1 { continue }
            if let m = try? InnerMessage.decodeAll(p) { messages += m }
        }
        client.handle(messages)
    }
}

@Suite("Stream pipelines (real VideoToolbox, in-process link)", .serialized, .timeLimit(.minutes(1)))
struct StreamTests {
    let w = 640, h = 400

    func frames(_ n: Int) throws -> [SharedPixelBuffer] {
        try (0..<n).map { i in SharedPixelBuffer(try #require(TestPattern.pixelBuffer(width: w, height: h, phase: i, cursorOn: i % 2 == 0))) }
    }

    func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func makeHost(_ link: Link, refinement: [RefinementScheduler.Stage] = []) throws -> HostVideoPipeline {
        var cfg = EncoderConfig(width: w, height: h)
        cfg.averageBitrate = 10_000_000
        let host = try HostVideoPipeline(config: cfg, refinement: refinement, sessionOverhead: SecureSession.overhead) { payloads, id, key in
            link.deliver(payloads, frameId: id, isKeyframe: key)
        }
        link.attach(host)
        return host
    }

    @Test func framesFlowAndStayFresh() async throws {
        let link = Link()
        let host = try makeHost(link)
        host.start()
        link.client.start()
        let src = try frames(30)
        for (i, f) in src.enumerated() {
            host.submit(f, captureTimeNs: UInt64(i), damaged: true)
            try await Task.sleep(for: .milliseconds(8))
        }
        #expect(await waitUntil { link.client.currentStats.framesDecoded >= 20 })
        let hs = host.currentStats, cs = link.client.currentStats
        #expect(hs.keyframes == 1, "only the session-start keyframe: \(hs)")
        #expect(cs.framesLost == 0 && cs.decoderErrors == 0, "\(cs)")
        #expect(cs.framesDecoded == hs.framesSent, "every sent frame decoded: \(cs.framesDecoded) vs \(hs.framesSent)")
        #expect(hs.framesSent + hs.skippedWhileBusy + hs.encoderDrops >= 30 - 1, "nothing silently lost on the host")
        // The newest picture is the last submitted one (drop-never-queue).
        #expect(await waitUntil { link.client.latest.take()?.captureTimeNs == 29 })
        #expect(link.sentFrames == Array(1...UInt32(link.sentFrames.count)), "frame ids are contiguous")
        host.stop(); link.client.stop()
    }

    @Test func lossTriggersKeyframeAndRecovers() async throws {
        let link = Link()
        link.dropFrame(5)
        let host = try makeHost(link)
        host.start()
        link.client.start()
        let src = try frames(40)
        for (i, f) in src.enumerated() {
            host.submit(f, captureTimeNs: UInt64(i), damaged: true)
            try await Task.sleep(for: .milliseconds(8))
        }
        #expect(await waitUntil { link.keyframes.count >= 2 }, "a second keyframe was sent after the loss")
        #expect(link.requests.contains { $0.reason == .frameLost }, "\(link.requests)")
        let recovery = try #require(link.keyframes.dropFirst().first)
        #expect(recovery > 5)
        // Frames after the recovery keyframe decode again.
        #expect(await waitUntil { (link.client.latest.take()?.frameId ?? 0) > recovery || link.client.currentStats.framesDecoded > Int(recovery) })
        let cs = link.client.currentStats
        #expect(cs.decoderErrors == 0, "\(cs)")
        #expect(cs.skippedAwaitingKeyframe >= 0)
        host.stop(); link.client.stop()
    }

    @Test func staticScreenCostsNothingButRefines() async throws {
        let link = Link()
        let stages = [RefinementScheduler.Stage(delay: .milliseconds(60), maxQP: 18), .init(delay: .milliseconds(150), maxQP: 12)]
        let host = try makeHost(link, refinement: stages)
        host.start()
        link.client.start()
        let still = try frames(1)[0]
        host.submit(still, captureTimeNs: 1, damaged: true)
        for i in 0..<30 {                                   // 30 undamaged captures of the same screen
            host.submit(still, captureTimeNs: UInt64(2 + i), damaged: false)
            try await Task.sleep(for: .milliseconds(8))
        }
        #expect(await waitUntil { host.currentStats.refinements == 2 })
        let hs = host.currentStats
        #expect(hs.framesSent == 3, "1 keyframe + 2 refinements, nothing for idle captures: \(hs)")
        #expect(await waitUntil { link.client.currentStats.refinements == 2 })
    }

    @Test func formatGenerationsAndKeyframeOnRequest() async throws {
        let link = Link()
        let host = try makeHost(link)
        host.start()
        link.client.start()
        let src = try frames(4)
        host.submit(src[0], captureTimeNs: 0, damaged: true)
        #expect(await waitUntil { link.client.currentStats.framesDecoded >= 1 })
        host.requestKeyframe()                               // static screen: the last picture is re-sent as a keyframe
        #expect(await waitUntil { host.currentStats.keyframes >= 2 })
        #expect(await waitUntil { link.client.currentStats.keyframes >= 2 })
        host.stop(); link.client.stop()
    }

    @Test func staleKeyframeRequestsAreIgnored() async throws {
        let link = Link()
        let host = try makeHost(link)
        host.start()
        let src = try frames(2)
        host.submit(src[0], captureTimeNs: 0, damaged: true)
        #expect(await waitUntil { host.currentStats.keyframes == 1 })
        host.requestKeyframe(lastGoodFrameId: 0)            // sent before the client saw keyframe #1
        try await Task.sleep(for: .milliseconds(40))
        #expect(host.currentStats.keyframes == 1)
        #expect(host.currentStats.duplicateKeyframeRequests == 1)
        try await Task.sleep(for: .milliseconds(150))
        host.requestKeyframe(lastGoodFrameId: 0)            // still nothing good after 150 ms: a real loss
        #expect(await waitUntil { host.currentStats.keyframes == 2 })
        host.stop()
    }

    /// The 4:4:4 path end to end: BGRA input into HEVC_Main444 (found by the encode probe), decoded as 444v.
    @Test func chroma444EndToEnd() async throws {
        var cfg = EncoderConfig(width: w, height: h)
        cfg.profile = .named("HEVC_Main444_AutoLevel")
        let link = Link()
        let host = try HostVideoPipeline(config: cfg, chroma: .yuv444, refinement: [], sessionOverhead: SecureSession.overhead) { p, id, key in
            link.deliver(p, frameId: id, isKeyframe: key)
        }
        link.attach(host)
        host.start()
        link.client.start()
        let src = try frames(3)
        for (i, f) in src.enumerated() { host.submit(f, captureTimeNs: UInt64(i), damaged: true); try await Task.sleep(for: .milliseconds(10)) }
        #expect(await waitUntil { link.client.currentStats.framesDecoded >= 2 })
        let pic = try #require(link.client.latest.take())
        #expect(CVPixelBufferGetPixelFormatType(pic.pixelBuffer) == kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
        #expect(link.client.currentStats.chroma == .yuv444)
        host.stop(); link.client.stop()
    }
}
