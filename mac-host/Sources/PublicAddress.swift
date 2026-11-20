import ClamshellHome
import ClamshellKeychain
import CryptoKit
import Foundation
import Network
import Observation
import Synchronization
import UserNotifications

/// The Mac's public (router WAN) address and the name phones dial to reach it (ADR-0005):
/// - with the router's admin password saved (Keychain), the Mac signs in to the TP-Link VR400's web UI
///   once a minute, reads the WAN address and signs out again. It skips a round when someone is signed
///   in there (signing in would throw them out) and stops for good after the router turns the password
///   down, until a new one is saved (a few wrong tries lock the web UI);
/// - otherwise it asks the router over NAT-PMP (RFC 6886) every 10 minutes, when the router answers it;
/// - with a DuckDNS (or deSEC) name and token saved, every new address is pointed at by that name, and
///   the phone is given the name instead of the address, so it finds the Mac after a change on its own;
/// - an address typed in the pairing window (UserDefaults `publicHost`) is the last resort.
///
/// Every change is logged to `ip-churn.json` (hashed addresses + time) and shown as a notification.
@MainActor @Observable
final class PublicAddressMonitor {
    /// The WAN address as last read from the router.
    private(set) var learned: String?
    private(set) var source = ""
    /// One line each for the settings window and the menu.
    private(set) var routerStatus = ""
    private(set) var dnsStatus = ""
    /// Called with what phones should dial (`effective`) whenever that, or the address behind it, changes.
    var onChange: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private let logURL: URL?
    private let keychain: KeychainStore?

    private var routerPassword: String?
    /// The router turned the saved password down: don't use it again until a new one is saved.
    private var passwordRejected = false
    private var routerFailures = 0
    private var dnsToken: String?
    private var dnsBlocked = false
    private var dnsNotBefore = Date.distantPast
    private var lastNATPMP = Date.distantPast
    private var lastDNS: (ip: String, at: Date)?

    static let routerPasswordAccount = "router-password"
    static let dnsTokenAccount = "dns-token"

    init(directory: URL?, keychain: KeychainStore?) {
        logURL = directory?.appendingPathComponent("ip-churn.json")
        self.keychain = keychain
        routerPassword = Self.secret(keychain, Self.routerPasswordAccount)
        dnsToken = Self.secret(keychain, Self.dnsTokenAccount)
    }

    var dnsName: String {
        DynamicDNS.normalize(UserDefaults.standard.string(forKey: "dnsHostname") ?? "")
    }
    var hasRouterPassword: Bool { routerPassword != nil }
    var hasDNSToken: Bool { dnsToken != nil }

    private var manual: String {
        (UserDefaults.standard.string(forKey: "publicHost") ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// What phones dial: the dynamic DNS name when set up, else a typed DNS name, else the router's address,
    /// else whatever was typed.
    var effective: String? {
        if !dnsName.isEmpty, dnsToken != nil { return dnsName }
        if !manual.isEmpty, IPv4(manual) == nil, DynamicDNS.isHostname(manual) { return manual }
        return learned ?? (manual.isEmpty ? nil : manual)
    }

    /// The home's address as a number, for telling home sessions from away ones.
    var ip: String? { learned ?? (IPv4(manual) != nil ? manual : nil) }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: settings

    func saveRouterPassword(_ password: String) {
        let p = password.isEmpty ? nil : password
        store(p, Self.routerPasswordAccount)
        routerPassword = p
        passwordRejected = false
        routerStatus = p == nil ? "" : "Router: password saved, reading…"
        Task { await refresh() }
    }

    func saveDNS(name: String, token: String?) {
        UserDefaults.standard.set(DynamicDNS.normalize(name), forKey: "dnsHostname")
        if let token {
            let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
            store(t.isEmpty ? nil : t, Self.dnsTokenAccount)
            dnsToken = t.isEmpty ? nil : t
        }
        dnsBlocked = false
        dnsNotBefore = .distantPast
        lastDNS = nil
        dnsStatus = ""
        Task {
            await updateDNS()
            if let e = effective { onChange?(e) }
        }
    }

    // MARK: reading

    func refresh() async {
        let before = learned
        if let password = routerPassword, !passwordRejected {
            await readRouter(password)
        } else if Date().timeIntervalSince(lastNATPMP) >= 600 {
            lastNATPMP = .now
            if let gw = await Self.gateway(), let ip = await Self.natpmpExternal(gateway: gw) {
                source = "router (NAT-PMP)"
                adopt(ip)
            }
        }
        await updateDNS()
        if learned != before, let e = effective { onChange?(e) }
    }

    private func readRouter(_ password: String) async {
        guard let gw = await Self.gateway() else { routerStatus = "Router: no network"; return }
        let router = TPLinkRouter(host: gw) { print($0) }
        do {
            let reading = try await router.readWAN(password: password)
            routerFailures = 0
            source = "router"
            routerStatus = "Router: \(reading.address)" + (reading.address.isPublic ? "" : reading.address.isCarrierNAT
                ? " — carrier NAT (100.64/10): the ISP shares this address, port forwarding can't work"
                : " — not a public address")
            adopt(reading.address.description)
        } catch RouterError.wrongPassword(let code) {
            passwordRejected = true
            routerStatus = "Router: the password was turned down (code \(code)). Type it again in Home address…"
            print("router: password turned down (\(code)); not trying again until a new one is saved")
            notify(id: "clamshell.router", title: "Router password not accepted",
                   body: "Clamshell stopped signing in to the router so it doesn't get locked. Enter the password again under Home address….")
        } catch let e as RouterError {
            if case .someoneSignedIn = e {
                if learned == nil { routerStatus = "Router: \(e)" }
                return
            }
            failed("\(e)")
        } catch {
            failed(error.localizedDescription)
        }
    }

    /// The VR400's web server now and then answers a request with HTTP 500. Keep showing the last good
    /// reading through a few of those; only three failures in a row are worth showing (and logging).
    private func failed(_ why: String) {
        routerFailures += 1
        if routerFailures == 3 || learned == nil { routerStatus = "Router: \(why)" }
        if routerFailures == 3 { print("router: \(why) (3 reads in a row failed)") }
    }

    private func adopt(_ ip: String) {
        guard ip != learned else { return }
        let previous = learned
        learned = ip
        let same = log(ip)
        print("public address: \(ip)" + (previous.map { " (was \($0))" } ?? ""))
        // Announce real changes only, including one that happened while the Mac app wasn't running.
        guard !same else { return }
        let name = (!dnsName.isEmpty && dnsToken != nil) ? " Phones reach it as \(dnsName)." : ""
        notify(id: "clamshell.address", title: "Home address changed", body: "The router's public address is now \(ip).\(name)")
    }

    // MARK: dynamic DNS

    private func updateDNS() async {
        let name = dnsName
        guard !name.isEmpty, let token = dnsToken, !dnsBlocked, let current = learned,
              let address = IPv4(current), address.isPublic, Date() >= dnsNotBefore else { return }
        if let last = lastDNS, last.ip == current, Date().timeIntervalSince(last.at) < 86400 { return }
        let outcome = await DynamicDNS.update(hostname: name, address: address, token: token)
        let service = DynamicDNS.provider(for: name).rawValue
        switch outcome {
        case .updated:
            lastDNS = (current, .now)
            dnsStatus = "\(service): \(name) → \(current)"
            print("\(service): \(name) → \(current)")
        case .badAuth:
            dnsBlocked = true
            dnsStatus = "\(service): the token or name was turned down. Check both in Home address…"
            print("\(service): token or name turned down")
        case .throttled(let after):
            dnsNotBefore = Date().addingTimeInterval(after ?? 300)
            dnsStatus = "\(service): \(outcome)"
        case .failed:
            dnsNotBefore = Date().addingTimeInterval(120)
            dnsStatus = "\(service): \(outcome)"
            print("\(service): \(outcome)")
        }
    }

    // MARK: helpers

    private func notify(id: String, title: String, body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    private static func secret(_ keychain: KeychainStore?, _ account: String) -> String? {
        guard let d = try? keychain?.data(account) else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    private func store(_ value: String?, _ account: String) {
        guard let keychain else { return }
        do {
            if let value { try keychain.set(Data(value.utf8), for: account) } else { try keychain.delete(account) }
        } catch {
            print("keychain: couldn't save \(account): \(error)")
        }
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

    /// Logs a new address; true if it isn't a change (the very first address, or the one logged last).
    @discardableResult
    private func log(_ ip: String) -> Bool {
        guard let logURL else { return true }
        var entries = readLog()
        let hash = SHA256.hash(data: Data(("clamshell-ip:" + ip).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        if entries.last?.hash == hash { return true }
        let first = entries.isEmpty
        entries.append(Entry(at: .now, hash: hash, first: first))
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries.suffix(500)).write(to: logURL, options: .atomic)
        return first
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
