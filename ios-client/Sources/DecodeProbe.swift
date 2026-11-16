import ClamshellCodec
import ClamshellVideo
import CoreVideo
import Foundation
import Synchronization

/// Day-1 probe 1 on the phone (ADR-0007): can this device's hardware decoder take the Mac's HEVC 4:4:4
/// (Rext) stream? Decodes the bundled samples with `requireHardware`, checks the output's chroma, and
/// times each frame. The 4:4:4 result is cached and decides the `hevc444Decode` capability.
enum DecodeProbe {
    struct Result: Sendable, Identifiable {
        var id: String { file }
        let file: String
        let spsChroma: Int?
        let frames: Int
        let decoded: Int
        let outputFormat: String
        let hardware: Bool?
        let msP50: Double?
        let msMax: Double?
        let error: String?
        var passed: Bool { error == nil && decoded == frames && frames > 0 }
    }

    static let samples = ["vt444_1878x1334", "x265_444_1878x1334", "vt420_1878x1334"]
    private static let cacheKey = "probe.hevc444.v1"

    static var cached444: Bool? {
        UserDefaults.standard.object(forKey: cacheKey) as? Bool
    }

    /// Runs the Mac's own 4:4:4 sample and caches the verdict.
    @discardableResult
    static func run444Check() -> Bool {
        let r = run(sample: "vt444_1878x1334")
        let ok = r.passed && r.outputFormat == "444v" && r.hardware != false
        UserDefaults.standard.set(ok, forKey: cacheKey)
        return ok
    }

    static func runAll() -> [Result] {
        let results = samples.map(run(sample:))
        if let r = results.first { UserDefaults.standard.set(r.passed && r.outputFormat == "444v" && r.hardware != false, forKey: cacheKey) }
        return results
    }

    static func run(sample: String) -> Result {
        func fail(_ e: String, chroma: Int? = nil) -> Result {
            Result(file: sample, spsChroma: chroma, frames: 0, decoded: 0, outputFormat: "-", hardware: nil, msP50: nil, msMax: nil, error: e)
        }
        guard let url = Bundle.main.url(forResource: sample, withExtension: "hevc", subdirectory: "Probes")
                ?? Bundle.main.url(forResource: sample, withExtension: "hevc"),
              let data = try? Data(contentsOf: url) else { return fail("sample not bundled") }
        let aus = NALFraming.accessUnits(NALFraming.splitAnnexB([UInt8](data)))
        let params = aus.first?.filter { HEVCNALType.type(of: $0).map(HEVCNALType.isParameterSet) ?? false } ?? []
        let chroma = params.first { HEVCNALType.type(of: $0) == HEVCNALType.sps }.flatMap { try? HEVCSPSInfo(sps: $0) }.map { Int($0.chromaFormatIdc) }
        let pixelFormat: OSType = chroma == 3 ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let decoder: VideoDecoder
        do { decoder = try VideoDecoder(parameterSets: params, outputPixelFormat: pixelFormat, requireHardware: true) }
        catch { return fail("hardware decoder refused the stream: \(error)", chroma: chroma) }
        let out = Mutex<(ok: Int, ms: [Double], format: OSType?, error: String?)>((0, [], nil, nil))
        var frames = 0
        for (i, au) in aus.enumerated() {
            let slices = au.filter { !(HEVCNALType.type(of: $0).map(HEVCNALType.isParameterSet) ?? true) }
            guard !slices.isEmpty else { continue }
            frames += 1
            decoder.decode(NALFraming.lengthPrefixed(slices), ptsNs: UInt64(i) * 8_333_333) { result in
                out.withLock { s in
                    switch result {
                    case .success(let f):
                        s.ok += 1
                        let c = f.decodeLatency.components
                        s.ms.append(Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
                        s.format = CVPixelBufferGetPixelFormatType(f.pixelBuffer)
                    case .failure(let e):
                        s.error = "\(e)"
                    }
                }
            }
        }
        decoder.waitForFrames()
        return out.withLock { s in
            let sorted = s.ms.sorted()
            return Result(file: sample, spsChroma: chroma, frames: frames, decoded: s.ok, outputFormat: s.format.map(fourCC) ?? "-",
                          hardware: decoder.usingHardware, msP50: sorted.isEmpty ? nil : sorted[sorted.count / 2], msMax: sorted.last,
                          error: s.error)
        }
    }

    /// `--probe` launch argument: the same probe, printed to the console (Xcode or `simctl launch --console`).
    static func printReport() async {
        let results = await Task.detached { runAll() }.value
        print("# Clamshell decode probe — hardware HEVC available: \(VideoDecoder.hardwareHEVCSupported)")
        for r in results {
            print("\(r.file): \(r.passed ? "PASS" : "FAIL") · SPS chroma \(r.spsChroma.map(String.init) ?? "?") · decoded \(r.decoded)/\(r.frames) · out \(r.outputFormat) · hw \(r.hardware.map(String.init) ?? "?") · ms p50 \(r.msP50.map { String(format: "%.2f", $0) } ?? "-") max \(r.msMax.map { String(format: "%.2f", $0) } ?? "-")\(r.error.map { " · " + $0 } ?? "")")
        }
        fflush(stdout)
    }

    static func fourCC(_ v: OSType) -> String {
        let b = [v >> 24, v >> 16, v >> 8, v].map { UInt8(truncatingIfNeeded: $0) }
        return String(decoding: b, as: UTF8.self)
    }
}
