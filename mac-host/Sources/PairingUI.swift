import AppKit
import ClamshellKeychain
import ClamshellSession
import ClamshellTransport
import CoreImage.CIFilterBuiltins
import Darwin
import LocalAuthentication
import Network
import SwiftUI

/// A phone on the allow-list (ADR-0014): its static key, the `psk_session` from pairing, a name.
struct PairedDevice: Codable, Identifiable, Equatable {
    var publicKey: Data
    var psk: Data
    var name: String
    var created: Date
    var id: Data { publicKey }

    var peer: PeerConfig { PeerConfig(publicKey: [UInt8](publicKey), psk: [UInt8](psk), name: name) }
}

/// The allow-list, as one Keychain item (`ThisDeviceOnly`, never synced). In-memory only with ephemeral keys.
@MainActor
final class DeviceStore {
    static let limit = 8
    private let keychain: KeychainStore?
    private(set) var devices: [PairedDevice] = []

    init(keychain: KeychainStore?) {
        self.keychain = keychain
        if let d = try? keychain?.data("peers"), let list = try? JSONDecoder().decode([PairedDevice].self, from: d) { devices = list }
    }

    func add(_ peer: PeerConfig) throws {
        devices.removeAll { $0.publicKey == Data(peer.publicKey) }
        devices.append(PairedDevice(publicKey: Data(peer.publicKey), psk: Data(peer.psk), name: peer.name, created: .now))
        try save()
    }

    func remove(_ key: Data) throws {
        devices.removeAll { $0.publicKey == key }
        try save()
    }

    private func save() throws {
        guard let keychain else { return }
        try keychain.set(try JSONEncoder().encode(devices), for: "peers")
    }
}

/// What the pairing window shows.
@MainActor
@Observable
final class PairingState {
    let invite: PairingInvite
    let qr: NSImage?
    let deadline: Date
    var requests: [PairingWindow.Request] = []
    var message = ""
    var done = false

    init(invite: PairingInvite, seconds: Double) {
        self.invite = invite
        qr = Self.qrImage(invite.string)
        deadline = Date().addingTimeInterval(seconds)
    }

    static func qrImage(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: out.extent.width / 2, height: out.extent.height / 2))
    }
}

struct PairingView: View {
    let state: PairingState
    let confirm: (UInt32) -> Void
    let reject: (UInt32) -> Void
    let cancel: () -> Void
    @AppStorage("publicHost") private var publicHost = ""

    var body: some View {
        VStack(spacing: 14) {
            if state.done {
                Label(state.message, systemImage: "checkmark.circle.fill").font(.title3)
                Button("Done") { cancel() }.keyboardShortcut(.defaultAction)
            } else if state.requests.isEmpty {
                Text("Pair a new iPhone").font(.title2.bold())
                Text("In Clamshell on the phone, tap Pair with this Mac and scan the code. The phone must be on this Wi-Fi.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                if let qr = state.qr { Image(nsImage: qr).interpolation(.none).resizable().frame(width: 220, height: 220) }
                Text("No camera? Type this code on the phone:").font(.callout)
                Text(state.invite.manualCode).font(.title2.monospaced()).textSelection(.enabled)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(state.deadline.timeIntervalSince(ctx.date)))
                    Text(left > 0 ? "Open for \(left) s" : "Closed. Open a new pairing window from the menu.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Away-from-home address (optional)").font(.callout)
                    TextField("your router's public IP or DNS name", text: $publicHost).textFieldStyle(.roundedBorder)
                    Text("Given to the phone when it pairs, for use on mobile data or other Wi-Fi. Needs TCP 443 and UDP 443 forwarded to this Mac (docs/SETUP.md).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
            } else {
                Text("Do the digits match the phone?").font(.title2.bold())
                ForEach(state.requests) { r in
                    VStack(spacing: 6) {
                        Text(r.phoneName.isEmpty ? "iPhone" : r.phoneName).font(.headline)
                        Text(String(r.sas.prefix(3)) + " " + String(r.sas.suffix(3))).font(.system(size: 40, weight: .semibold, design: .monospaced))
                        HStack {
                            Button("Doesn't match") { reject(r.id) }
                            Button("Pair") { confirm(r.id) }.keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                if state.requests.count > 1 {
                    Text("More than one phone answered. If you're pairing only one, someone else may have the code: reject the one whose digits differ.")
                        .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                if !state.message.isEmpty { Text(state.message).font(.callout).foregroundStyle(.red) }
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

enum PairingSupport {
    /// The person at the Mac proves they're the owner (admin password or Touch ID) before a window opens.
    static func authorize() async -> Bool {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "open a window to pair a new iPhone")) ?? false
    }

    /// Private IPv4 addresses of interfaces that are up (for the QR code).
    static func lanAddresses() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let s = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let h = IPv4Address(s), isLocalAddress(.ipv4(h)), !s.hasPrefix("169.254.") { out.append(s) }
        }
        return out
    }
}

/// Hosts the pairing view in a small floating window (the menu-bar popover closes when it loses focus).
@MainActor
final class PairingWindowController {
    private var window: NSWindow?

    func show(_ view: some View) {
        let w = window ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Pair iPhone"
        w.contentViewController = NSHostingController(rootView: view)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}
