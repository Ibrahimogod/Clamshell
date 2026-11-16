import Foundation
import Testing
@testable import ClamshellCodec

/// Samples are x265 output (`ffmpeg -f lavfi -i testsrc2=size=64x48 -frames:v 2 -c:v libx265 -pix_fmt yuv444p|yuv420p`),
/// i.e. produced by an independent encoder.
@Suite("HEVC bitstream")
struct CodecTests {
    func sample(_ name: String) throws -> [UInt8] {
        let url = try #require(Bundle.module.url(forResource: "Samples", withExtension: nil)).appendingPathComponent(name)
        return [UInt8](try Data(contentsOf: url))
    }

    @Test func splitsAnnexB() throws {
        let nals = NALFraming.splitAnnexB(try sample("tiny444.hevc"))
        let types = nals.compactMap(HEVCNALType.type(of:))
        #expect(Array(types.prefix(3)) == [HEVCNALType.vps, HEVCNALType.sps, HEVCNALType.pps])
        #expect(types.contains { HEVCNALType.isIRAP($0) })
        #expect(nals.allSatisfy { !$0.isEmpty && $0.first != 0 })
    }

    @Test(arguments: [("tiny444.hevc", UInt8(3), UInt8(4)), ("tiny420.hevc", UInt8(1), UInt8(1))])
    func parsesSPS(_ file: String, _ chroma: UInt8, _ profile: UInt8) throws {
        let nals = NALFraming.splitAnnexB(try sample(file))
        let sps = try #require(nals.first { HEVCNALType.type(of: $0) == HEVCNALType.sps })
        let info = try HEVCSPSInfo(sps: sps)
        #expect(info.chromaFormatIdc == chroma)
        #expect(info.profileIdc == profile)
        #expect(info.width == 64 && info.height == 48)
    }

    @Test func accessUnits() throws {
        let aus = NALFraming.accessUnits(NALFraming.splitAnnexB(try sample("tiny420.hevc")))
        #expect(aus.count == 2, "two encoded frames")
        #expect(aus[0].compactMap(HEVCNALType.type(of:)).contains(HEVCNALType.sps))
    }

    @Test func lengthPrefixRoundTrip() throws {
        let nals = NALFraming.splitAnnexB(try sample("tiny444.hevc"))
        let lp = NALFraming.lengthPrefixed(nals)
        #expect(try NALFraming.splitLengthPrefixed(lp) == nals)
        #expect(throws: CodecError.truncated) { try NALFraming.splitLengthPrefixed(Array(lp.dropLast())) }
        #expect(throws: CodecError.self) { try NALFraming.splitLengthPrefixed(lp, lengthSize: 3) }
    }

    @Test func threeAndFourByteStartCodes() {
        let stream: [UInt8] = [0, 0, 0, 1, 0x40, 1, 0xAA, 0, 0, 1, 0x42, 1, 0xBB, 0, 0, 0, 1, 0x44, 1]
        #expect(NALFraming.splitAnnexB(stream) == [[0x40, 1, 0xAA], [0x42, 1, 0xBB], [0x44, 1]])
    }

    @Test func emulationPrevention() {
        #expect(hevcRBSP([0, 0, 3, 1, 0, 0, 3, 0, 5]) == [0, 0, 1, 0, 0, 0, 5])
        #expect(hevcRBSP([1, 2, 3]) == [1, 2, 3])
    }

    @Test func expGolomb() throws {
        var r = BitReader([0b1010_0110, 0b0100_0000])  // ue: 1→0, 010→1, 011→2, 00100→3
        #expect(try r.ue() == 0)
        #expect(try r.ue() == 1)
        #expect(try r.ue() == 2)
        #expect(try r.ue() == 3)
    }

    @Test func rejectsNonSPS() {
        #expect(throws: CodecError.invalidNAL) { try HEVCSPSInfo(sps: [0x40, 0x01, 0x0C, 0x01]) }
    }
}
