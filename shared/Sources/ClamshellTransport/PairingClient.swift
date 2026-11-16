import ClamshellSession
import Synchronization

/// Phone side of pairing over one path (LAN UDP): repeats the current step every 400 ms until the Mac
/// moves it on, reports the SAS, and returns the Mac's key, `psk_session` and endpoint once confirmed.
public enum PairingClient {
    public enum Failure: Error, Equatable, Sendable { case timedOut, rejected, wrongMac, failed }

    public static func pair(path: any PacketPath, identity: StaticIdentity, invite: PairingInvite, phoneName: String,
                            timeout: Duration = .seconds(120),
                            onSAS: @escaping @Sendable (String) -> Void) async throws -> (mac: PeerConfig, endpoint: PairingAccept) {
        var flow: PairingInitiator
        do { flow = try PairingInitiator(identity: identity, invite: invite, phoneName: phoneName) } catch { throw Failure.failed }
        try await path.start()
        let current = Mutex(flow.currentPacket)
        let resender = Task {
            let deadline = ContinuousClock.now + timeout
            while !Task.isCancelled, ContinuousClock.now < deadline {
                path.send([current.withLock { $0 }])
                try? await Task.sleep(for: .milliseconds(400))
            }
            path.stop()                                     // ends `datagrams`, so the loop below returns
        }
        defer { resender.cancel(); path.stop() }
        for await d in path.datagrams {
            let event: PairingInitiator.Event
            do { event = try flow.handle(d) } catch PairingError.wrongMac { throw Failure.wrongMac } catch { throw Failure.failed }
            switch event {
            case .none: continue
            case .showSAS(let sas):
                let p = flow.currentPacket
                current.withLock { $0 = p }
                path.send([p])
                onSAS(sas)
            case .accepted(let mac, let endpoint): return (mac, endpoint)
            case .rejected: throw Failure.rejected
            }
        }
        throw Failure.timedOut
    }
}
