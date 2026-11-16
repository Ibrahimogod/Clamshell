import CryptoKit
import Foundation
import Network
import Synchronization

/// The Mac's public (router WAN) address, learned without any third party (ADR-0005):
/// - NAT-PMP "external address" request to the default gateway (RFC 6886, opcode 0). It opens no ports;
///   routers answer it when NAT-PMP/PCP is on, which on many models comes with UPnP;
/// - otherwise the address typed in the pairing window (UserDefaults `publicHost`) is used as is.
/// Router readout over the VR400 admin page (the ADR's choice (a)) needs the router and its admin
/// password; it's not built yet (CHANGELOG, M3).
///
/// Every change is logged to `ip-churn.json` (hashed addresses + time) for the 30-day decision.
@MainActor
final class PublicAddressMonitor {
    private(set) var learned: String?
    private(set) var source = ""
    var onChange: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private let logURL: URL?

    init(directory: URL?) {
        logURL = directory?.appendingPathComponent("ip-churn.json")
    }

    /// Manual entry wins; NAT-PMP otherwise.
    var effective: String? {
        let manual = (UserDefaults.standard.string(forKey: "publicHost") ?? "").trimmingCharacters(in: .whitespaces)
        return manual.isEmpty ? learned : manual
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    func refresh() async {
        guard let gw = await Self.gateway(), let ip = await Self.natpmpExternal(gateway: gw) else { return }
        source = "router (NAT-PMP)"
        guard ip != learned else { return }
        let first = learned == nil
        learned = ip
        log(ip, first: first)
        onChange?(ip)
    }

    /// Changes in the last 30 days (not counting the first sighting).
    var changesLast30Days: Int {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        return readLog().filter { $0.at > cutoff && !$0.first }.count
    }

    private struct Entry: Codable { var at: Date; var hash: String; var first: Bool }

    private func readLog() -> [Entry] {
        guard let logURL, let d = try? Data(contentsOf: logURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: d)) ?? []
    }

    private func log(_ ip: String, first: Bool) {
        guard let logURL else { return }
        var entries = readLog()
        let hash = SHA256.hash(data: Data(("clamshell-ip:" + ip).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        if entries.last?.hash == hash { return }
        entries.append(Entry(at: .now, hash: hash, first: first && entries.isEmpty))
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries.suffix(500)).write(to: logURL, options: .atomic)
    }

    /// `route -n get default` → the gateway's IPv4 address.
    nonisolated static func gateway() async -> String? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/route")
            p.arguments = ["-n", "get", "default"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0] == "gateway", IPv4Address(parts[1]) != nil { return parts[1] }
            }
            return nil
        }.value
    }

    /// RFC 6886 §3.2: request `[0, 0]`, response `[0, 128, result(2), epoch(4), address(4)]`.
    nonisolated static func natpmpExternal(gateway: String, timeout: Duration = .seconds(1)) async -> String? {
        let c = NWConnection(host: NWEndpoint.Host(gateway), port: 5351, using: .udp)
        let result = Mutex<CheckedContinuation<String?, Never>?>(nil)
        @Sendable func finish(_ v: String?) {
            result.withLock { k in k?.resume(returning: v); k = nil }
            c.cancel()
        }
        return await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
            result.withLock { $0 = k }
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    c.send(content: Data([0, 0]), completion: .idempotent)
                    c.receiveMessage { data, _, _, _ in
                        guard let d = data.map([UInt8].init), d.count >= 12, d[0] == 0, d[1] == 128, d[2] == 0, d[3] == 0 else { finish(nil); return }
                        finish("\(d[8]).\(d[9]).\(d[10]).\(d[11])")
                    }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            c.start(queue: .global(qos: .utility))
            Task { try? await Task.sleep(for: timeout); finish(nil) }
        }
    }
}
