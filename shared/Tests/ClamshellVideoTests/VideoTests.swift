import CoreVideo
import Foundation
import Synchronization
import Testing
import VideoToolbox
@testable import ClamshellCodec
@testable import ClamshellVideo

final class Collected<T: Sendable>: Sendable {
    private let items = Mutex<[T]>([])
    func append(_ x: T) { items.withLock { $0.append(x) } }
    var all: [T] { items.withLock { $0 } }
}

/// Real VideoToolbox round trips on this Mac (hardware HEVC is present on every Apple-silicon Mac).
@Suite("VideoToolbox round trip", .serialized)
struct VideoTests {
    let w = 640, h = 400

    func encodeAll(_ enc: VideoEncoder, _ frames: [(CVPixelBuffer, Bool)]) throws -> [EncodedFrame] {
        let out = Collected<Result<EncodedFrame, VideoError>>()
        for (i, (pb, key)) in frames.enumerated() {
            enc.encode(pb, ptsNs: UInt64(i) * 8_333_333, forceKeyframe: key, tag: UInt64(i)) { out.append($0) }
        }
        enc.flush()
        return try out.all.map { try $0.get() }
    }

    func decodeAll(_ frames: [EncodedFrame]) throws -> [DecodedFrame] {
        let first = try #require(frames.first)
        let dec = try VideoDecoder(parameterSets: first.parameterSets, nalLengthSize: first.nalLengthSize,
                                   outputPixelFormat: kCVPixelFormatType_32BGRA)
        let out = Collected<Result<DecodedFrame, VideoError>>()
        for f in frames { dec.decode(f.data, ptsNs: f.ptsNs) { out.append($0) } }
        dec.waitForFrames()
        return try out.all.map { try $0.get() }
    }

    @Test func encodeDecodeRoundTrip() throws {
        var cfg = EncoderConfig(width: w, height: h)
        cfg.profile = .main
        cfg.averageBitrate = 8_000_000
        let enc = try VideoEncoder(config: cfg)
        let src = try (0..<6).map { i in try #require(TestPattern.pixelBuffer(width: w, height: h, phase: i / 3, cursorOn: i % 2 == 0)) }
        let encoded = try encodeAll(enc, src.enumerated().map { ($1, $0 == 0) })
        #expect(encoded.count == 6)
        #expect(encoded[0].isKeyframe)
        #expect(encoded.dropFirst().allSatisfy { !$0.isKeyframe }, "keyframes only on request")
        #expect(encoded.map(\.tag) == [0, 1, 2, 3, 4, 5], "no reordering")
        #expect(encoded[0].parameterSets.count == 3)

        let sps = try #require(encoded[0].parameterSets.first { HEVCNALType.type(of: $0) == HEVCNALType.sps })
        let info = try HEVCSPSInfo(sps: sps)
        #expect(info.chromaFormatIdc == 1)
        #expect(info.width == w && info.height == h)

        // The bitstream splits into NAL units with our own framing code.
        let nals = try NALFraming.splitLengthPrefixed(encoded[0].data, lengthSize: encoded[0].nalLengthSize)
        #expect(nals.contains { HEVCNALType.type(of: $0).map(HEVCNALType.isIRAP) ?? false })

        let decoded = try decodeAll(encoded)
        #expect(decoded.count == 6)
        let psnr = try #require(PixelCompare.lumaPSNR(src[0], decoded[0].pixelBuffer))
        #expect(psnr > 30, "keyframe luma PSNR \(psnr)")
    }

    @Test func refinementCapImprovesQuality() throws {
        var cfg = EncoderConfig(width: w, height: h)
        cfg.averageBitrate = 3_000_000           // tight budget so the default frame is soft
        let enc = try VideoEncoder(config: cfg)
        let still = try #require(TestPattern.pixelBuffer(width: w, height: h))
        let moved = try #require(TestPattern.pixelBuffer(width: w, height: h, phase: 1))
        // key, motion, then the same still picture twice: once at the motion cap, once refined.
        var frames = try encodeAll(enc, [(still, true), (moved, false), (still, false)])
        #expect(enc.setMaxFrameQP(12))
        frames += try encodeAll(enc, [(still, false)])
        enc.setMaxFrameQP(nil)
        let decoded = try decodeAll(frames)
        let base = try #require(PixelCompare.lumaPSNR(still, decoded[2].pixelBuffer))
        let refined = try #require(PixelCompare.lumaPSNR(still, decoded[3].pixelBuffer))
        #expect(refined > base, "refined \(refined) dB vs \(base) dB")
        #expect(frames[3].data.count > frames[2].data.count)
    }

    @Test func testPatternRenders() throws {
        let a = try #require(TestPattern.pixelBuffer(width: 200, height: 100))
        let b = try #require(TestPattern.pixelBuffer(width: 200, height: 100))
        #expect(PixelCompare.lumaPSNR(a, b) == .infinity, "deterministic")
        let c = try #require(TestPattern.pixelBuffer(width: 200, height: 100, phase: 1))
        #expect((PixelCompare.lumaPSNR(a, c) ?? .infinity) < 40)
    }

    @Test func decoderRejectsMissingParameterSets() {
        #expect(throws: VideoError.missingFormat) { try VideoDecoder(parameterSets: [[0x40, 0x01]]) }
    }
}
