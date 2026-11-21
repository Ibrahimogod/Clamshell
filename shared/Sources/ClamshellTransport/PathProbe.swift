import ClamshellSession
import ClamshellWire

/// Network check (M3): does one path reach the Mac, and how fast? Sends a real handshake initiation and
/// waits for an authentic response, then stops. The session is never confirmed, so the Mac doesn't start
/// streaming and drops the half-open session after 10 s.
public enum PathProbe {
    public enum Result: Sendable, Equatable {
        case reachable(rttMs: Double)
        case noAnswer
        case failed(String)
    }

    public static func check(_ path: any PacketPath, identity: StaticIdentity, mac: PeerConfig, hello: Hello,
                             timeout: Duration = .seconds(2)) async -> Result {
        var hs: ClientHandshake
        do { hs = try ClientHandshake(identity: identity, server: mac, payload: [hello.message]) } catch { return .failed("\(error)") }
        do {
            try await withThrowingTaskGroup(of: Void.self) { g in
                g.addTask { try await path.start() }
                g.addTask { try await Task.sleep(for: timeout); throw CancellationError() }
                try await g.next()
                g.cancelAll()
            }
        } catch {
            path.stop()
            return .noAnswer
        }
        defer { path.stop() }
        let started = ContinuousClock.now
        let packet = hs.initiationPacket
        let resend = Task {
            while !Task.isCancelled {
                path.send([packet])
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        let stopper = Task {
            try? await Task.sleep(for: timeout)
            path.stop()
        }
        defer { resend.cancel(); stopper.cancel() }
        var heard = 0
        for await d in path.datagrams {
            heard += 1
            guard d.first == OuterPacketType.handshakeResponse.rawValue else { continue }
            if (try? hs.complete(response: d, now: .now)) != nil {
                let c = (ContinuousClock.now - started).components
                return .reachable(rttMs: Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
            }
        }
        return heard == 0 ? .noAnswer : .failed("\(heard) packets came back, none a valid answer")
    }
}
