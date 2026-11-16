import CryptoKit
import Foundation
import Testing
import ClamshellWire
@testable import ClamshellSession

@Suite("Pairing (XXpsk3 + SAS)")
struct XXPairingTests {
    let mac = StaticIdentity()
    let phone = StaticIdentity()

    func invite(_ key: [UInt8]? = nil) -> PairingInvite {
        PairingInvite(macPublicKey: key, secret: PairingInvite.newSecret(), macName: "Studio Mac", port: 51820, addresses: ["192.168.1.20"])
    }

    @Test func xxpsk3RoundTrip() throws {
        let psk = [UInt8](repeating: 7, count: 32)
        var i = try XXpsk3Initiator(localStatic: phone.privateKey, psk: psk, prologue: [1])
        var r = try XXpsk3Responder(localStatic: mac.privateKey, psk: psk, prologue: [1])
        #expect(try r.readMessage1(try i.writeMessage1(payload: [9])) == [9])
        #expect(try i.readMessage2(try r.writeMessage2(payload: [8])) == [8])
        #expect(i.remoteStatic == mac.publicKey)
        let m3 = try i.writeMessage3(payload: [7])
        let read = try r.readMessage3(m3.message)
        #expect(read.payload == [7])
        #expect(r.remoteStatic == phone.publicKey)
        #expect(read.keys.send == m3.keys.receive && read.keys.receive == m3.keys.send)
        #expect(read.keys.handshakeHash == m3.keys.handshakeHash)
    }

    @Test func wrongPSKFailsAtMessage3() throws {
        var i = try XXpsk3Initiator(localStatic: phone.privateKey, psk: [UInt8](repeating: 1, count: 32), prologue: [])
        var r = try XXpsk3Responder(localStatic: mac.privateKey, psk: [UInt8](repeating: 2, count: 32), prologue: [])
        // psk mode encrypts the empty msg1 payload under a key from e alone, so msg1 and msg2 still pass.
        _ = try r.readMessage1(try i.writeMessage1(payload: []))
        _ = try i.readMessage2(try r.writeMessage2(payload: []))
        #expect(throws: NoiseError.self) { try r.readMessage3(try i.writeMessage3(payload: []).message) }
    }

    @Test func fullPairingFlow() throws {
        let inv = invite(mac.publicKey)
        var window = PairingWindow(identity: mac, invite: inv, now: .now)
        var p = try PairingInitiator(identity: phone, invite: try #require(PairingInvite(string: inv.string)), phoneName: "Duo")

        guard case .reply(let m2) = window.handle(p.currentPacket, now: .now) else { Issue.record("no msg2"); return }
        // A repeated msg1 gets the cached msg2.
        #expect(window.handle(p.currentPacket, now: .now) == .reply(m2))
        guard case .showSAS(let phoneSAS) = try p.handle(m2) else { Issue.record("no SAS"); return }
        guard case .request(let req) = window.handle(p.currentPacket, now: .now) else { Issue.record("no request"); return }
        #expect(req.sas == phoneSAS)
        #expect(req.sas.count == 6)
        #expect(req.phoneKey == phone.publicKey)
        #expect(req.phoneName == "Duo")
        #expect(window.pending.count == 1)

        let (packet, peer) = try window.confirm(req.id, accept: PairingAccept(accepted: true, udpPort: 51820, tcpPort: 443, publicHost: "home.example"))
        // A repeated msg3 (lost step 4) gets the same answer.
        #expect(window.handle(p.currentPacket, now: .now) == .reply(packet))
        guard case .accepted(let macPeer, let endpoint) = try p.handle(packet) else { Issue.record("not accepted"); return }
        #expect(macPeer.publicKey == mac.publicKey)
        #expect(macPeer.psk == peer.psk)
        #expect(macPeer.name == "Studio Mac")
        #expect(endpoint.publicHost == "home.example" && endpoint.tcpPort == 443)

        // The stored keys work for a normal IKpsk2 session.
        var responder = HostResponder(identity: mac, peers: [peer])
        let hs = try ClientHandshake(identity: phone, server: macPeer, payload: [])
        let accepted = try responder.handleInitiation(hs.initiationPacket, now: .now) { _ in [] }
        #expect(accepted.isKnownPeer)
    }

    @Test func manualCodeLearnsKeyFromHandshake() throws {
        let inv = invite(mac.publicKey)
        let typed = try #require(PairingInvite(string: inv.manualCode.lowercased()))
        #expect(typed.secret == inv.secret && typed.macPublicKey == nil)
        #expect(inv.manualCode.count == 19)
        var window = PairingWindow(identity: mac, invite: inv, now: .now)
        var p = try PairingInitiator(identity: phone, invite: typed, phoneName: "Duo")
        guard case .reply(let m2) = window.handle(p.currentPacket, now: .now),
              case .showSAS = try p.handle(m2),
              case .request(let req) = window.handle(p.currentPacket, now: .now) else { Issue.record("flow"); return }
        guard case .accepted(let m, _) = try p.handle(try window.confirm(req.id, accept: PairingAccept(accepted: true)).packet) else {
            Issue.record("not accepted"); return
        }
        #expect(m.publicKey == mac.publicKey)
    }

    @Test func impostorMacIsRefused() throws {
        let other = StaticIdentity()
        let inv = invite(mac.publicKey)
        var window = PairingWindow(identity: other, invite: inv, now: .now)   // knows the secret, wrong key
        var p = try PairingInitiator(identity: phone, invite: inv, phoneName: "Duo")
        guard case .reply(let m2) = window.handle(p.currentPacket, now: .now) else { Issue.record("no msg2"); return }
        #expect(throws: PairingError.wrongMac) { try p.handle(m2) }
    }

    @Test func wrongSecretThreeTimesClosesTheWindow() throws {
        let inv = invite(mac.publicKey)
        var window = PairingWindow(identity: mac, invite: inv, now: .now)
        var outputs: [PairingWindow.Output] = []
        for _ in 0..<3 {
            var guess = inv
            guess.secret = PairingInvite.newSecret()
            var p = try PairingInitiator(identity: StaticIdentity(), invite: guess, phoneName: "x")
            guard case .reply(let m2) = window.handle(p.currentPacket, now: .now) else { Issue.record("no msg2"); return }
            _ = try p.handle(m2)
            outputs.append(window.handle(p.currentPacket, now: .now))
        }
        #expect(outputs == [.none, .none, .closed])
        #expect(window.isClosed)
        var late = try PairingInitiator(identity: phone, invite: inv, phoneName: "Duo")
        #expect(window.handle(late.currentPacket, now: .now) == .none)
        _ = try late.handle([])
    }

    @Test func windowExpires() throws {
        let inv = invite(mac.publicKey)
        let start = ContinuousClock.now
        var window = PairingWindow(identity: mac, invite: inv, now: start, duration: .seconds(120))
        let p = try PairingInitiator(identity: phone, invite: inv, phoneName: "Duo")
        #expect(window.handle(p.currentPacket, now: start + .seconds(121)) == .closed)
    }

    @Test func rejectTellsThePhone() throws {
        let inv = invite(mac.publicKey)
        var window = PairingWindow(identity: mac, invite: inv, now: .now)
        var p = try PairingInitiator(identity: phone, invite: inv, phoneName: "Duo")
        guard case .reply(let m2) = window.handle(p.currentPacket, now: .now), case .showSAS = try p.handle(m2),
              case .request(let req) = window.handle(p.currentPacket, now: .now) else { Issue.record("flow"); return }
        let rejected = window.reject(req.id)
        let packet = try #require(rejected)
        #expect(try p.handle(packet) == .rejected)
    }

    @Test func codesRoundTrip() throws {
        let inv = invite(mac.publicKey)
        #expect(PairingInvite(string: inv.string) == inv)
        #expect(Base32.decode(Base32.encode([0, 1, 2, 250, 255])) == [0, 1, 2, 250, 255])
        #expect(PairingInvite(string: "CLAMPAIR1:!!") == nil)
        #expect(PairingInvite(string: "ABCD") == nil)
    }
}
