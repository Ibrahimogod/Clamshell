import ClamshellHome
import Foundation
import Observation

/// Opens Clamshell's two ports on the router over UPnP (ADR-0005 amendment), so nobody has to set up port
/// forwarding by hand, and the forward follows the Mac when its address on the home network changes.
///
/// Each mapping is asked for with a one-hour lease and renewed every 30 minutes, and again at once when the
/// Mac's own address changes or the router has lost it (checked every minute: a restart wipes them), so a
/// forward never outlives the Mac by more than an hour. Mappings are named "Clamshell"; a Clamshell mapping that points at an old address of this Mac is replaced, a mapping
/// someone else made on the same port is left alone and reported.
///
/// Off (UserDefaults `upnpPortMapping` = false) it removes its own mappings and does nothing else.
@MainActor @Observable
final class PortForwarder {
    /// One line for the Home address window.
    private(set) var status = ""
    /// Set when the ports could not be opened (shown in the menu).
    private(set) var problem = ""

    static let description = "Clamshell"
    static let lease = 3600
    static let renewEvery: TimeInterval = 1800

    private var ports: [PortProtocol: UInt16] = [:]
    private var paused = false
    private var gateway: UPnPGateway?
    private var gatewayHost: String?
    /// What the router currently forwards to us, per protocol (to remove on pause or switch-off).
    private var open: [PortProtocol: (port: UInt16, client: String)] = [:]
    private var local: String?
    private var nextRenewal = Date.distantPast
    private var permanentOnly = false
    private var task: Task<Void, Never>?
    private var working = false

    /// UserDefaults `upnpPortMapping` (on unless switched off).
    var enabled = UserDefaults.standard.object(forKey: "upnpPortMapping") as? Bool ?? true {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: "upnpPortMapping")
            Task { enabled ? await renewNow() : await closeAll(status: "Off: forward the ports by hand on the router.") }
        }
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// A port Clamshell listens on (or nil when it stopped listening).
    func set(_ proto: PortProtocol, _ port: UInt16?) {
        ports[proto] = port
        Task { await renewNow() }
    }

    /// Remote access paused: no forwards while it is.
    func setPaused(_ on: Bool) {
        paused = on
        Task { on ? await closeAll(status: "Closed while remote access is paused.") : await renewNow() }
    }

    func renewNow() async {
        nextRenewal = .distantPast
        await tick()
    }

    private func tick() async {
        guard enabled, !paused, !ports.isEmpty, !working else { return }
        working = true
        defer { working = false }
        guard let gw = await PublicAddressMonitor.gateway(), let me = UPnPGateway.localAddress(toward: gw) else {
            status = "Waiting for the network…"
            return
        }
        if me == local, Date() < nextRenewal {
            // A router that restarted, or whose internet connection came back, forgets its forwards (the
            // VR400 even drops ones made while it was still coming up): look for them once a minute.
            guard await forwardsLost(at: gw, me: me) else { return }
            print("port forwarding: the router lost the forwards (restarted?); opening them again")
        }
        if me != local, let old = local { print("port forwarding: this Mac moved from \(old) to \(me) on the home network") }
        local = me

        guard let gateway = await gateway(at: gw) else {
            report(problem: "The router doesn't answer UPnP. Turn UPnP on in its settings (NAT Forwarding › UPnP), or forward the ports by hand.")
            nextRenewal = Date().addingTimeInterval(600)
            return
        }

        var done: [String] = [], trouble: [String] = []
        for proto in PortProtocol.allCases {
            guard let port = ports[proto] else { continue }
            do {
                try await map(port, proto, to: me, on: gateway)
                open[proto] = (port, me)
                done.append("\(proto.rawValue) \(port)")
            } catch let e as UPnPError where e.code < 0 {
                // The router's UPnP server went away (restart, new router): look it up again next time.
                self.gateway = nil
                trouble.append("\(proto.rawValue) \(port): \(e)")
            } catch {
                trouble.append("\(proto.rawValue) \(port): \(error)")
            }
        }
        nextRenewal = Date().addingTimeInterval(trouble.isEmpty ? Self.renewEvery : 300)
        if trouble.isEmpty {
            let text = "\(done.joined(separator: " and ")) → \(me)" + (permanentOnly ? " (the router only keeps permanent forwards)" : "")
            if status != "Open: " + text { print("port forwarding: " + text) }
            status = "Open: " + text
            problem = ""
        } else {
            report(problem: (done.isEmpty ? "" : "Open: \(done.joined(separator: ", ")). ") + "Couldn't open " + trouble.joined(separator: "; "))
        }
    }

    private func map(_ port: UInt16, _ proto: PortProtocol, to me: String, on g: UPnPGateway) async throws {
        if let existing = try await g.mapping(port, proto), existing.internalClient != me {
            // Ours from an old address of this Mac (or another Mac running Clamshell): take it over.
            // Anyone else's: leave it, and say so.
            guard existing.description.hasPrefix(Self.description) else {
                throw UPnPError(code: UPnPError.conflict, text: "the router already forwards it to \(existing.internalClient) (\(existing.description))")
            }
            try? await g.delete(port, proto)
        }
        var m = PortMapping(externalPort: port, proto: proto, internalPort: port, internalClient: me,
                            description: Self.description, leaseSeconds: permanentOnly ? 0 : Self.lease)
        do {
            try await g.add(m)
        } catch let e as UPnPError where e.code == UPnPError.onlyPermanentLeases && !permanentOnly {
            permanentOnly = true
            m.leaseSeconds = 0
            try await g.add(m)
        } catch let e as UPnPError where e.code == UPnPError.conflict {
            throw UPnPError(code: e.code, text: "another device has that port on the router")
        } catch let e as UPnPError where e.code == UPnPError.notAuthorized {
            throw UPnPError(code: e.code, text: "the router doesn't let devices open ports (UPnP is read-only there)")
        }
    }

    /// True when a forward this Mac made is gone from the router or points elsewhere.
    private func forwardsLost(at host: String, me: String) async -> Bool {
        guard let g = await gateway(at: host) else { return false }
        for (proto, m) in open {
            do {
                guard let now = try await g.mapping(m.port, proto), now.internalClient == me else { return true }
            } catch let e as UPnPError where e.code < 0 {
                gateway = nil   // not answering (restarting): look it up again next minute
                return false
            } catch {
                return false
            }
        }
        return false
    }

    /// Removes the forwards this Mac made (on pause, or when switched off).
    private func closeAll(status text: String) async {
        let mine = open
        open = [:]
        local = nil
        nextRenewal = .distantPast
        if !mine.isEmpty, let gw = await PublicAddressMonitor.gateway() {
            let g = await gateway(at: gw)
            for (proto, m) in mine {
                // Only if it's still ours: another Mac may have taken the port over since.
                if let g, let now = try? await g.mapping(m.port, proto), now.internalClient == m.client {
                    try? await g.delete(m.port, proto)
                }
            }
            print("port forwarding: closed \(mine.map { "\($0.key.rawValue) \($0.value.port)" }.sorted().joined(separator: ", "))")
        }
        status = text
        problem = ""
    }

    /// The router's public (WAN) address, asked over UPnP whether or not the ports are opened here; nil when
    /// the router doesn't answer.
    func publicAddress() async -> String? {
        guard let gw = await PublicAddressMonitor.gateway(), let g = await gateway(at: gw) else { return nil }
        do {
            return try await g.externalAddress()
        } catch let e as UPnPError where e.code < 0 {
            gateway = nil   // the router's UPnP server went away (restart): look it up again next time
            return nil
        } catch {
            return nil
        }
    }

    /// The router's UPnP service, looked up again when the default gateway changes or it stopped answering.
    private func gateway(at host: String) async -> UPnPGateway? {
        if gateway == nil || gatewayHost != host {
            gateway = await UPnPGateway.discover(gateway: host)
            gatewayHost = host
        }
        return gateway
    }

    private func report(problem text: String) {
        if problem != text { print("port forwarding: " + text) }
        problem = text
        status = text
    }
}
