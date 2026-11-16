/// HEVC bitstream helpers shared by the Mac host, the iOS client and the probes.
/// Pure Swift (no VideoToolbox) so it is unit-tested on any platform.

public enum CodecError: Error, Equatable, Sendable {
    case truncated
    case invalidNAL
    case unsupported(String)
}

/// HEVC NAL unit types we care about (H.265 Table 7-1).
public enum HEVCNALType {
    public static let vps: UInt8 = 32
    public static let sps: UInt8 = 33
    public static let pps: UInt8 = 34
    public static let aud: UInt8 = 35
    public static let prefixSEI: UInt8 = 39
    /// 16...21 are IRAP (keyframe) slices.
    public static func isIRAP(_ t: UInt8) -> Bool { (16...21).contains(t) }
    public static func isParameterSet(_ t: UInt8) -> Bool { t == vps || t == sps || t == pps }
    public static func type(of nal: [UInt8]) -> UInt8? { nal.first.map { ($0 >> 1) & 0x3F } }
}

public enum NALFraming {
    /// Splits an Annex B byte stream (00 00 01 / 00 00 00 01 start codes) into NAL units.
    public static func splitAnnexB(_ data: [UInt8]) -> [[UInt8]] {
        var nals: [[UInt8]] = []
        var i = 0
        var start: Int?
        let n = data.count
        while i + 2 < n {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                if let s = start {
                    var end = i
                    while end > s, data[end - 1] == 0 { end -= 1 }   // trailing zero of a 4-byte start code
                    if end > s { nals.append(Array(data[s..<end])) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let s = start, s < n { nals.append(Array(data[s..<n])) }
        return nals
    }

    /// NAL units → 4-byte big-endian length-prefixed (AVCC/HVCC) sample data, as VideoToolbox wants.
    public static func lengthPrefixed(_ nals: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            let len = UInt32(nal.count)
            out += [UInt8(len >> 24), UInt8(truncatingIfNeeded: len >> 16), UInt8(truncatingIfNeeded: len >> 8), UInt8(truncatingIfNeeded: len)]
            out += nal
        }
        return out
    }

    /// Length-prefixed sample data → NAL units. `lengthSize` is 1, 2 or 4 (from the format description).
    public static func splitLengthPrefixed(_ data: [UInt8], lengthSize: Int = 4) throws -> [[UInt8]] {
        guard [1, 2, 4].contains(lengthSize) else { throw CodecError.unsupported("NAL length size \(lengthSize)") }
        var nals: [[UInt8]] = []
        var i = 0
        while i < data.count {
            guard i + lengthSize <= data.count else { throw CodecError.truncated }
            var len = 0
            for k in 0..<lengthSize { len = len << 8 | Int(data[i + k]) }
            i += lengthSize
            guard len > 0, i + len <= data.count else { throw CodecError.truncated }
            nals.append(Array(data[i..<i + len]))
            i += len
        }
        return nals
    }

    /// Groups an Annex B stream into access units (pictures): a new AU starts at a parameter set,
    /// AUD or prefix SEI after a slice, or at a slice whose `first_slice_segment_in_pic_flag` is set.
    public static func accessUnits(_ nals: [[UInt8]]) -> [[[UInt8]]] {
        var aus: [[[UInt8]]] = []
        var current: [[UInt8]] = []
        var sawSlice = false
        for nal in nals {
            guard let t = HEVCNALType.type(of: nal) else { continue }
            let isSlice = t < 32
            let firstSlice = isSlice && nal.count > 2 && nal[2] & 0x80 != 0
            let startsNew = sawSlice && ((!isSlice && [HEVCNALType.vps, HEVCNALType.sps, HEVCNALType.pps, HEVCNALType.aud, HEVCNALType.prefixSEI].contains(t)) || firstSlice)
            if startsNew {
                aus.append(current)
                current = []
                sawSlice = false
            }
            current.append(nal)
            if isSlice { sawSlice = true }
        }
        if !current.isEmpty { aus.append(current) }
        return aus
    }
}

/// Removes emulation-prevention bytes (00 00 03 → 00 00) to get the RBSP.
public func hevcRBSP(_ nal: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(nal.count)
    var zeros = 0
    for b in nal {
        if zeros >= 2, b == 3 { zeros = 0; continue }
        out.append(b)
        zeros = b == 0 ? zeros + 1 : 0
    }
    return out
}

struct BitReader {
    let bytes: [UInt8]
    var bit = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func u(_ n: Int) throws -> UInt64 {
        var v: UInt64 = 0
        for _ in 0..<n {
            guard bit / 8 < bytes.count else { throw CodecError.truncated }
            v = v << 1 | UInt64((bytes[bit / 8] >> (7 - UInt8(bit % 8))) & 1)
            bit += 1
        }
        return v
    }

    mutating func skip(_ n: Int) throws {
        guard (bit + n + 7) / 8 <= bytes.count else { throw CodecError.truncated }
        bit += n
    }

    /// Unsigned Exp-Golomb.
    mutating func ue() throws -> UInt64 {
        var zeros = 0
        while try u(1) == 0 {
            zeros += 1
            guard zeros < 32 else { throw CodecError.invalidNAL }
        }
        return (UInt64(1) << UInt64(zeros)) - 1 + (try u(zeros))
    }
}

/// The fields of an HEVC SPS that decide whether a stream is text-sharp 4:4:4 (ADR-0006/0007).
public struct HEVCSPSInfo: Equatable, Sendable {
    public var profileIdc: UInt8          // 1 Main, 2 Main10, 4 Range Extensions (needed for 4:4:4)
    public var levelIdc: UInt8            // level × 30
    public var chromaFormatIdc: UInt8     // 0 mono, 1 4:2:0, 2 4:2:2, 3 4:4:4
    public var width: UInt32
    public var height: UInt32

    public var chromaDescription: String {
        switch chromaFormatIdc {
        case 0: "4:0:0"
        case 1: "4:2:0"
        case 2: "4:2:2"
        case 3: "4:4:4"
        default: "unknown(\(chromaFormatIdc))"
        }
    }

    public var profileDescription: String {
        switch profileIdc {
        case 1: "Main"
        case 2: "Main 10"
        case 3: "Main Still Picture"
        case 4: "Range Extensions"
        default: "profile \(profileIdc)"
        }
    }

    /// Parses an SPS NAL unit (with its 2-byte NAL header).
    public init(sps nal: [UInt8]) throws {
        guard HEVCNALType.type(of: nal) == HEVCNALType.sps, nal.count > 3 else { throw CodecError.invalidNAL }
        var r = BitReader(hevcRBSP(Array(nal.dropFirst(2))))
        _ = try r.u(4)                                      // sps_video_parameter_set_id
        let maxSubLayersMinus1 = Int(try r.u(3))
        _ = try r.u(1)                                      // temporal_id_nesting
        // profile_tier_level(1, maxSubLayersMinus1)
        _ = try r.u(2)                                      // general_profile_space
        _ = try r.u(1)                                      // general_tier_flag
        profileIdc = UInt8(try r.u(5))
        try r.skip(32)                                      // compatibility flags
        try r.skip(4 + 43 + 1)                              // source flags, constraint flags, reserved
        levelIdc = UInt8(try r.u(8))
        var profilePresent: [Bool] = []
        var levelPresent: [Bool] = []
        for _ in 0..<maxSubLayersMinus1 {
            profilePresent.append(try r.u(1) == 1)
            levelPresent.append(try r.u(1) == 1)
        }
        if maxSubLayersMinus1 > 0 { for _ in maxSubLayersMinus1..<8 { try r.skip(2) } }
        for i in 0..<maxSubLayersMinus1 {
            if profilePresent[i] { try r.skip(88) }
            if levelPresent[i] { try r.skip(8) }
        }
        _ = try r.ue()                                      // sps_seq_parameter_set_id
        let chroma = try r.ue()
        guard chroma <= 3 else { throw CodecError.invalidNAL }
        chromaFormatIdc = UInt8(chroma)
        if chroma == 3 { _ = try r.u(1) }                   // separate_colour_plane_flag
        width = UInt32(truncatingIfNeeded: try r.ue())
        height = UInt32(truncatingIfNeeded: try r.ue())
    }
}
