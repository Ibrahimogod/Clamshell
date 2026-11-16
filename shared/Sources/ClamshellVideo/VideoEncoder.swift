import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum VideoError: Error, Equatable, Sendable {
    case status(String, OSStatus)
    case noData
    case missingFormat
}

@inline(__always)
func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw VideoError.status(what, status) }
}

public enum HEVCProfile: Sendable, Equatable {
    case main, main10, main42210
    /// A profile string not in the public SDK (the probe tries candidates such as a 4:4:4 profile).
    case named(String)

    var cfValue: CFString {
        switch self {
        case .main: kVTProfileLevel_HEVC_Main_AutoLevel
        case .main10: kVTProfileLevel_HEVC_Main10_AutoLevel
        case .main42210: kVTProfileLevel_HEVC_Main42210_AutoLevel
        case .named(let s): s as CFString
        }
    }
}

/// Encoder settings for the desktop stream (ADR-0006, ADR-0008).
public struct EncoderConfig: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int = 120
    public var averageBitrate: Int = 25_000_000
    public var profile: HEVCProfile?
    /// `EnableLowLatencyRateControl`. On by default. On the M5 at 1878×1334 it costs ~7.2 ms per frame against
    /// ~3.9 ms for normal RC, but halves keyframe size (193 vs 400 KB), gives +6 dB during scrolls at the same
    /// bitrate, and is the only mode with LTR and working QP-cap refinement (ADR-0007, probe log).
    public var lowLatencyRateControl = true
    /// Burst cap for normal rate control: at most `peakBitrate` bits per second over any `peakWindowMs`.
    public var peakBitrate: Int?
    public var peakWindowMs = 100
    public var requireHardware = true
    public var enableLTR = false
    /// Cap during motion (rate control decides below it). Refinement frames lower it temporarily.
    public var motionMaxQP: Int?
    public var prioritizeSpeed = true

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct EncodedFrame: Sendable {
    /// Length-prefixed NAL units (`nalLengthSize` bytes each), ready for `VideoFragment`s.
    public let data: [UInt8]
    public let nalLengthSize: Int
    public let isKeyframe: Bool
    /// VPS, SPS, PPS of the stream (from the output format description).
    public let parameterSets: [[UInt8]]
    public let ptsNs: UInt64
    public let encodeLatency: Duration
    public let tag: UInt64
}

/// Thin, honest wrapper over `VTCompressionSession`: low-latency, no B-frames, keyframes only on
/// request, optional LTR. Safe to call from one producer thread; callbacks arrive on VT's thread.
public final class VideoEncoder: @unchecked Sendable {
    public let config: EncoderConfig
    private let session: VTCompressionSession
    /// Whether the low-latency rate control spec was accepted at creation.
    public let lowLatencyActive: Bool

    public init(config: EncoderConfig) throws {
        self.config = config
        var created: VTCompressionSession?
        var lowLatency = config.lowLatencyRateControl
        func make(_ lowLatency: Bool) -> OSStatus {
            var spec: [CFString: Any] = [:]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            if config.requireHardware { spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true }
            return VTCompressionSessionCreate(allocator: nil, width: Int32(config.width), height: Int32(config.height),
                                              codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                              refcon: nil, compressionSessionOut: &created)
        }
        var status = make(lowLatency)
        if status != noErr, lowLatency {
            lowLatency = false
            status = make(false)
        }
        try check(status, "VTCompressionSessionCreate")
        guard let s = created else { throw VideoError.status("VTCompressionSessionCreate", -1) }
        session = s
        lowLatencyActive = lowLatency

        func set(_ key: CFString, _ value: CFTypeRef, required: Bool = true) throws {
            let st = VTSessionSetProperty(s, key: key, value: value)
            if required { try check(st, "set \(key)") }
        }
        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)           // no B-frames
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, config.fps as CFNumber, required: false)
        try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 3600 as CFNumber, required: false)
        try set(kVTCompressionPropertyKey_AverageBitRate, config.averageBitrate as CFNumber, required: false)
        try set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, config.prioritizeSpeed ? kCFBooleanTrue : kCFBooleanFalse, required: false)
        if let peak = config.peakBitrate, !lowLatency {
            let window = Double(config.peakWindowMs) / 1000
            try set(kVTCompressionPropertyKey_DataRateLimits, [Double(peak) / 8 * window, window] as CFArray, required: false)
        }
        if let p = config.profile { try set(kVTCompressionPropertyKey_ProfileLevel, p.cfValue) }
        if config.enableLTR { try set(kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue) }
        if let qp = config.motionMaxQP { try set(kVTCompressionPropertyKey_MaxAllowedFrameQP, qp as CFNumber) }
        try check(VTCompressionSessionPrepareToEncodeFrames(s), "PrepareToEncodeFrames")
    }

    deinit {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    /// `nil` when the encoder doesn't report it (the M5 HEVC encoder returns kVTPropertyNotSupportedErr).
    /// With `requireHardware` (default) a successful init already guarantees the media engine.
    public var usingHardware: Bool? { boolProperty(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder) }

    func boolProperty(_ key: CFString) -> Bool? {
        var value: CFTypeRef?
        // Copy rule: the +1 reference written here is owned (and released) by `value`.
        let status = withUnsafeMutablePointer(to: &value) { VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: $0) }
        guard status == noErr else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// Caps QP for the next frames (refinement: 18, then 12). `nil` restores the motion cap.
    @discardableResult
    public func setMaxFrameQP(_ qp: Int?) -> Bool {
        let value = qp ?? config.motionMaxQP ?? 51
        return VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: value as CFNumber) == noErr
    }

    /// Live bitrate change (the rate controller, ADR-0008 §5). Takes effect from the next frame.
    @discardableResult
    public func setAverageBitrate(_ bps: Int) -> Bool {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber) == noErr
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, ptsNs: UInt64, forceKeyframe: Bool = false, tag: UInt64 = 0,
                       handler: @escaping @Sendable (Result<EncodedFrame, VideoError>) -> Void) {
        let started = ContinuousClock.now
        let pts = CMTime(value: CMTimeValue(ptsNs), timescale: 1_000_000_000)
        let props: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
                                                     frameProperties: props, infoFlagsOut: nil) { status, _, sample in
            let latency = ContinuousClock.now - started
            guard status == noErr else { handler(.failure(.status("encode callback", status))); return }
            guard let sample else { handler(.failure(.noData)); return }   // frame dropped by the encoder
            handler(Result { try Self.extract(sample, ptsNs: ptsNs, latency: latency, tag: tag) }.mapError { $0 as? VideoError ?? .noData })
        }
        if status != noErr { handler(.failure(.status("VTCompressionSessionEncodeFrame", status))) }
    }

    /// Blocks until queued frames are emitted.
    public func flush() { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }

    static func extract(_ sample: CMSampleBuffer, ptsNs: UInt64, latency: Duration, tag: UInt64) throws -> EncodedFrame {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw VideoError.noData }
        let length = CMBlockBufferGetDataLength(block)
        var data = [UInt8](repeating: 0, count: length)
        try check(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data), "CopyDataBytes")
        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }
        guard let format = CMSampleBufferGetFormatDescription(sample) else { throw VideoError.missingFormat }
        let (sets, nalLength) = try parameterSets(of: format)
        return EncodedFrame(data: data, nalLengthSize: nalLength, isKeyframe: keyframe, parameterSets: sets,
                            ptsNs: ptsNs, encodeLatency: latency, tag: tag)
    }

    public static func parameterSets(of format: CMFormatDescription) throws -> ([[UInt8]], Int) {
        var count = 0
        var nalLength: Int32 = 4
        try check(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                    parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                    nalUnitHeaderLengthOut: &nalLength), "HEVC parameter set count")
        var sets: [[UInt8]] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            try check(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                        parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                        nalUnitHeaderLengthOut: nil), "HEVC parameter set \(i)")
            guard let ptr else { throw VideoError.missingFormat }
            sets.append(Array(UnsafeBufferPointer(start: ptr, count: size)))
        }
        return (sets, Int(nalLength))
    }

    /// Profile/level strings the HEVC hardware encoder says it supports at this size.
    public static func supportedProfileLevels(width: Int, height: Int) -> [String] {
        var props: CFDictionary?
        var encoderID: CFString?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCopySupportedPropertyDictionaryForEncoder(width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                                                          encoderSpecification: spec, encoderIDOut: &encoderID,
                                                          supportedPropertiesOut: &props) == noErr,
              let dict = props as? [CFString: Any],
              let profile = dict[kVTCompressionPropertyKey_ProfileLevel] as? [CFString: Any],
              let values = profile[kVTPropertySupportedValueListKey] as? [String] else { return [] }
        return values.sorted()
    }
}
