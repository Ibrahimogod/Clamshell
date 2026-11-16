import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// A decoded picture. `CVPixelBuffer` is a thread-safe, reference-counted CF type.
public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let ptsNs: UInt64
    public let decodeLatency: Duration
}

/// `VTDecompressionSession` for one parameter-set generation. A new `VideoFormat` means a new decoder.
public final class VideoDecoder: @unchecked Sendable {
    public let format: CMVideoFormatDescription
    public let nalLengthSize: Int
    private let session: VTDecompressionSession

    public static var hardwareHEVCSupported: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) }

    /// - Parameters:
    ///   - parameterSets: VPS, SPS, PPS.
    ///   - outputPixelFormat: e.g. `kCVPixelFormatType_444YpCbCr8BiPlanarFullRange` for 4:4:4 streams.
    ///   - requireHardware: fail instead of silently falling back to a software decoder (A20 probe).
    public init(parameterSets: [[UInt8]], nalLengthSize: Int = 4, outputPixelFormat: OSType? = nil, requireHardware: Bool = false) throws {
        guard parameterSets.count >= 3 else { throw VideoError.missingFormat }
        self.nalLengthSize = nalLengthSize
        format = try Self.makeFormat(parameterSets, nalLengthSize: nalLengthSize)

        var attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        if let outputPixelFormat { attrs[kCVPixelBufferPixelFormatTypeKey] = outputPixelFormat }
        var spec: [CFString: Any] = [:]
        if requireHardware { spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true }
        var created: VTDecompressionSession?
        try check(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec as CFDictionary,
                                               imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                               decompressionSessionOut: &created), "VTDecompressionSessionCreate")
        guard let created else { throw VideoError.status("VTDecompressionSessionCreate", -1) }
        session = created
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    }

    deinit {
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
    }

    public var usingHardware: Bool {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: $0)
        }
        guard status == noErr else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    static func makeFormat(_ sets: [[UInt8]], nalLengthSize: Int) throws -> CMVideoFormatDescription {
        // Copy each set into stable memory for the duration of the call.
        let buffers = sets.map { set -> UnsafeMutableBufferPointer<UInt8> in
            let b = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: set.count)
            _ = b.initialize(from: set)
            return b
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0.baseAddress!) }  // allocate(capacity: n > 0) never returns nil base
        let sizes = sets.map(\.count)
        var format: CMFormatDescription?
        try check(CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                      parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                      nalUnitHeaderLength: Int32(nalLengthSize), extensions: nil,
                                                                      formatDescriptionOut: &format), "FormatFromHEVCParameterSets")
        guard let format else { throw VideoError.missingFormat }
        return format
    }

    public var dimensions: CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(format) }

    /// Decodes one access unit of length-prefixed NAL units.
    public func decode(_ data: [UInt8], ptsNs: UInt64, handler: @escaping @Sendable (Result<DecodedFrame, VideoError>) -> Void) {
        let started = ContinuousClock.now
        let sample: CMSampleBuffer
        do { sample = try makeSample(data, ptsNs: ptsNs) } catch {
            handler(.failure(error as? VideoError ?? .noData))
            return
        }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
                                                       infoFlagsOut: nil) { status, _, image, _, _ in
            guard status == noErr else { handler(.failure(.status("decode callback", status))); return }
            guard let image else { handler(.failure(.noData)); return }
            handler(.success(DecodedFrame(pixelBuffer: image, ptsNs: ptsNs, decodeLatency: ContinuousClock.now - started)))
        }
        if status != noErr { handler(.failure(.status("VTDecompressionSessionDecodeFrame", status))) }
    }

    public func waitForFrames() { VTDecompressionSessionWaitForAsynchronousFrames(session) }

    func makeSample(_ data: [UInt8], ptsNs: UInt64) throws -> CMSampleBuffer {
        guard !data.isEmpty else { throw VideoError.noData }
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                     customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                                                     flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block), "BlockBufferCreate")
        guard let block else { throw VideoError.noData }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw VideoError.noData }
            try check(CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count), "ReplaceDataBytes")
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(ptsNs), timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                            sampleSizeArray: &size, sampleBufferOut: &sample), "SampleBufferCreate")
        guard let sample else { throw VideoError.noData }
        return sample
    }
}
