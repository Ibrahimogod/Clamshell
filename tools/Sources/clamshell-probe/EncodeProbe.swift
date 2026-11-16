import ClamshellCodec
import ClamshellVideo
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

final class Box<T: Sendable>: Sendable {
    private let items = Mutex<[T]>([])
    func append(_ x: T) { items.withLock { $0.append(x) } }
    func drain() -> [T] { items.withLock { let all = $0; $0.removeAll(); return all } }
}

/// Probe 1 (Mac half) and the encoder numbers for ADR-0007: what the M5 media engine will encode,
/// whether any 4:4:4 path exists, encode latency at the phone's resolution, frame sizes per content type.
enum EncodeProbe {
    static func run(_ args: Args) throws {
        let w = args.int("width", 1878), h = args.int("height", 1334)
        let frames = args.int("frames", 360)
        print("# clamshell-probe encode — \(w)×\(h)")
        print("hardware HEVC decode (this Mac): \(VideoDecoder.hardwareHEVCSupported)")
        let levels = VideoEncoder.supportedProfileLevels(width: w, height: h)
        print("hardware encoder ProfileLevel values (\(levels.count)):")
        for l in levels { print("  \(l)") }

        let converter = try PixelConverter()
        guard let source = TestPattern.pixelBuffer(width: w, height: h) else { throw ProbeFailure("test pattern") }

        print("\n## Profile / chroma attempts (one keyframe each, decoded back and compared with the BGRA source)")
        print("| profile | input | result | SPS profile_idc | chroma_format_idc | bytes | luma PSNR dB | colour fringe |")
        print("|---|---|---|---|---|---|---|---|")
        var candidates: [(String, HEVCProfile?, OSType)] = [
            ("Main", .main, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            ("Main", .main, kCVPixelFormatType_32BGRA),
            ("Main10", .main10, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            ("Main42210", .main42210, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
            ("Main42210", .main42210, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange),
            ("(default)", nil, kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange),
            ("(default)", nil, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange),
        ]
        for name in ["HEVC_Main444_AutoLevel", "HEVC_Main44410_AutoLevel", "HEVC_Main444_8_AutoLevel", "HEVC_RExt_AutoLevel",
                     "HEVC_Main444_10_AutoLevel", "HEVC_Main444Intra_AutoLevel"] {
            candidates.append((name, .named(name), kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange))
            candidates.append((name, .named(name), kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange))
        }
        for level in levels where !candidates.contains(where: { $0.0 == level }) {
            candidates.append((level, .named(level), kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange))
        }
        var found444 = false
        for (label, profile, format) in candidates {
            let row = attempt(label: label, profile: profile, format: format, source: source, converter: converter, w: w, h: h)
            print(row.line)
            found444 = found444 || row.chroma == 3
        }
        print("\n4:4:4 HEVC from the hardware encoder: \(found444 ? "YES" : "NO")")
        if let out444 = args.string("out444") { try write444Sample(w: w, h: h, converter: converter, to: out444) }

        let modes = args.string("rc").map { [$0 == "low"] } ?? [false, true]
        for low in modes {
            try latencyRun(w: w, h: h, frames: frames, converter: converter, lowLatencyRC: low, bitrate: args.int("bitrate", 25_000_000),
                           out: low == modes[0] ? args.string("out") : nil)
        }
    }

    struct Row { let line: String; let chroma: UInt8? }

    static func attempt(label: String, profile: HEVCProfile?, format: OSType, source: CVPixelBuffer,
                        converter: PixelConverter, w: Int, h: Int) -> Row {
        let input = fourCC(format)
        func fail(_ why: String) -> Row { Row(line: "| \(label) | \(input) | ✗ \(why) | | | | | |", chroma: nil) }
        let pb: CVPixelBuffer
        do { pb = format == kCVPixelFormatType_32BGRA ? source : try converter.convert(source, to: format) } catch { return fail("convert to \(input): \(error)") }
        var cfg = EncoderConfig(width: w, height: h)
        cfg.profile = profile
        cfg.averageBitrate = 40_000_000
        let enc: VideoEncoder
        do { enc = try VideoEncoder(config: cfg) } catch { return fail("create: \(error)") }
        let box = Box<Result<EncodedFrame, VideoError>>()
        enc.encode(pb, ptsNs: 0, forceKeyframe: true) { box.append($0) }
        enc.flush()
        guard let result = box.drain().first else { return fail("no output") }
        let frame: EncodedFrame
        switch result {
        case .success(let f): frame = f
        case .failure(let e): return fail("encode: \(e)")
        }
        guard let sps = frame.parameterSets.first(where: { HEVCNALType.type(of: $0) == HEVCNALType.sps }),
              let info = try? HEVCSPSInfo(sps: sps) else { return fail("no SPS") }
        var psnr = "n/a", fringe = "n/a"
        if let dec = try? VideoDecoder(parameterSets: frame.parameterSets, nalLengthSize: frame.nalLengthSize,
                                       outputPixelFormat: kCVPixelFormatType_32BGRA) {
            let out = Box<Result<DecodedFrame, VideoError>>()
            dec.decode(frame.data, ptsNs: 0) { out.append($0) }
            dec.waitForFrames()
            if case .success(let d)? = out.drain().first {
                psnr = fmt(PixelCompare.lumaPSNR(source, d.pixelBuffer))
                fringe = fmt(PixelCompare.colorFringe(source, d.pixelBuffer), 3)
            }
        }
        return Row(line: "| \(label) | \(input) | ✓ \(enc.usingHardware.map { "hw=\($0)" } ?? "hw required") | \(info.profileIdc) | \(info.chromaFormatIdc) | \(frame.data.count) | \(psnr) | \(fringe) |",
                   chroma: info.chromaFormatIdc)
    }

    /// Paced 120 Hz encode of an editor-like sequence: idle cursor blinks, scroll bursts, a forced
    /// keyframe, and refinement re-encodes of a still picture at QP caps 18 and 12.
    static func latencyRun(w: Int, h: Int, frames: Int, converter: PixelConverter, lowLatencyRC: Bool, bitrate: Int, out: String?) throws {
        print("\n## Encode latency and frame sizes (Main 4:2:0, 420v input, \(lowLatencyRC ? "low-latency RC" : "normal RC + speed, peak 2× over 100 ms"), \(bitrate / 1_000_000) Mbit/s, paced at 120 Hz, \(frames) frames)")
        var cfg = EncoderConfig(width: w, height: h)
        cfg.profile = .main
        cfg.averageBitrate = bitrate
        cfg.lowLatencyRateControl = lowLatencyRC
        cfg.peakBitrate = bitrate * 2
        cfg.enableLTR = true
        let enc: VideoEncoder
        do { enc = try VideoEncoder(config: cfg) } catch {
            cfg.enableLTR = false
            enc = try VideoEncoder(config: cfg)
            print("(LTR not accepted: \(error))")
        }
        print("low-latency rate control: \(enc.lowLatencyActive), hardware: \(enc.usingHardware.map(String.init) ?? "required at create"), LTR: \(cfg.enableLTR)")

        // Pre-convert content so the loop only measures the encoder.
        var pool: [String: CVPixelBuffer] = [:]
        func buffer(phase: Int, cursor: Bool) throws -> CVPixelBuffer {
            let key = "\(phase)-\(cursor)"
            if let b = pool[key] { return b }
            guard let bgra = TestPattern.pixelBuffer(width: w, height: h, phase: phase, cursorOn: cursor) else { throw ProbeFailure("pattern") }
            let b = try converter.convert(bgra, to: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            pool[key] = b
            return b
        }
        enum Kind: String, CaseIterable { case keyframe, cursor = "cursor blink (P)", scroll = "scroll (P)", refine18 = "refinement QP≤18", refine12 = "refinement QP≤12" }
        var plan: [(CVPixelBuffer, Kind, Int)] = []     // buffer, kind, maxQP to apply before
        var content: [(phase: Int, cursor: Bool)] = []
        func add(_ phase: Int, _ cursor: Bool, _ kind: Kind, _ qp: Int) throws {
            plan.append((try buffer(phase: phase, cursor: cursor), kind, qp))
            content.append((phase, cursor))
        }
        var phase = 0
        for i in 0..<frames {
            let cycle = i % 120
            if i == 0 || cycle == 60 && i > 0 && i % 240 == 60 {
                try add(phase, true, .keyframe, 51)
            } else if cycle < 24 {                       // 200 ms scroll burst
                phase += 1
                try add(phase, true, .scroll, 51)
            } else if cycle == 38 {                      // ≈120 ms after the scroll stops
                try add(phase, true, .refine18, 18)
            } else if cycle == 72 {                      // ≈400 ms after
                try add(phase, true, .refine12, 12)
            } else {
                try add(phase, cycle / 60 % 2 == 0, .cursor, 51)
            }
        }

        let box = Box<Result<EncodedFrame, VideoError>>()
        let period = Duration.nanoseconds(8_333_333)
        var next = ContinuousClock.now
        var currentQP = 51
        for (i, (pb, kind, qp)) in plan.enumerated() {
            if qp != currentQP || (currentQP != 51 && kind != .refine18 && kind != .refine12) {
                enc.setMaxFrameQP(kind == .refine18 || kind == .refine12 ? qp : nil)
                currentQP = kind == .refine18 || kind == .refine12 ? qp : 51
            }
            enc.encode(pb, ptsNs: UInt64(i) * 8_333_333, forceKeyframe: kind == .keyframe, tag: UInt64(i)) { box.append($0) }
            next += period
            let wait = next - ContinuousClock.now
            if wait > .zero { Thread.sleep(forTimeInterval: Double(wait.components.attoseconds) / 1e18 + Double(wait.components.seconds)) }
        }
        enc.flush()
        let results = box.drain()
        var encoded: [EncodedFrame] = []
        var dropped = 0, failed = 0
        for r in results {
            switch r {
            case .success(let f): encoded.append(f)
            case .failure(.noData): dropped += 1
            case .failure: failed += 1
            }
        }
        encoded.sort { $0.tag < $1.tag }
        let latencies = encoded.map { ms($0.encodeLatency) }
        let l = stats(latencies)
        print("frames out: \(encoded.count)/\(plan.count), dropped by encoder: \(dropped), errors: \(failed)")
        print("encode latency ms: p50 \(fmt(l.p50)) · p95 \(fmt(l.p95)) · max \(fmt(l.max))")
        print("| content | frames | median bytes | p95 bytes | max bytes | median encode ms | keyframe flag |")
        print("|---|---|---|---|---|---|---|")
        for kind in Kind.allCases {
            let fs = encoded.filter { plan[Int($0.tag)].1 == kind }
            guard !fs.isEmpty else { continue }
            let sizes = fs.map { Double($0.data.count) }.sorted()
            let lat = stats(fs.map { ms($0.encodeLatency) })
            print("| \(kind.rawValue) | \(fs.count) | \(Int(sizes[sizes.count / 2])) | \(Int(sizes[min(sizes.count - 1, sizes.count * 95 / 100)])) | \(Int(sizes.last ?? 0)) | \(fmt(lat.p50)) | \(fs.allSatisfy(\.isKeyframe) ? "all" : fs.contains(where: \.isKeyframe) ? "some" : "none") |")
        }
        let totalBytes = encoded.reduce(0) { $0 + $1.data.count }
        print("mean bitrate over the run: \(fmt(Double(totalBytes) * 8 / (Double(plan.count) / 120) / 1e6)) Mbit/s")

        // Quality of the refined still vs the scroll-time picture.
        if let firstRefine = encoded.firstIndex(where: { plan[Int($0.tag)].1 == .refine18 }) {
            try qualityCheck(encoded: encoded, upTo: firstRefine, content: content, w: w, h: h)
        }
        if let out {
            try writeAnnexB(encoded.prefix(120), to: out)
            print("\nwrote \(min(120, encoded.count)) frames of Annex B to \(out)")
        }
    }

    /// Decodes the first 2-second cycle and reports luma PSNR / colour fringe at the moments that matter:
    /// the last scroll frame, the still picture just before each refinement, and each refinement.
    static func qualityCheck(encoded: [EncodedFrame], upTo idx: Int, content: [(phase: Int, cursor: Bool)], w: Int, h: Int) throws {
        guard let first = encoded.first,
              let dec = try? VideoDecoder(parameterSets: first.parameterSets, nalLengthSize: first.nalLengthSize,
                                          outputPixelFormat: kCVPixelFormatType_32BGRA) else { return }
        let out = Box<Result<DecodedFrame, VideoError>>()
        for f in encoded where f.tag <= 72 { dec.decode(f.data, ptsNs: UInt64(f.tag)) { out.append($0) } }
        dec.waitForFrames()
        let decoded = Dictionary(out.drain().compactMap { try? $0.get() }.map { ($0.ptsNs, $0) }, uniquingKeysWith: { a, _ in a })
        print("| moment | frame | luma PSNR dB | colour fringe |")
        print("|---|---|---|---|")
        for (label, tag) in [("last scroll frame", 23), ("still, before refinement", 37), ("refinement QP≤18", 38),
                             ("still, before 2nd refinement", 71), ("refinement QP≤12", 72)] {
            guard let d = decoded[UInt64(tag)], tag < content.count,
                  let ref = TestPattern.pixelBuffer(width: w, height: h, phase: content[tag].phase, cursorOn: content[tag].cursor) else { continue }
            print("| \(label) | \(tag) | \(fmt(PixelCompare.lumaPSNR(ref, d.pixelBuffer))) | \(fmt(PixelCompare.colorFringe(ref, d.pixelBuffer), 3)) |")
        }
    }

    /// 60 frames of the real 4:4:4 stream (HEVC_Main444, 444v input) for the A20 decode probe on the phone.
    static func write444Sample(w: Int, h: Int, converter: PixelConverter, to path: String) throws {
        var cfg = EncoderConfig(width: w, height: h)
        cfg.profile = .named("HEVC_Main444_AutoLevel")
        let enc = try VideoEncoder(config: cfg)
        let box = Box<Result<EncodedFrame, VideoError>>()
        for i in 0..<60 {
            guard let bgra = TestPattern.pixelBuffer(width: w, height: h, phase: i / 4, cursorOn: i % 30 < 15) else { throw ProbeFailure("pattern") }
            let pb = try converter.convert(bgra, to: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
            enc.encode(pb, ptsNs: UInt64(i) * 8_333_333, forceKeyframe: i == 0, tag: UInt64(i)) { box.append($0) }
        }
        enc.flush()
        let frames = box.drain().compactMap { try? $0.get() }.sorted { $0.tag < $1.tag }
        guard let sps = frames.first?.parameterSets.first(where: { HEVCNALType.type(of: $0) == HEVCNALType.sps }),
              let info = try? HEVCSPSInfo(sps: sps), info.chromaFormatIdc == 3 else { throw ProbeFailure("4:4:4 sample is not 4:4:4") }
        try writeAnnexB(frames[...], to: path)
        print("wrote \(frames.count) frames of 4:4:4 (\(info.profileDescription), chroma \(info.chromaFormatIdc)) Annex B to \(path)")
    }

    static func writeAnnexB(_ frames: ArraySlice<EncodedFrame>, to path: String) throws {
        var bytes: [UInt8] = []
        let start: [UInt8] = [0, 0, 0, 1]
        for f in frames {
            if f.isKeyframe { for ps in f.parameterSets { bytes += start + ps } }
            for nal in try NALFraming.splitLengthPrefixed(f.data, lengthSize: f.nalLengthSize) { bytes += start + nal }
        }
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    }
}
