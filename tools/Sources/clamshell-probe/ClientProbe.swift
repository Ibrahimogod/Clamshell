import ClamshellBench
import ClamshellRateControl
import ClamshellSession
import ClamshellStream
import ClamshellTransport
import ClamshellWire
import Darwin
import Foundation
import Synchronization

/// A stand-in phone on the Mac itself: pairs with a running Clamshell Host (its pairing window open, e.g.
/// `CLAMSHELL_PAIR_ON_START=1 CLAMSHELL_PAIR_AUTOCONFIRM=1`), connects (Bonjour or host:port), decodes the stream with the real client pipeline and reports fps, losses,
/// decode time and capture→decoded latency. Host and probe share `CLOCK_UPTIME_RAW`, so no clock sync.
enum ClientProbe {
    static func run(_ args: Args) async throws {
        guard let raw = args.string("invite") ?? ProcessInfo.processInfo.environment["CLAMSHELL_PAIR_INVITE"],
              let invite = PairingInvite(string: raw) else {
            throw ProbeFailure("pass --invite CLAMPAIR1:… (the host prints it when its pairing window opens) or set CLAMSHELL_PAIR_INVITE")
        }
        let seconds = args.double("seconds", 10)
        let udp: UDPClient
        if let host = args.string("host") {
            udp = UDPClient(host: host, port: UInt16(args.int("port", 0)))
            print("connecting to \(host):\(args.int("port", 0))")
        } else {
            let browser = BonjourBrowser()
            browser.start()
            var found: BonjourBrowser.Found?
            for await list in browser.results { if let f = list.first { found = f; break } }
            browser.stop()
            guard let found else { throw ProbeFailure("no Clamshell host found via Bonjour") }
            print("connecting to \(found.name) (Bonjour)")
            udp = UDPClient(endpoint: found.endpoint)
        }
        // `--v10` behaves like a protocol 1.0 phone: no reports, no FEC (compatibility check).
        let legacy = args.flag("v10")
        var caps: Capabilities = legacy ? [.hevc420Decode, .refinementFrames] : [.hevc420Decode, .refinementFrames, .receiverReports, .fecXor]
        if args.flag("444") { caps.insert(.hevc444Decode) }
        let hello = Hello(protoMinor: legacy ? 0 : ProtocolVersion.minor, appVersion: "0.1.0", build: 1, capabilities: caps, displayModes: [.laptop], maxFps: 120, deviceName: "clamshell-probe")
        // Pair first (each run is a new probe identity), over the same address the session will use.
        let identity = StaticIdentity()
        let pairHost = args.string("host") ?? invite.addresses.first ?? "127.0.0.1"
        let pairPort = args.string("host") != nil ? UInt16(args.int("port", Int(invite.port))) : invite.port
        let (mac, _) = try await PairingClient.pair(path: UDPClient(host: pairHost, port: pairPort, name: "pair"), identity: identity,
                                                    invite: invite, phoneName: "clamshell-probe", timeout: .seconds(20)) { sas in
            print("pairing: SAS \(sas) (confirm on the Mac unless it auto-confirms)")
        }
        let conn = ClientSessionConnection(udp: udp, identity: identity, server: mac, hello: hello)
        let t0 = ContinuousClock.now
        let macHello = try await conn.connect(timeout: .seconds(5))
        print("connected to \(macHello.deviceName) in \(fmt(ms(ContinuousClock.now - t0), 1)) ms")

        let reports = !legacy && macHello.capabilities.contains(.receiverReports)
        var sendReport: (@Sendable (ReceiverReport) -> Void)?
        if reports {
            sendReport = { @Sendable (r: ReceiverReport) in
                let m = r.message
                Task { await conn.send([m]) }
            }
        }
        let pipeline = ClientVideoPipeline(requestKeyframe: { req in Task { await conn.send([req.message]) } }, sendReport: sendReport)
        pipeline.start()
        let hostStats = Mutex<HostStats?>(nil)
        let hostState = Mutex<HostState?>(nil)
        let rtt = Mutex<LatencyStats>(LatencyStats(capacity: 10_000))
        Task.detached {
            for await batch in conn.messages {
                pipeline.handle(batch)
                for m in batch {
                    switch m.type {
                    case .hostStats: hostStats.withLock { $0 = try? HostStats(m) }
                    case .hostState: hostState.withLock { $0 = try? HostState(m) }
                    case .pong:
                        // id 0 is the transport's keepalive, timed on another clock: not ours.
                        guard let p = try? Pong(m), p.id != Ping.keepaliveId else { continue }
                        let t4 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        // Same clock on both ends: RTT minus the Mac's own processing time.
                        let ns = Int64(t4) - Int64(p.t1) - (Int64(p.t3) - Int64(p.t2))
                        pipeline.setRoundTrip(nanoseconds: ns)
                        rtt.withLock { $0.add(Double(ns) / 1e6) }
                    default: continue
                    }
                }
            }
        }
        Task.detached {
            var id: UInt32 = 0
            while !Task.isCancelled {
                id &+= 1
                await conn.send([Ping(id: id, t1: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)).message])
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        var latency = LatencyStats(capacity: 100_000)
        var lastId: UInt32 = 0
        var window = (frames: 0, start: ContinuousClock.now)
        let end = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < end {
            if let pic = pipeline.latest.take(), pic.frameId != lastId {
                lastId = pic.frameId
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                if now > pic.captureTimeNs { latency.add(Double(now - pic.captureTimeNs) / 1e6) }
                window.frames += 1
            }
            if ContinuousClock.now - window.start >= .seconds(1) {
                let s = pipeline.currentStats
                print("\(window.frames) fps presented · decoded \(s.framesDecoded) (\(s.keyframes) key, \(s.refinements) refine) · lost \(s.framesLost) · decode \(fmt(s.lastDecodeMs)) ms · \(s.chroma) hw=\(s.hardwareDecoder.map(String.init) ?? "?") · capture→decoded p50 \(fmt(latency.p50)) p95 \(fmt(latency.p95)) ms")
                if let h = hostStats.withLock({ $0 }) {
                    let st = hostState.withLock { $0 }
                    let rate = st.map { " · target \(fmt(Double($0.targetBitrateKbps) / 1000, 1)) Mbit/s · FEC \($0.fecPercent)% · screen \($0.screen)" } ?? ""
                    print("    mac: sent \(h.framesSent) · encode \(fmt(Double(h.encodeMicros) / 1000)) ms · encoder drops \(h.encoderDrops) · skipped busy \(h.skippedWhileBusy) · refine \(h.refinements)\(rate)")
                }
                window = (0, .now)
            }
            try await Task.sleep(for: .microseconds(500))
        }
        let s = pipeline.currentStats
        print("\n## summary (\(Int(seconds)) s)")
        print("frames decoded \(s.framesDecoded), keyframes \(s.keyframes), refinements \(s.refinements), lost \(s.framesLost), decoder errors \(s.decoderErrors), keyframe requests \(s.keyframeRequests)")
        print("received \(fmt(Double(s.bytesReceived) / 1e6, 1)) MB → \(fmt(Double(s.bytesReceived) * 8 / seconds / 1e6, 1)) Mbit/s")
        print("capture→decoded latency ms: p50 \(fmt(latency.p50)) · p95 \(fmt(latency.p95)) · n \(latency.count)")
        let r = rtt.withLock { $0 }
        print("ping rtt ms: p50 \(fmt(r.p50)) · p95 \(fmt(r.p95)) · n \(r.count)")
        if let st = hostState.withLock({ $0 }) {
            print("final rate: \(fmt(Double(st.targetBitrateKbps) / 1000, 1)) Mbit/s, FEC \(st.fecPercent)%")
        }
        print("PROBE_SUMMARY decoded=\(s.framesDecoded) lost=\(s.framesLost) keyreq=\(s.keyframeRequests) mbps=\(fmt(Double(s.bytesReceived) * 8 / seconds / 1e6, 1)) p50=\(fmt(latency.p50)) p95=\(fmt(latency.p95)) target=\(hostState.withLock { $0 }.map { String($0.targetBitrateKbps) } ?? "-") fec=\(hostState.withLock { $0 }.map { String($0.fecPercent) } ?? "-")")
        pipeline.stop()
        await conn.close()
    }
}
