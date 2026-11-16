import ClamshellRateControl
import ClamshellSession
import ClamshellStream
import ClamshellVideo
import ClamshellWire
import CoreVideo
import Foundation
import Synchronization

/// Harness D (docs/video.md §2): how fast does static text get sharp after a scroll stops?
/// Runs the real host and client pipelines in-process (no network), scrolls for 0.5 s at 120 Hz, then
/// holds the screen still for 700 ms the way SCK reports it (undamaged captures), and records every
/// decoded picture's luma PSNR against the source. "Refined" = a refinement picture at ≥ `target` dB
/// (default 45 dB: 1 px text edges intact on the test pattern; motion frames sit near 26 dB).
enum TextRefine {
    struct Sample { let ms: Double; let frameId: UInt32; let refinement: Bool; let psnr: Double; let bytes: Int }

    static func run(width: Int, height: Int, bitrateMbps: Int, target: Double = 45) {
        let stageSets: [(String, [RefinementScheduler.Stage])] = [
            ("default 120 ms QP≤18, 400 ms QP≤12", RefinementScheduler.defaultStages),
            ("120 ms QP≤12", [.init(delay: .milliseconds(120), maxQP: 12)]),
            ("60 ms QP≤12", [.init(delay: .milliseconds(60), maxQP: 12)]),
        ]
        print("# clamshell-bench text-refine — \(width)×\(height), \(bitrateMbps) Mbit/s, low-latency RC")
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            for (label, stages) in stageSets {
                do { try await once(label: label, stages: stages, width: width, height: height, bitrate: bitrateMbps * 1_000_000, target: target) }
                catch { print("\(label): failed — \(error)") }
            }
            sem.signal()
        }
        sem.wait()
    }

    static func once(label: String, stages: [RefinementScheduler.Stage], width: Int, height: Int, bitrate: Int, target: Double) async throws {
        var cfg = EncoderConfig(width: width, height: height)
        cfg.averageBitrate = bitrate
        let hostBox = Mutex<HostVideoPipeline?>(nil)
        let sizes = Mutex<[UInt32: Int]>([:])
        let client = ClientVideoPipeline { _ in hostBox.withLock { $0 }?.requestKeyframe() }
        let host = try HostVideoPipeline(config: cfg, refinement: stages, sessionOverhead: SecureSession.overhead) { payloads, id, _ in
            sizes.withLock { $0[id] = payloads.reduce(0) { $0 + $1.count } }
            var messages: [InnerMessage] = []
            for p in payloads { if let m = try? InnerMessage.decodeAll(p) { messages += m } }
            client.handle(messages)
        }
        hostBox.withLock { $0 = host }
        host.start(); client.start()
        defer { host.stop(); client.stop() }

        let scrollFrames = 60
        var sources: [CVPixelBuffer] = []
        for i in 0..<scrollFrames {
            guard let b = TestPattern.pixelBuffer(width: width, height: height, phase: i * 3, cursorOn: true) else { throw ProbeError("pattern") }
            sources.append(b)
        }
        let still = SharedPixelBuffer(sources[scrollFrames - 1])
        for (i, b) in sources.enumerated() {
            host.submit(SharedPixelBuffer(b), captureTimeNs: UInt64(i), damaged: true)
            try await Task.sleep(for: .microseconds(8333))
        }
        let stop = ContinuousClock.now
        let converter = try PixelConverter()
        var samples: [Sample] = []
        var seen = Set<UInt32>()
        var nextCapture = stop
        while ContinuousClock.now - stop < .milliseconds(700) {
            if ContinuousClock.now >= nextCapture {                 // SCK keeps reporting the unchanged screen
                host.submit(still, captureTimeNs: UInt64(scrollFrames), damaged: false)
                nextCapture += .microseconds(8333)
            }
            if let pic = client.latest.take(), !seen.contains(pic.frameId), pic.captureTimeNs == UInt64(scrollFrames - 1) {
                seen.insert(pic.frameId)
                let rgb = try converter.convert(pic.pixelBuffer, to: kCVPixelFormatType_32BGRA)
                let t = pic.decodedAt - stop
                let ms = Double(t.components.seconds) * 1000 + Double(t.components.attoseconds) / 1e15
                samples.append(Sample(ms: ms, frameId: pic.frameId, refinement: pic.flags.contains(.refinement),
                                      psnr: PixelCompare.lumaPSNR(rgb, still.buffer) ?? 0,
                                      bytes: sizes.withLock { $0[pic.frameId] } ?? 0))
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let hs = host.currentStats
        print("\n## stages: \(label)")
        print("host: \(hs.framesSent) frames, \(hs.refinements) refinements, \(hs.encoderDrops) encoder drops, \(hs.skippedWhileBusy) skipped while busy, \(hs.refinementRetries) refinement retries")
        guard let best = samples.map(\.psnr).max() else { print("no picture of the final screen decoded"); return }
        for s in samples {
            print(String(format: "  +%6.1f ms  frame %4u  %@  PSNR %.2f dB  %6.1f KB", s.ms, s.frameId,
                         s.refinement ? "refine" : "motion", s.psnr, Double(s.bytes) / 1024))
        }
        let refined = samples.first { $0.refinement && $0.psnr >= target }
        let first = samples.first
        let verdict = refined.map { $0.ms <= 150 ? "PASS (≤ 150 ms)" : "FAIL (> 150 ms)" } ?? "FAIL (never reached \(target) dB)"
        print(String(format: "first picture of the final screen: +%.1f ms at %.2f dB; best %.2f dB; refined to ≥ %.0f dB at +%.1f ms → %@",
                     first?.ms ?? -1, first?.psnr ?? 0, best, target, refined?.ms ?? -1, verdict))
    }
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
