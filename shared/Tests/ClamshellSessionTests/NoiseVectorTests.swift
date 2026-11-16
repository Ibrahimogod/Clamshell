import CryptoKit
import Foundation
import Testing
import ClamshellWire
@testable import ClamshellSession

/// Checks our IKpsk2 against the Cacophony test vector (independent implementation), byte for byte.
@Suite("Noise IKpsk2 test vector")
struct NoiseVectorTests {
    struct Message { let payload: [UInt8]; let ciphertext: [UInt8] }
    struct Vector {
        let prologue: [UInt8]
        let psk: [UInt8]
        let initStatic: [UInt8], initEphemeral: [UInt8], initRemoteStatic: [UInt8]
        let respStatic: [UInt8], respEphemeral: [UInt8]
        let handshakeHash: [UInt8]
        let messages: [Message]
    }

    static func load() throws -> Vector {
        let url = try #require(Bundle.module.url(forResource: "Vectors", withExtension: nil))
            .appendingPathComponent("IKpsk2_25519_ChaChaPoly_SHA256.json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let v = try #require((root["vectors"] as? [[String: Any]])?.first)
        func hex(_ key: String) throws -> [UInt8] { try #require((v[key] as? String).flatMap { [UInt8](hex: $0) }, "\(key)") }
        let psks = try #require(v["init_psks"] as? [String])
        let msgs = try #require(v["messages"] as? [[String: String]]).map { m in
            Message(payload: [UInt8](hex: m["payload"] ?? "") ?? [], ciphertext: [UInt8](hex: m["ciphertext"] ?? "") ?? [])
        }
        return Vector(prologue: try hex("init_prologue"), psk: try #require([UInt8](hex: psks[0])),
                      initStatic: try hex("init_static"), initEphemeral: try hex("init_ephemeral"),
                      initRemoteStatic: try hex("init_remote_static"), respStatic: try hex("resp_static"),
                      respEphemeral: try hex("resp_ephemeral"), handshakeHash: try hex("handshake_hash"), messages: msgs)
    }

    @Test func matchesCacophony() throws {
        let v = try Self.load()
        try #require(v.messages.count == 6)
        let iS = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.initStatic)
        let iE = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.initEphemeral)
        let rS = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.respStatic)
        let rE = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.respEphemeral)
        #expect(Array(rS.publicKey.rawRepresentation) == v.initRemoteStatic)

        var initiator = try IKpsk2Initiator(localStatic: iS, remoteStatic: v.initRemoteStatic, psk: v.psk, prologue: v.prologue, ephemeral: iE)
        var responder = IKpsk2Responder(localStatic: rS, prologue: v.prologue, ephemeral: rE)

        let m1 = try initiator.writeMessage1(payload: v.messages[0].payload)
        #expect(m1 == v.messages[0].ciphertext)
        let read1 = try responder.readMessage1(m1)
        #expect(read1.initiatorStatic == Array(iS.publicKey.rawRepresentation))
        #expect(read1.payload == v.messages[0].payload)

        let w2 = try responder.writeMessage2(payload: v.messages[1].payload, psk: v.psk)
        #expect(w2.message == v.messages[1].ciphertext)
        let read2 = try initiator.readMessage2(w2.message)
        #expect(read2.payload == v.messages[1].payload)

        #expect(read2.keys.handshakeHash == v.handshakeHash)
        #expect(w2.keys.handshakeHash == v.handshakeHash)
        #expect(read2.keys.send == w2.keys.receive)
        #expect(read2.keys.receive == w2.keys.send)

        // Transport phase: messages alternate initiator→responder, responder→initiator.
        var iSend = CipherState(key: read2.keys.send), iRecv = CipherState(key: read2.keys.receive)
        var rSend = CipherState(key: w2.keys.send), rRecv = CipherState(key: w2.keys.receive)
        for (i, m) in v.messages.enumerated().dropFirst(2) {
            if i % 2 == 0 {
                do { let ok = (try iSend.encrypt(ad: [], plaintext: m.payload) == m.ciphertext); #expect(ok, "transport message \(i)") }
                do { let ok = (try rRecv.decrypt(ad: [], ciphertext: m.ciphertext) == m.payload); #expect(ok) }
            } else {
                do { let ok = (try rSend.encrypt(ad: [], plaintext: m.payload) == m.ciphertext); #expect(ok, "transport message \(i)") }
                do { let ok = (try iRecv.decrypt(ad: [], ciphertext: m.ciphertext) == m.payload); #expect(ok) }
            }
        }
    }

    @Test func wrongPSKFailsAtMessage2() throws {
        let v = try Self.load()
        let iS = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.initStatic)
        let rS = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.respStatic)
        var initiator = try IKpsk2Initiator(localStatic: iS, remoteStatic: v.initRemoteStatic, psk: v.psk, prologue: v.prologue)
        var responder = IKpsk2Responder(localStatic: rS, prologue: v.prologue)
        _ = try responder.readMessage1(try initiator.writeMessage1(payload: []))
        var other = v.psk
        other[0] ^= 1
        let w2 = try responder.writeMessage2(payload: [], psk: other)
        #expect(throws: NoiseError.decryptFailed) { try initiator.readMessage2(w2.message) }
    }

    @Test func prologueMismatchFails() throws {
        let v = try Self.load()
        let iS = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.initStatic)
        let rS = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.respStatic)
        var initiator = try IKpsk2Initiator(localStatic: iS, remoteStatic: v.initRemoteStatic, psk: v.psk, prologue: [1])
        var responder = IKpsk2Responder(localStatic: rS, prologue: [2])
        #expect(throws: NoiseError.decryptFailed) { try responder.readMessage1(try initiator.writeMessage1(payload: [])) }
    }

    @Test func lowOrderPointRejected() throws {
        let s = Curve25519.KeyAgreement.PrivateKey()
        // All-zero public key gives an all-zero shared secret.
        #expect(throws: NoiseError.self) { try Noise.dh(s, [UInt8](repeating: 0, count: 32)) }
    }

    @Test func messageLengths() {
        #expect(IKpsk2.message1Length(payload: 16) == 112)
        #expect(IKpsk2.message2Length(payload: 15) == 63)
    }
}
