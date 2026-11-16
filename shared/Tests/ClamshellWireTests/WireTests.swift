import Testing
@testable import ClamshellWire

@Suite("Varint and bytes")
struct VarintTests {
    @Test(arguments: [UInt64(0), 1, 127, 128, 300, 16_383, 16_384, 1 << 21, UInt64(UInt32.max), 1 << 56, UInt64.max])
    func roundTrip(_ v: UInt64) throws {
        var w = ByteWriter()
        w.varint(v)
        var r = ByteReader(w.bytes)
        #expect(try r.varint() == v)
        #expect(r.isAtEnd)
    }

    @Test func knownEncodings() {
        func enc(_ v: UInt64) -> [UInt8] { var w = ByteWriter(); w.varint(v); return w.bytes }
        #expect(enc(0) == [0x00])
        #expect(enc(127) == [0x7F])
        #expect(enc(128) == [0x80, 0x01])
        #expect(enc(300) == [0xAC, 0x02])
        #expect(enc(UInt64.max) == [UInt8](repeating: 0xFF, count: 9) + [0x01])
    }

    @Test func overflowAndTooLong() {
        var a = ByteReader([UInt8](repeating: 0xFF, count: 9) + [0x02])
        #expect(throws: WireError.varintOverflow) { try a.varint() }
        var b = ByteReader([UInt8](repeating: 0xFF, count: 9) + [0x81, 0x00])
        #expect(throws: WireError.varintTooLong) { try b.varint() }
    }

    @Test func truncated() {
        var r = ByteReader([0x80])
        #expect(throws: WireError.truncated(needed: 1, available: 0)) { try r.varint() }
        var r2 = ByteReader([0x00, 0x01])
        #expect(throws: WireError.truncated(needed: 4, available: 2)) { try r2.u32() }
    }

    @Test func lengthLimit() {
        var w = ByteWriter()
        w.varint(UInt64(wireMaxFieldLength) + 1)
        var r = ByteReader(w.bytes)
        #expect(throws: WireError.lengthTooLarge(wireMaxFieldLength + 1)) { try r.length() }
    }

    @Test func fixedWidthBigEndian() throws {
        var w = ByteWriter()
        w.u16(0x0102); w.u32(0x0304_0506); w.u64(0x0708_090A_0B0C_0D0E)
        #expect(w.bytes == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14])
        var r = ByteReader(w.bytes)
        #expect(try r.u16() == 0x0102)
        #expect(try r.u32() == 0x0304_0506)
        #expect(try r.u64() == 0x0708_090A_0B0C_0D0E)
    }

    @Test func hex() {
        #expect([0x00, 0xAB, 0xFF].hex == "00abff")
        #expect([UInt8](hex: "00 ab\nFF") == [0x00, 0xAB, 0xFF])
        #expect([UInt8](hex: "abc") == nil)
        #expect([UInt8](hex: "zz") == nil)
    }
}

@Suite("TLV")
struct TLVTests {
    @Test func unknownNonCriticalIsSkipped() throws {
        var t = TLVWriter()
        t.uint(1, 7)
        t.bytes(99, [1, 2, 3])
        let r = try TLVReader(t.bytes, knownTags: [1])
        #expect(try r.requiredUInt(1) == 7)
    }

    @Test func unknownCriticalIsRejected() {
        var t = TLVWriter()
        t.uint(1, 7)
        t.uint(0x8001, 1)
        #expect(throws: WireError.unsupportedCritical(tag: 0x8001)) { try TLVReader(t.bytes, knownTags: [1]) }
    }

    @Test func knownCriticalIsAccepted() throws {
        var t = TLVWriter()
        t.uint(0x8001, 1)
        let r = try TLVReader(t.bytes, knownTags: [0x8001])
        #expect(try r.requiredUInt(0x8001) == 1)
    }

    @Test func duplicateAndMissing() throws {
        var t = TLVWriter()
        t.uint(1, 1)
        t.uint(1, 2)
        let r = try TLVReader(t.bytes, knownTags: [1])
        #expect(throws: WireError.duplicateField(tag: 1)) { try r.requiredUInt(1) }
        #expect(throws: WireError.missingField(tag: 2)) { try r.requiredUInt(2) }
        #expect(r.all(1).count == 2)
    }

    @Test func trailingBytesInUInt() throws {
        var t = TLVWriter()
        t.bytes(1, [0x01, 0x00])
        let r = try TLVReader(t.bytes, knownTags: [1])
        #expect(throws: WireError.self) { try r.requiredUInt(1) }
    }

    @Test func invalidUTF8() throws {
        var t = TLVWriter()
        t.bytes(1, [0xC3, 0x28])
        let r = try TLVReader(t.bytes, knownTags: [1])
        #expect(throws: WireError.invalidUTF8) { try r.requiredString(1) }
    }

    @Test func narrowing() throws {
        #expect(try UInt64(65_535).narrowed(to: UInt16.self, field: "x") == 65_535)
        #expect(throws: WireError.self) { try UInt64(65_536).narrowed(to: UInt16.self, field: "x") }
    }
}

@Suite("Messages")
struct MessageTests {
    static let phoneHello = Hello(protoMinor: 0, appVersion: "0.1.0", build: 1, capabilities: [.hevc444Decode, .hevc420Decode, .refinementFrames, .benchBarcode],
                                  displayModes: [.laptop, .flat, .book, .cover], maxFps: 120, deviceName: "iPhone Duo")

    @Test func helloRoundTrip() throws {
        let h = Self.phoneHello
        #expect(try Hello(h.message) == h)
    }

    @Test func helloForwardCompatible() throws {
        // A future minor version adds a non-critical field: today's decoder still accepts it.
        var body = Self.phoneHello.encodeBody()
        var t = TLVWriter()
        t.string(42, "future")
        body += t.bytes
        let decoded = try Hello(body: body)
        #expect(decoded == Self.phoneHello)
    }

    @Test func helloRejectsUnknownCritical() {
        var body = Self.phoneHello.encodeBody()
        var t = TLVWriter()
        t.uint(0x8000 | 42, 1)
        body += t.bytes
        #expect(throws: WireError.unsupportedCritical(tag: 0x8000 | 42)) { try Hello(body: body) }
    }

    @Test func helloRequiresVersion() {
        var t = TLVWriter()
        t.string(3, "0.1.0")
        #expect(throws: WireError.missingField(tag: 1)) { try Hello(body: t.bytes) }
    }

    @Test func badDisplayModeRejected() {
        var mode = ByteWriter()
        mode.varint(939); mode.varint(667); mode.varint(0); mode.varint(120)   // scale 0
        var t = TLVWriter()
        t.uint(1, 1); t.uint(2, 0); t.bytes(6, mode.bytes)
        #expect(throws: WireError.self) { try Hello(body: t.bytes) }
    }

    @Test func displayModePixels() {
        #expect(DisplayMode.laptop.widthPixels == 1878)
        #expect(DisplayMode.flat.heightPixels == 1878)
    }

    @Test func controlRoundTrips() throws {
        let ping = Ping(id: 7, t1: 123_456_789)
        #expect(try Ping(ping.message) == ping)
        let pong = Pong(id: 7, t1: 1, t2: 2, t3: 3)
        #expect(try Pong(pong.message) == pong)
        for r in [GoodbyeReason.userDisconnected, .revoked, .paused, .shuttingDown, .unknown(77)] {
            #expect(try Goodbye(Goodbye(reason: r).message) == Goodbye(reason: r))
        }
        for r in [KeyframeReason.sessionStart, .frameLost, .decoderError, .formatChanged, .unknown(9)] {
            let k = KeyframeRequest(reason: r, lastGoodFrameId: 41)
            #expect(try KeyframeRequest(k.message) == k)
        }
        let inc = Incompatible(requiredMajor: 2, peerMajor: 1, hint: .updatePhone)
        #expect(try Incompatible(inc.message) == inc)
    }

    @Test func videoRoundTrips() throws {
        let f = VideoFormat(generation: 3, codec: .hevc, widthPixels: 1878, heightPixels: 1334, chroma: .yuv444,
                            fullRange: true, parameterSets: [[0x40, 0x01], [0x42, 0x01, 0x01], [0x44, 0x01]])
        #expect(try VideoFormat(f.message) == f)
        let frag = VideoFragment(frameId: 99, index: 2, count: 5, flags: [.keyframe, .longTermReference],
                                 formatGeneration: 3, captureTimeNs: 1_000_000_123, payload: [1, 2, 3, 4])
        #expect(try VideoFragment(frag.message) == frag)
        #expect(frag.encodeBody().count == VideoFragment.headerSize + 4)
    }

    @Test func videoFormatNeedsParameterSets() {
        let f = VideoFormat(generation: 1, codec: .hevc, widthPixels: 2, heightPixels: 2, chroma: .yuv420, fullRange: false, parameterSets: [])
        #expect(throws: WireError.missingField(tag: 7)) { try VideoFormat(body: f.encodeBody()) }
    }

    @Test func fragmentIndexValidated() {
        let bad = VideoFragment(frameId: 1, index: 3, count: 3, flags: [], formatGeneration: 0, captureTimeNs: 0, payload: [])
        #expect(throws: WireError.self) { try VideoFragment(body: bad.encodeBody()) }
        let zero = VideoFragment(frameId: 1, index: 0, count: 0, flags: [], formatGeneration: 0, captureTimeNs: 0, payload: [])
        #expect(throws: WireError.self) { try VideoFragment(body: zero.encodeBody()) }
    }

    @Test func wrongTypeRejected() {
        #expect(throws: WireError.self) { try Ping(Pong(id: 1, t1: 1, t2: 1, t3: 1).message) }
    }
}

@Suite("Envelope")
struct EnvelopeTests {
    @Test func innerMessagesBackToBack() throws {
        let msgs = [Ping(id: 1, t1: 2).message,
                    InnerMessage(channel: .unknown(9), type: .unknown(0x7777), flags: .redundant, body: [9, 9]),
                    Goodbye(reason: .paused).message]
        let decoded = try InnerMessage.decodeAll(InnerMessage.encodeAll(msgs))
        #expect(decoded == msgs)
        #expect(decoded[1].channel == .unknown(9))
        #expect(decoded[1].type == .unknown(0x7777))
    }

    @Test func truncatedInnerMessage() {
        var bytes = Ping(id: 1, t1: 2).message.encoded
        bytes.removeLast()
        #expect(throws: WireError.self) { try InnerMessage.decodeAll(bytes) }
    }

    @Test func rawValuesStable() {
        // These numbers are on the wire; changing one breaks every deployed peer.
        #expect(OuterPacketType.handshakeInitiation.rawValue == 0x01)
        #expect(OuterPacketType.handshakeResponse.rawValue == 0x02)
        #expect(OuterPacketType.cookieReply.rawValue == 0x03)
        #expect(OuterPacketType.transport.rawValue == 0x04)
        #expect([Channel.control, .video, .input, .clipboard, .files, .audio].map(\.rawValue) == [0, 1, 2, 3, 4, 5])
        #expect([MessageType.hello, .incompatible, .ping, .pong, .goodbye, .keyframeRequest, .receiverReport, .hostStats, .hostState, .videoFormat, .videoFragment].map(\.rawValue)
                == [0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0010, 0x0011, 0x0020, 0x0021, 0x0101, 0x0102])
        for v in UInt8.min...UInt8.max { #expect(OuterPacketType(rawValue: v).rawValue == v) }
    }

    @Test func negotiation() {
        let mac = Hello(protoMajor: 1, protoMinor: 3, appVersion: "m", build: 1, capabilities: [.hevc444Decode, .ltr, .fecRS], deviceName: "Mac")
        let phone = Hello(protoMajor: 1, protoMinor: 1, appVersion: "p", build: 1, capabilities: [.ltr, .audioOpus], deviceName: "Duo")
        #expect(Negotiation.negotiate(mac: mac, phone: phone) == .compatible(minor: 1, capabilities: [.ltr]))

        let newPhone = Hello(protoMajor: 2, protoMinor: 0, appVersion: "p", build: 1, capabilities: [], deviceName: "Duo")
        #expect(Negotiation.negotiate(mac: mac, phone: newPhone)
                == .incompatible(Incompatible(requiredMajor: 2, peerMajor: 1, hint: .updateMac)))
        let oldPhone = Hello(protoMajor: 0, protoMinor: 9, appVersion: "p", build: 1, capabilities: [], deviceName: "Duo")
        #expect(Negotiation.negotiate(mac: mac, phone: oldPhone)
                == .incompatible(Incompatible(requiredMajor: 1, peerMajor: 0, hint: .updatePhone)))
    }
}
