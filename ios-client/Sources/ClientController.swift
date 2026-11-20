import ClamshellBench
import ClamshellFiles
import ClamshellKeychain
import ClamshellInput
import LocalAuthentication
import ClamshellSession
import ClamshellStream
import ClamshellTransport
import ClamshellWire
import CryptoKit
import Darwin
import Foundation
import Observation
import Synchronization
import UIKit
import AVFAudio

/// The phone's single clock for latency maths: `CLOCK_UPTIME_RAW` ns, the same base as
/// `CACurrentMediaTime()` and `CADisplayLink` timestamps.
enum PhoneClock {
    static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    static func ns(fromMediaTime t: CFTimeInterval) -> UInt64 { UInt64(max(t, 0) * 1e9) }
}

@MainActor
@Observable
final class HUDModel {
    var presentedFps = 0.0
    var decodedFps = 0.0
    var mbps = 0.0
    var decodeMs = 0.0
    var encodeMs = 0.0
    var keyframes = 0
    var refinements = 0
    var framesLost = 0
    var hostDrops = 0
    var hostSkipped = 0
    var chroma = "4:2:0"
    var latencyP50: Double?
    var latencyP95: Double?
    var latencySamples = 0

    /// Glass-to-glass from the camera test, or nil when it's off.
    var glassText: String?
    /// From the Mac's `HostState`: what its own screen is doing, and the rate controller's choice.
    var macScreen: MacScreenState = .active
    var macLocalUser = false
    var macKeepsAwake = false
    var rateText = ""
    var rttMs: Double?
    var migrations = 0
    /// The path carrying the session: "lan", "udp" or "tcp" (WSS on 443).
    var pathName = ""
    /// Whether the Mac may post keyboard and mouse events (nil: a Mac without input, or not reported yet).
    var inputAllowed: Bool?
    /// 1.8 Macs: whether the Clamshell Microphone is installed there; the window streamed alone; its frame rate.
    var micReady: Bool?
    var window: String?
    var macFps = 0
    /// 1.9 Macs: whether the Mac's own screen is hidden, and its keyboard and trackpad off (nil: not reported).
    var macCurtain: Bool?
    var macInputBlocked: Bool?

    /// A banner over the stream when the Mac's screen isn't what the user expects to see.
    var macBanner: String? {
        switch macScreen {
        case _ where macLocalUser: "Someone is using the Mac. Your input is paused until they stop."
        case .locked: "The Mac is locked."
        case .screenSaver: macKeepsAwake ? "The Mac's screen saver is running." : "The Mac's screen saver is running (move the mouse at the Mac)."
        default:
            inputAllowed == false ? "Allow keyboard & mouse on the Mac: menu bar › Clamshell Host › Allow keyboard & mouse control." : nil
        }
    }

    var latencyText: String {
        guard let p50 = latencyP50, let p95 = latencyP95 else { return "barcode latency: waiting for patch + clock sync" }
        return String(format: "barcode draw→present p50 %.1f · p95 %.1f ms (n %d)", p50, p95, latencySamples)
    }
}

/// M1 client: Bonjour discovery, dev-code pairing, one Noise session, the video pipeline and the HUD.
@MainActor
@Observable
final class ClientController {
    enum Phase: Equatable { case idle, connecting(String), streaming(String), failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var hosts: [BonjourBrowser.Found] = []
    /// The Macs this phone paired with (ADR-0014), from the Keychain. `pairedMac` is the one selected: the
    /// away-from-home address fields and Connect are about it.
    private(set) var macs: [PairedMac] = []
    private(set) var selectedMacKey: Data? = UserDefaults.standard.data(forKey: "selectedMac") {
        didSet { UserDefaults.standard.set(selectedMacKey, forKey: "selectedMac") }
    }
    var pairedMac: PairedMac? { macs.first { $0.publicKey == selectedMacKey } ?? macs.first }
    var isPaired: Bool { !macs.isEmpty }
    /// The Mac of the session being set up or streamed (its learned address is saved to it).
    private var connectedMacKey: Data?
    enum PairingStatus: Equatable { case idle, working, sas(String), failed(String) }
    private(set) var pairingStatus: PairingStatus = .idle
    /// Ask for Touch ID before connecting (ADR-0014; default on, skipped where the phone has no biometrics).
    /// The Mac's sound on this phone (M5). Off at connect means the Mac doesn't capture audio at all.
    var sound = UserDefaults.standard.object(forKey: "sound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sound, forKey: "sound"); audio?.muted = !sound }
    }
    private var audio: AudioPlayer? { didSet { audioSink.player = audio } }
    /// The player the receive task feeds (it changes when the microphone turns on or off).
    @ObservationIgnored private let audioSink = AudioSink()
    var requireBiometrics = UserDefaults.standard.object(forKey: "requireBiometrics") as? Bool ?? true {
        didSet { UserDefaults.standard.set(requireBiometrics, forKey: "requireBiometrics") }
    }
    private var unlockedAt: Date?
    /// `host:port` (or `[v6]:port`) for a Mac that Bonjour can't see: a remote network, or the netsim relay.
    /// The selected Mac's away-from-home address (each paired Mac keeps its own).
    var manualAddress = UserDefaults.standard.string(forKey: "manualAddress") ?? "" {
        didSet {
            UserDefaults.standard.set(manualAddress, forKey: "manualAddress")
            updateSelected { $0.address = manualAddress }
        }
    }
    var manualAddressValid: Bool { Self.parse(manualAddress, defaultPort: awayUDPPort) != nil }
    /// The Mac's TCP fallback port (TLS + WebSocket, path P3); 0 turns the fallback off.
    var tcpPort = UserDefaults.standard.object(forKey: "tcpPort") as? Int ?? 443 {
        didSet {
            UserDefaults.standard.set(tcpPort, forKey: "tcpPort")
            if let p = UInt16(exactly: tcpPort) { updateSelected { $0.tcpPort = p } }
        }
    }
    /// The battery and heat saver: how fast to ask the Mac to stream (1.1).
    var powerSaver = PowerSaverMode(rawValue: UserDefaults.standard.string(forKey: "powerSaver") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(powerSaver.rawValue, forKey: "powerSaver"); updateFrameRateCap() }
    }
    /// The cap in force (0: none), for the HUD and the display link.
    private(set) var frameRateCap: UInt16 = 0
    @ObservationIgnored private var powerObservers: [NSObjectProtocol] = []
    /// Files the Mac sent (1.1), newest first; they live in Files › On My iPhone › Clamshell › From Mac.
    private(set) var receivedFiles: [URL] = []
    var showHUD = false
    let hud = HUDModel()
    private(set) var pipeline: ClientVideoPipeline?
    /// Keyboard, trackpad and cursor, while streaming to a Mac that takes input.
    private(set) var input: InputClient?
    /// A hardware keyboard or mouse attached to the phone, forwarded while streaming (M4).
    private(set) var hardware: HardwareInput?
    /// How the Duo is held (ADR-0012), and the per-posture choices.
    let posture = PostureModel()
    /// Key size, which of keyboard and trackpad strip show, and the strip's size (Layout › Keyboard & trackpad).
    var deck = ClientController.loadDeck() {
        didSet { if let d = try? JSONEncoder().encode(deck) { UserDefaults.standard.set(d, forKey: "deckSettings") } }
    }
    private static func loadDeck() -> DeckSettings {
        if let d = UserDefaults.standard.data(forKey: "deckSettings"), let s = try? JSONDecoder().decode(DeckSettings.self, from: d) { return s }
        return DeckSettings(legacyDeckMode: UserDefaults.standard.string(forKey: "deckMode"))
    }
    /// Pinch on the picture zooms the phone's view of it (the Mac doesn't change).
    let pictureZoom = PictureZoom()
    /// Flat and book: a touch on the picture is a click there (true), or the picture is a trackpad (false).
    /// Off (the default since 1.0.1): the picture is a trackpad, as on a MacBook. On: touch clicks where you touch.
    var directTouch = UserDefaults.standard.object(forKey: "directTouchOnPicture") as? Bool ?? false {
        didSet { UserDefaults.standard.set(directTouch, forKey: "directTouchOnPicture") }
    }
    /// The Mac's display mode now (it follows the posture on a 1.4 Mac).
    private(set) var displayMode = DisplayMode.laptop
    private var macMinor: UInt16 = 0
    private(set) var macCaps: Capabilities = []
    private var sendingFile: String?
    /// Mac → phone clipboard: writes the phone's pasteboard when the Mac's changes (off by default).
    var clipboardSync = UserDefaults.standard.bool(forKey: "clipboardSync") {
        didSet { UserDefaults.standard.set(clipboardSync, forKey: "clipboardSync") }
    }
    private(set) var lastClipboardNote: String?
    private var bulkOut = BulkSender()
    private var bulkIn = BulkReceiver()
    private var clipboardCount: UInt64 = 0
    /// Files and folders to the Mac and from it (1.9): any size, resumed after a dropped connection.
    @ObservationIgnored private var fileQueue = FileSendQueue()
    /// The Mac `fileQueue` belongs to; connecting to another Mac drops it.
    @ObservationIgnored private var fileMac: Data?
    @ObservationIgnored private let fileReceiver = FileReceiver(root: ClientController.receivedFolder
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("From Mac", isDirectory: true))
    /// Picked files and folders stay readable (security-scoped) while they are being sent.
    @ObservationIgnored private var scopedPicks: [URL] = []
    @ObservationIgnored private var reportedFiles: Set<UInt32> = []
    @ObservationIgnored private var lastTransferUpdate = ContinuousClock.now
    /// What is being sent or received, and how far (nil: nothing).
    private(set) var transferText = ""
    private(set) var transferFraction: Double?

    /// Presentation-side counters, written by the renderer on the main actor.
    var presentedFrames = 0
    private(set) var latency = LatencyStats(capacity: 2000)
    private(set) var clock = ClockSync()

    private let keychain = KeychainStore(service: "dev.clamshell.client")
    private var browser: BonjourBrowser?
    private var connection: ClientSessionConnection?
    private var udp: PathRacer?
    /// Whether the current race has the Mac's LAN path (false after connecting by address before Bonjour saw it).
    private var raceHasLAN = false
    private var tasks: [Task<Void, Never>] = []
    private var lastStats: (at: ContinuousClock.Instant, decoded: Int, bytes: Int, presented: Int)?
    private var pingId: UInt32 = 0

    /// Harness B on one device: the rear camera watches the Mac's flash square (FlashProbe.swift).
    var cameraTestEnabled = false
    private var cameraProbe: CameraFlashProbe?
    private var cameraStatus = ""
    private var cameraFps = 0.0
    private var screenFlash = FlashEdgeDetector(fixedThreshold: 128, interpolates: false)
    private var flashMatcher = FlashMatcher()
    private var hudTicks = 0
    var flashTestRunning: Bool { cameraProbe != nil }

    /// The Simulator has no hardware HEVC decoder; a real phone must never fall back to software.
    #if targetEnvironment(simulator)
    static let requireHardwareDecode = false
    #else
    static let requireHardwareDecode = true
    #endif

    /// Launch arguments for runs started from the Mac (`xcrun devicectl device process launch …`):
    /// `--camera-test` turns the glass-to-glass camera test on, `--auto-connect` connects to the first Mac found.
    private let autoConnect = CommandLine.arguments.contains("--auto-connect")
    /// `--host <host:port>` connects there instead of to a Bonjour result (with `--auto-connect`).
    private let launchHost: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--host"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()

    init() {
        if let h = launchHost { manualAddress = h }
        if CommandLine.arguments.contains("--camera-test") { cameraTestEnabled = true }
        if let d = try? keychain.data("paired-macs"), let list = try? JSONDecoder().decode([PairedMac].self, from: d) {
            macs = list
        } else if let d = try? keychain.data("paired-mac"), var one = try? JSONDecoder().decode(PairedMac.self, from: d) {
            one.address = manualAddress.isEmpty ? nil : manualAddress          // 1.0: one Mac, address in defaults
            macs = [one]
            saveMacs()
        }
        if let m = pairedMac { applySelection(m) }
        receivedFiles = Self.listReceivedFiles()
        setUpFileReceiver()
        startPowerWatch()
        try? keychain.delete("dev-code")                       // M1 development pairing is gone
        posture.onDisplayChange = { [weak self] p in self?.displayPostureChanged(p) }
        // `--posture flat|book|laptop|cover` pins a posture at launch (simulator tests have no hinge).
        if let i = CommandLine.arguments.firstIndex(of: "--posture"), i + 1 < CommandLine.arguments.count {
            posture.pinned = Posture(rawValue: CommandLine.arguments[i + 1])
        }
        // `--network-check` on a paired phone: Check connection once Bonjour has had a moment to look.
        if CommandLine.arguments.contains("--network-check"), pairedMac != nil {
            Task { try? await Task.sleep(for: .seconds(3)); runNetworkCheck() }
        }
    }

    // MARK: pairing (ADR-0014)

    /// Pairs with the Mac that shows `text` (QR string or the 16-character code). With only the code, the
    /// Mac is the one Bonjour finds, or the address field.
    func pair(code text: String) {
        guard let invite = PairingInvite(string: text) else {
            pairingStatus = .failed("That isn't a pairing code. Open Clamshell Host › Pair new iPhone… on the Mac.")
            return
        }
        var targets: [(String, UInt16)] = invite.addresses.map { ($0, invite.port) }
        let named = hosts.first { !invite.macName.isEmpty && $0.name == invite.macName } ?? hosts.first { h in !macs.contains { $0.name == h.name } } ?? hosts.first
        if targets.isEmpty, let found = named, case .hostPort(let h, let p) = found.endpoint { targets.append(("\(h)", p.rawValue)) }
        let bonjour = targets.isEmpty ? named?.endpoint : nil
        if targets.isEmpty, bonjour == nil, let (h, p) = Self.parse(manualAddress, defaultPort: awayUDPPort) { targets.append((h, p)) }
        guard !targets.isEmpty || bonjour != nil else {
            pairingStatus = .failed("No Mac found on this Wi-Fi. Pair at home, on the same network as the Mac.")
            return
        }
        pairingStatus = .working
        Task {
            do {
                let identity = try identity()
                let name = UIDevice.current.name
                // The Mac's first listed LAN address (or the Bonjour result when only the code was typed).
                let path: any PacketPath = if let bonjour { UDPClient(endpoint: bonjour, name: "pair") }
                    else { UDPClient(host: targets[0].0, port: targets[0].1, name: "pair") }
                let (mac, endpoint) = try await PairingClient.pair(path: path, identity: identity, invite: invite, phoneName: name) { sas in
                    Task { @MainActor in self.pairingStatus = .sas(sas) }
                }
                var record = PairedMac(publicKey: Data(mac.publicKey), psk: Data(mac.psk), name: mac.name, udpPort: endpoint.udpPort,
                                       tcpPort: endpoint.tcpPort, publicHost: endpoint.publicHost, paired: .now)
                if !endpoint.publicHost.isEmpty {
                    let h = endpoint.publicHost.contains(":") ? "[\(endpoint.publicHost)]" : endpoint.publicHost
                    record.address = "\(h):\(endpoint.udpPort)"
                }
                if endpoint.tcpPort == 0 { record.tcpPort = UInt16(clamping: tcpPort) }
                macs.removeAll { $0.publicKey == record.publicKey }
                macs.append(record)
                try saveMacsThrowing()
                applySelection(record)
                pairingStatus = .idle
                print("paired with \(mac.name)")
                if CommandLine.arguments.contains("--network-check") { runNetworkCheck() }
                if autoConnect, phase == .idle {
                    if launchHost != nil { connectManual() } else if let first = lanHost(for: record) { connect(to: first) }
                }
            } catch PairingClient.Failure.rejected {
                pairingStatus = .failed("The Mac said the digits didn't match. Try again.")
            } catch PairingClient.Failure.timedOut {
                pairingStatus = .failed("The Mac didn't answer. Is its pairing window still open, and is this phone on the same Wi-Fi?")
            } catch PairingClient.Failure.wrongMac {
                pairingStatus = .failed("A different Mac answered than the one that showed the code. Not paired.")
            } catch {
                pairingStatus = .failed("Pairing failed: \(error)")
            }
        }
    }

    func cancelPairingMessage() { pairingStatus = .idle }

    /// The Mac's away-from-home address (ADR-0005), newest `seq` wins. Fills the address field when it's
    /// empty or still holds the previous learned value. A hand-typed name is left alone; a hand-typed number
    /// gives way to a name from the Mac (its DuckDNS name), which keeps working after the address changes.
    private func learn(_ e: HomeEndpoint) {
        guard let i = macs.firstIndex(where: { $0.publicKey == connectedMacKey }) else { return }
        var mac = macs[i]
        guard !e.host.isEmpty, e.seq > mac.endpointSeq ?? 0 else { return }
        let h = e.host.contains(":") ? "[\(e.host)]" : e.host
        let old = mac.publicHost.isEmpty ? nil : (mac.publicHost.contains(":") ? "[\(mac.publicHost)]" : mac.publicHost) + ":\(mac.udpPort)"
        let current = mac.address ?? ""
        let typedNumber = Self.parse(current).map { Self.isAddressLiteral($0.host) } ?? false
        if current.isEmpty || current == old || (typedNumber && !Self.isAddressLiteral(e.host)) {
            if !current.isEmpty, current != old { print("# home endpoint: \(e.host) replaces the typed \(current)") }
            mac.address = "\(h):\(e.udpPort)"
        }
        mac.publicHost = e.host
        mac.udpPort = e.udpPort
        if e.tcpPort > 0 { mac.tcpPort = e.tcpPort }
        mac.endpointSeq = e.seq
        macs[i] = mac
        saveMacs()
        if mac.publicKey == pairedMac?.publicKey { applySelection(mac) }
        print("# home endpoint: \(e.host) udp \(e.udpPort) tcp \(e.tcpPort)")
    }

    // MARK: network check

    struct PathCheck: Identifiable, Equatable {
        let id: String
        var detail: String
        var ok: Bool?
    }
    private(set) var checks: [PathCheck] = []
    private(set) var checking = false

    /// Tries each path on its own (LAN, home UDP, TCP 443) with a real handshake; nothing streams.
    func runNetworkCheck() {
        guard let mac = pairedMac, !checking else { return }
        checking = true
        let peer = PeerConfig(publicKey: [UInt8](mac.publicKey), psk: [UInt8](mac.psk), name: mac.name)
        var plan: [(String, String, @Sendable () -> any PacketPath)] = []
        if let lan = lanHost(for: mac)?.endpoint { plan.append(("Same Wi-Fi (LAN)", "Bonjour", { UDPClient(endpoint: lan, name: "lan") })) }
        else { plan.append(("Same Wi-Fi (LAN)", "Mac not visible on this network", { DeadPath() })) }
        if let (h, p) = Self.parse(manualAddress, defaultPort: awayUDPPort) {
            plan.append(("Home, UDP \(p)", h, { UDPClient(host: h, port: p, name: "udp") }))
            if let tp = UInt16(exactly: tcpPort), tp > 0 {
                plan.append(("Home, TCP \(tp) (TLS)", h, { WSSClient(host: h, port: tp, name: "tcp") }))
            }
        } else {
            plan.append(("Away from home", "no address yet: connect once at home, or type it below", { DeadPath() }))
        }
        checks = plan.map { PathCheck(id: $0.0, detail: $0.1 + " …", ok: nil) }
        Task {
            guard let identity = try? identity() else { checking = false; return }
            for (name, detail, make) in plan {
                let r = await PathProbe.check(make(), identity: identity, mac: peer,
                                              hello: Hello(appVersion: AppVersion.short, build: AppVersion.build, capabilities: [], deviceName: "check"))
                guard let i = checks.firstIndex(where: { $0.id == name }) else { continue }
                switch r {
                case .reachable(let ms): checks[i] = PathCheck(id: name, detail: "\(detail) · \(Int(ms.rounded())) ms", ok: true)
                case .noAnswer: checks[i] = PathCheck(id: name, detail: "\(detail) · no answer", ok: false)
                case .failed(let e): checks[i] = PathCheck(id: name, detail: "\(detail) · \(e)", ok: false)
                }
                print("# check: \(checks[i].id): \(checks[i].detail)")
            }
            checking = false
        }
    }

    /// Forget a Mac (the selected one by default). Pairing again needs the Mac's owner and the home Wi-Fi.
    func forgetMac(_ mac: PairedMac? = nil) {
        guard let key = (mac ?? pairedMac)?.publicKey else { return }
        macs.removeAll { $0.publicKey == key }
        try? keychain.delete("paired-mac")                    // the 1.0 single-Mac record, if any
        saveMacs()
        if selectedMacKey == key { selectedMacKey = nil }
        if let m = pairedMac { applySelection(m) } else { manualAddress = "" }
    }

    /// Makes `mac` the one the address fields and Connect are about.
    func select(_ mac: PairedMac) {
        guard mac.publicKey != pairedMac?.publicKey || selectedMacKey == nil else { return }
        applySelection(mac)
    }

    /// `mac`'s away-from-home address: as typed or learned, else from the address it gave at pairing.
    func awayAddress(of mac: PairedMac) -> String {
        mac.address ?? (mac.publicHost.isEmpty ? "" : (mac.publicHost.contains(":") ? "[\(mac.publicHost)]" : mac.publicHost) + ":\(mac.udpPort)")
    }

    /// Whether Connect can reach `mac` now: on this Wi-Fi, or at a usable away-from-home address.
    func canConnect(_ mac: PairedMac) -> Bool { lanHost(for: mac) != nil || Self.parse(awayAddress(of: mac), defaultPort: mac.udpPort) != nil }

    private func applySelection(_ mac: PairedMac) {
        selectedMacKey = mac.publicKey
        let address = awayAddress(of: mac)
        if manualAddress != address { manualAddress = address }
        if mac.tcpPort > 0, tcpPort != Int(mac.tcpPort) { tcpPort = Int(mac.tcpPort) }
    }

    private func updateSelected(_ change: (inout PairedMac) -> Void) {
        guard let key = pairedMac?.publicKey, let i = macs.firstIndex(where: { $0.publicKey == key }) else { return }
        var m = macs[i]
        change(&m)
        guard m != macs[i] else { return }
        macs[i] = m
        saveMacs()
    }

    private func saveMacs() { try? saveMacsThrowing() }
    private func saveMacsThrowing() throws { try keychain.set(try JSONEncoder().encode(macs), for: "paired-macs") }

    /// The Bonjour result for `mac` on this Wi-Fi: by name, or the only Mac found when only one is paired.
    func lanHost(for mac: PairedMac) -> BonjourBrowser.Found? {
        hosts.first { $0.name == mac.name } ?? (macs.count == 1 && hosts.count == 1 ? hosts.first : nil)
    }

    // MARK: Siri, Shortcuts and the widget (1.1)

    /// A Mac to connect to once Bonjour has had a moment to look (the app was just opened by a link).
    @ObservationIgnored private var pendingConnect: PairedMac?

    /// `clamshell://connect` (optionally `?mac=Name`) and `clamshell://disconnect`, from the App Intents, the
    /// widget and the Control Center control. Connects on this Wi-Fi if the Mac shows up within 2 s, else
    /// at its away-from-home address.
    func open(_ url: URL) {
        guard url.scheme == "clamshell" else { return }
        switch url.host() {
        case "connect":
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "mac" }?.value
            guard let mac = macs.first(where: { $0.name == name }) ?? pairedMac else { return }
            switch phase {
            case .connecting, .streaming: return
            case .idle, .failed: break
            }
            select(mac)
            if lanHost(for: mac) != nil { connect(mac: mac); return }
            pendingConnect = mac
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard let m = pendingConnect, m.publicKey == mac.publicKey else { return }
                pendingConnect = nil
                connect(mac: m)
            }
        case "disconnect":
            disconnect()
        default:
            break
        }
    }

    /// Connect to `mac`: on this Wi-Fi if Bonjour sees it, else at its away-from-home address.
    func connect(mac: PairedMac) {
        select(mac)
        if let h = lanHost(for: mac) { connect(to: h) } else { connectManual() }
    }

    /// Touch ID before a session, at most every 5 minutes (skipped where there's no biometry).
    private func unlock() async -> Bool {
        guard requireBiometrics else { return true }
        if let t = unlockedAt, Date().timeIntervalSince(t) < 300 { return true }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else { return true }
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Connect to your Mac")) ?? false
        if ok { unlockedAt = Date() }
        return ok
    }

    var hevc444Text: String {
        switch DecodeProbe.cached444 {
        case true?: "hardware, verified"
        case false?: "not available (4:2:0 stream)"
        case nil: "not probed yet"
        }
    }

    func startBrowsing() {
        guard browser == nil else { return }
        if DecodeProbe.cached444 == nil { Task.detached { _ = DecodeProbe.run444Check() } }
        let b = BonjourBrowser()
        browser = b
        b.start()
        tasks.append(Task { [weak self] in
            for await list in b.results {
                guard let self else { return }
                hosts = list.sorted { $0.name < $1.name }
                joinLANIfFound()
                if let mac = pendingConnect, lanHost(for: mac) != nil { pendingConnect = nil; connect(mac: mac) }
                if autoConnect, launchHost == nil, phase == .idle, let mac = pairedMac, pairingStatus == .idle, let first = lanHost(for: mac) { connect(to: first) }
            }
        })
        if let invite = ProcessInfo.processInfo.environment["CLAMSHELL_PAIR_INVITE"], !isPaired || pairedMac.map({ PairingInvite(string: invite)?.macPublicKey != [UInt8]($0.publicKey) }) == true {
            pair(code: invite)                                 // automation: pair first, then auto-connect
        } else if autoConnect, launchHost != nil, phase == .idle { connectManual() }
    }

    /// Connected by address before Bonjour saw the Mac on this Wi-Fi: add the LAN path now. It ranks first,
    /// so the race moves the session onto it within a couple of seconds, off the router's loopback.
    private func joinLANIfFound() {
        guard let udp, !raceHasLAN, let mac = macs.first(where: { $0.publicKey == connectedMacKey }) else { return }
        switch phase {
        case .connecting, .streaming: break
        case .idle, .failed: return
        }
        guard let ep = lanHost(for: mac)?.endpoint else { return }
        raceHasLAN = true
        print("# path: the Mac is on this Wi-Fi now; adding the LAN path")
        udp.add(.init(rank: 0, delay: .zero) { UDPClient(endpoint: ep, name: "lan") })
    }

    /// An IPv4 or IPv6 address rather than a DNS name.
    static func isAddressLiteral(_ host: String) -> Bool {
        host.contains(":") || (host.split(separator: ".", omittingEmptySubsequences: false).count == 4
            && host.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") })
    }

    /// Splits `host:port`, `[v6]:port`, or a bare host or `[v6]`, which gets `defaultPort` (the Mac's UDP
    /// port). Nil if malformed.
    static func parse(_ text: String, defaultPort: UInt16 = ClientController.defaultUDPPort) -> (host: String, port: UInt16)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let host: Substring, port: Substring?
        if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
            host = t[t.index(after: t.startIndex)..<close]
            let rest = t[t.index(after: close)...]
            guard rest.isEmpty || rest.hasPrefix(":") else { return nil }
            port = rest.isEmpty ? nil : rest.dropFirst()
        } else if let colon = t.lastIndex(of: ":") {
            guard t.firstIndex(of: ":") == colon else { return nil }
            host = t[..<colon]
            port = t[t.index(after: colon)...]
        } else {
            host = Substring(t)
            port = nil
        }
        guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { return nil }
        guard let port else { return defaultPort > 0 ? (String(host), defaultPort) : nil }
        guard let p = UInt16(port), p > 0 else { return nil }
        return (String(host), p)
    }

    /// The UDP port for an away address typed without one: the selected Mac's.
    var awayUDPPort: UInt16 { pairedMac.map(\.udpPort).flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultUDPPort }
    /// The Mac's UDP port unless it was changed (docs/SETUP.md §6): 443, like HTTP/3, which mobile networks pass.
    /// The race also tries it when the saved port is another one, so a Mac moved to it isn't lost.
    nonisolated static let defaultUDPPort: UInt16 = 443

    func connectManual() {
        guard let (h, p) = Self.parse(manualAddress, defaultPort: awayUDPPort) else { return }
        connect(to: BonjourBrowser.Found(name: manualAddress, endpoint: .hostPort(host: .init(h), port: .init(rawValue: p) ?? .any)))
    }

    func connect(to host: BonjourBrowser.Found) {
        if let named = macs.first(where: { $0.name == host.name }) { select(named) }
        guard let mac = pairedMac else { return }
        connectedMacKey = mac.publicKey
        phase = .connecting(host.name)
        Task {
            guard await unlock() else { phase = .failed("Touch ID didn't match."); return }
            await run(host: host, mac: mac)
        }
    }

    func disconnect() {
        cameraProbe?.stop()
        cameraProbe = nil
        hud.glassText = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        pipeline?.stop()
        pipeline = nil
        hardware?.stop()
        hardware = nil
        audio?.stop()
        audio = nil
        micOn = false
        windows = []
        frameRateCap = 0
        input?.stop()
        input = nil
        hud.inputAllowed = nil
        hud.macCurtain = nil
        hud.macInputBlocked = nil
        fileReceiver.suspend()
        if let c = connection { Task { await c.close() } }
        connection = nil
        udp = nil
        hud.macScreen = .active
        hud.rateText = ""
        phase = .idle
        browser?.stop()
        browser = nil
        startBrowsing()
    }

    func recordBarcode(macMicros: UInt32, presentNs: UInt64) {
        guard let best = clock.best else { return }
        // Mac "now" in its own clock ≈ phone now + offset; unwrap the 32-bit µs value near it.
        let macNowNs = UInt64(bitPattern: Int64(bitPattern: presentNs) &+ best.offsetNs)
        let macDrawNs = BarcodePatch.unwrapMicros(macMicros, near: macNowNs / 1000) * 1000
        guard let drawLocal = clock.toLocal(remoteNs: macDrawNs), presentNs > drawLocal else { return }
        let ms = Double(presentNs - drawLocal) / 1e6
        if ms < 2000 { latency.add(ms) }
    }

    /// The streamed square's level in a picture presented at `presentNs` (renderer, main actor).
    func recordStreamFlash(level: Double, presentNs: UInt64) {
        if let e = screenFlash.add(timeNs: presentNs, level: level), let lag = flashMatcher.addFollower(e) { logLag(lag, e) }
    }

    /// One line per matched flip on the console, so a slow tail can be lined up against the host's own log.
    private func logLag(_ lag: Double, _ e: FlashEdge) {
        print("# flip \(e.rising ? "up" : "down") lag \(String(format: "%.1f", lag)) ms · \(Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()))")
    }

    private func startCameraTest() {
        screenFlash = FlashEdgeDetector(fixedThreshold: 128, interpolates: false)
        flashMatcher = FlashMatcher()
        cameraStatus = "starting the camera"
        let probe = CameraFlashProbe(
            onEdge: { [weak self] e in
                Task { @MainActor in
                    guard let self, let lag = self.flashMatcher.addReference(e) else { return }
                    self.logLag(lag, e)
                }
            },
            onStatus: { [weak self] status, fps in Task { @MainActor in self?.cameraStatus = status; self?.cameraFps = fps } })
        cameraProbe = probe
        probe.start()
    }

    private func refreshGlassText() {
        guard cameraProbe != nil else { hud.glassText = nil; return }
        let lags = flashMatcher.lagsMs.sorted()
        let fps = String(format: "cam %.0f fps", cameraFps)
        let text: String
        if lags.isEmpty {
            text = "glass-to-glass (camera): \(cameraStatus) · \(fps)"
        } else {
            let p = { (q: Double) in lags[min(lags.count - 1, Int((q * Double(lags.count - 1)).rounded()))] }
            text = String(format: "glass-to-glass (camera) p50 %.1f · p95 %.1f ms (n %d) · ", p(0.5), p(0.95), lags.count) + fps
        }
        hud.glassText = text
        hudTicks += 1
        if hudTicks % 4 == 0 {                                   // every 2 s, for `devicectl … --console`
            print("# \(text) · capture→screen p50 \(hud.latencyP50.map { String(format: "%.1f", $0) } ?? "-") · decode \(String(format: "%.1f", hud.decodeMs)) ms")
            fflush(stdout)
        }
    }

    private func identity() throws -> StaticIdentity {
        let raw = try keychain.dataOrCreate("identity") { Data(StaticIdentity().rawPrivateKey) }
        return try StaticIdentity(rawPrivateKey: [UInt8](raw))
    }

    private func run(host: BonjourBrowser.Found, mac: PairedMac) async {
        do {
            var caps: Capabilities = [.hevc420Decode, .refinementFrames, .benchBarcode, .receiverReports, .fecXor,
                                      .inputV1, .clientCursor, .clipboardV1, .filesToPhone, .micOpus, .windowStreaming, .frameRateCap,
                                      .filesV2, .curtain]
            if DecodeProbe.cached444 == true { caps.insert(.hevc444Decode) }
            caps.insert(.audioOpus)                              // muting is local, so a later unmute plays at once
            let wanted = PostureModel.mode(for: posture.display)
            let modes = [wanted] + [DisplayMode.laptop, .flat, .book, .cover].filter { $0 != wanted }
            let cap = currentCap()
            let hello = Hello(appVersion: AppVersion.short, build: AppVersion.build, capabilities: caps, displayModes: modes,
                              maxFps: cap == 0 ? 120 : cap, deviceName: UIDevice.current.name,
                              connectionId: UInt64.random(in: 1...UInt64.max), appExpires: AppExpiryWatch.unixSeconds)
            // Race the paths (ADR-0002): LAN (Bonjour), home UDP, then TLS + WebSocket on TCP, 150 ms apart.
            var candidates: [PathRacer.Candidate] = []
            let isManual = host.name == manualAddress
            // Connect (the home address) at home still tries the Mac on this Wi-Fi first: the router's own
            // public address loops back slowly or, on some routers, drops the video entirely.
            let lan = isManual ? lanHost(for: mac) : host
            if let ep = lan?.endpoint {
                candidates.append(.init(rank: 0, delay: .zero) { UDPClient(endpoint: ep, name: "lan") })
            }
            if let (h, p) = Self.parse(manualAddress, defaultPort: awayUDPPort) {
                let start: Duration = lan == nil ? .zero : .milliseconds(150)
                candidates.append(.init(rank: 1, delay: start) { UDPClient(host: h, port: p, name: "udp") })
                if p != Self.defaultUDPPort {
                    candidates.append(.init(rank: 1, delay: start) { UDPClient(host: h, port: Self.defaultUDPPort, name: "udp") })
                }
                if let tp = UInt16(exactly: tcpPort), tp > 0 {
                    candidates.append(.init(rank: 2, delay: start + .milliseconds(150)) { WSSClient(host: h, port: tp, name: "tcp") })
                }
            }
            let udp = PathRacer(candidates)
            self.udp = udp
            raceHasLAN = lan?.endpoint != nil
            let conn = ClientSessionConnection(udp: udp, identity: try identity(),
                                               server: PeerConfig(publicKey: [UInt8](mac.publicKey), psk: [UInt8](mac.psk), name: mac.name), hello: hello)
            connection = conn
            // Reports only to a Mac that understands them (protocol 1.1); a 1.0 Mac would just drop them.
            let macHello = try await conn.connect(timeout: .seconds(5))
            macMinor = macHello.protoMinor
            macCaps = macHello.capabilities
            frameRateCap = macCaps.contains(.frameRateCap) ? cap : 0
            // A 1.3 Mac builds the first mode it understands and can't change it; 1.4 follows the posture.
            displayMode = wanted
            let reports = macHello.protoMinor >= 1 && macHello.capabilities.contains(.receiverReports)
            var sendReport: (@Sendable (ReceiverReport) -> Void)?
            if reports {
                sendReport = { @Sendable (r: ReceiverReport) in
                    let m = r.message
                    Task { await conn.send([m]) }
                }
            }
            let pipeline = ClientVideoPipeline(requireHardware: Self.requireHardwareDecode,
                                               requestKeyframe: { req in Task { await conn.send([req.message]) } },
                                               sendReport: sendReport)
            self.pipeline = pipeline
            latency = LatencyStats(capacity: 2000)
            clock = ClockSync()
            presentedFrames = 0
            lastStats = nil
            pipeline.start()
            bulkOut = BulkSender()
            bulkIn = BulkReceiver()
            if fileMac == mac.publicKey {
                fileQueue.reconnected()                  // resume what was being sent
            } else {
                fileQueue = FileSendQueue()
                fileMac = mac.publicKey
            }
            if macHello.capabilities.contains(.inputV1) {
                let mode = displayMode
                let ic = InputClient(connection: conn, displaySize: CGSize(width: Double(mode.widthPoints), height: Double(mode.heightPoints)))
                input = ic
                hardware = HardwareInput(input: ic)
            }
            if cameraTestEnabled { startCameraTest() }
            phase = .streaming(host.name)
            micOn = false
            restartAudio(conn)
            #if DEBUG
            // `--posture-switch flat`: pin that posture 3 s into the stream (tests the display mode rebuild).
            if let i = CommandLine.arguments.firstIndex(of: "--posture-switch"), i + 1 < CommandLine.arguments.count,
               let p = Posture(rawValue: CommandLine.arguments[i + 1]) {
                Task { try? await Task.sleep(for: .seconds(3)); posture.pinned = p }
            }
            // `--audio-stats`: print what the audio player did 5 s into the stream.
            if CommandLine.arguments.contains("--audio-stats"), let a = audio {
                Task.detached { try? await Task.sleep(for: .seconds(5)); let s = a.stats
                    print("# audio: played \(s.played) lost \(s.lost) dropped \(s.dropped) queued \(Int(s.queuedMs)) ms") }
            }
            // `--send-file <path>`: send that file 2 s into the stream (tests the windowed bulk path).
            if let i = CommandLine.arguments.firstIndex(of: "--send-file"), i + 1 < CommandLine.arguments.count {
                let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
                Task { try? await Task.sleep(for: .seconds(2)); sendFile(url); print("# file: \(lastClipboardNote ?? "")") }
            }
            #endif
            UIApplication.shared.isIdleTimerDisabled = true

            let audioBox = audioSink
            tasks.append(Task.detached { [weak self] in
                for await batch in conn.messages {
                    pipeline.handle(batch)                       // video: thread-safe, stays off the main actor
                    if let player = audioBox.player {            // audio: also off the main actor
                        for m in batch where m.channel == .audio { if let p = try? AudioPacket(m) { player.handle(p) } }
                    }
                    let control = batch.filter { $0.channel != .video && $0.channel != .audio }
                    if !control.isEmpty {
                        let t4 = PhoneClock.nowNs()
                        await self?.handleControl(control, t4: t4)
                    }
                }
                await self?.connectionEnded("The Mac closed the connection.")
            })
            // Clock sync, and the Mac's rate control: 10 Hz pings while it reads our reports (their RTT above
            // its minimum is the queuing delay we report; ~70 bytes each), else fast at first, then 1 Hz.
            let fastPings = sendReport != nil
            tasks.append(Task { [weak self] in
                var n = 0
                while !Task.isCancelled {
                    await self?.sendPing(conn)
                    n += 1
                    try? await Task.sleep(for: fastPings || n < 10 ? .milliseconds(100) : .seconds(1))
                }
            })
            tasks.append(Task { [weak self] in                   // bulk resends (cursor shapes, clipboard)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard let self else { return }
                    let resend = self.bulkOut.poll(nowNs: PhoneClock.nowNs())
                    if !resend.isEmpty { await conn.send(resend) }
                    self.pumpFiles()
                    if let name = self.sendingFile {
                        if let p = self.bulkOut.progress { self.lastClipboardNote = "Sending \(name) · \(Int(p * 100))%" } else {
                            self.lastClipboardNote = "Sent \(name) to the Mac's Downloads"
                            self.sendingFile = nil
                        }
                    }
                }
            })
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.refreshHUD()
                }
            })
        } catch let error as KeychainStore.KeychainError {
            phase = .failed("This phone's key could not be read from the Keychain (\(error)). The app is probably not signed with a team; see docs/SETUP.md.")
            connection = nil
        } catch {
            if let conn = connection, let race = udp {
                let sent = await conn.handshakesSent, unmatched = await conn.unmatchedAnswers
                print("# connect failed: \(error) · \(sent) handshakes sent, \(unmatched) answers didn't match · \(race.report)")
            }
            phase = .failed("Could not connect: \(error). Check the pairing code, and that the phone can reach the Mac: the same network, or the Mac's address and forwarded UDP port (docs/SETUP.md › Away from home).")
            connection = nil
        }
    }

    private func sendPing(_ conn: ClientSessionConnection) async {
        pingId &+= 1
        await conn.send([Ping(id: pingId, t1: PhoneClock.nowNs()).message])
    }

    private func handleControl(_ messages: [InnerMessage], t4: UInt64) {
        for m in messages {
            switch m.type {
            case .pong:
                // id 0 answers the transport's keepalive (another clock): it would corrupt clock sync and RTT.
                if let p = try? Pong(m), p.id != Ping.keepaliveId, let sample = clock.add(t1: p.t1, t2: p.t2, t3: p.t3, t4: t4) {
                    pipeline?.setRoundTrip(nanoseconds: sample.delayNs)
                    hud.rttMs = Double(sample.delayNs) / 1e6
                }
            case .homeEndpoint:
                if let e = try? HomeEndpoint(m) { learn(e) }
            case .hostState:
                if let h = try? HostState(m) {
                    if h.screen != hud.macScreen { print("# mac screen: \(h.screen)") }
                    hud.macScreen = h.screen
                    hud.macKeepsAwake = h.keepsAwake
                    hud.inputAllowed = h.inputAllowed
                    if h.localUser != hud.macLocalUser { print("# mac local user: \(h.localUser)") }
                    hud.macLocalUser = h.localUser
                    hud.micReady = h.micReady
                    if h.window != hud.window { print("# streaming: \(h.window ?? "the whole screen")") }
                    hud.window = h.window
                    hud.macFps = Int(h.fps)
                    if h.curtain != hud.macCurtain { print("# mac screen hidden: \(h.curtain.map(String.init) ?? "-")") }
                    hud.macCurtain = h.curtain
                    hud.macInputBlocked = h.localInputBlocked
                    hud.rateText = String(format: "target %.1f Mbit/s", Double(h.targetBitrateKbps) / 1000) + (h.fecPercent > 0 ? " · FEC \(h.fecPercent)%" : "")
                }
            case .hostStats:
                if let s = try? HostStats(m) {
                    hud.encodeMs = Double(s.encodeMicros) / 1000
                    hud.hostDrops = Int(s.encoderDrops)
                    hud.hostSkipped = Int(s.skippedWhileBusy)
                }
            case .cursorPosition:
                if let p = try? CursorPosition(m) { input?.cursor.apply(p) }
            case .bulkChunk:
                guard let c = try? BulkChunk(m) else { continue }
                let (ack, done) = bulkIn.add(c, nowNs: t4)
                if let conn = connection { Task { await conn.send([ack.message]) } }
                if let done { received(done) }
            case .bulkAck:
                if let a = try? BulkAck(m) { bulkOut.handle(a) }
            case .fileBegin:
                if let b = try? FileBegin(m) { fileReceiver.handle(b, nowNs: t4) }
            case .fileAccept:
                if let a = try? FileAccept(m) { fileQueue.handle(a, nowNs: t4); pumpFiles() }
            case .fileProgress:
                if let p = try? FileProgress(m) { fileQueue.handle(p, nowNs: t4); pumpFiles() }
            case .fileCancel:
                if let c = try? FileCancel(m) { fileQueue.handle(c); fileReceiver.handle(c); pumpFiles() }
            case .cursorShape, .clipboardOffer, .keyboardLayout, .windowList:
                received(m)
            case .goodbye:
                connectionEnded("The Mac ended the session.")
            default:
                break
            }
        }
    }

    /// A message that came whole or through a bulk transfer.
    private func received(_ m: InnerMessage) {
        switch m.type {
        case .cursorShape:
            if let s = try? CursorShape(m) { input?.cursor.add(s) }
        case .keyboardLayout:
            guard let l = try? KeyboardLayout(m) else { return }
            print("# mac keyboard: \(l.name) (\(l.language))")
            input?.keyboardLayout = l
        case .clipboardOffer:
            guard clipboardSync, let offer = try? ClipboardOffer(m) else { return }
            if let text = offer.text {
                UIPasteboard.general.string = text
                lastClipboardNote = "Copied from the Mac: \(text.prefix(40))"
            } else if let png = offer.items.first(where: { $0.uti == "public.png" }), let image = UIImage(data: Data(png.data)) {
                UIPasteboard.general.image = image
                lastClipboardNote = "Copied an image from the Mac"
            }
            clipboardCount = UInt64(UIPasteboard.general.changeCount)
        case .fileOffer:
            if let f = try? FileOffer(m) { saveReceived(f) }
        case .fileSegment:
            if let seg = try? FileSegment(m) { fileReceiver.handle(seg, nowNs: PhoneClock.nowNs()) }
        case .windowList:
            if let l = try? WindowList(m) { windows = l.windows; loadingWindows = false; windowsTimedOut = false }
        default:
            break
        }
    }

    // MARK: files from the Mac (1.1)

    /// Files › On My iPhone › Clamshell › From Mac (the app shares its Documents folder with Files).
    static var receivedFolder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("From Mac", isDirectory: true)
    }

    static func listReceivedFiles() -> [URL] {
        guard let dir = receivedFolder,
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        let date = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return urls.sorted { date($0) > date($1) }
    }

    /// A file from the Mac: checked against its SHA-256, saved under a safe, unused name.
    private func saveReceived(_ f: FileOffer) {
        guard Array(SHA256.hash(data: f.data)) == f.sha256 else { lastClipboardNote = "A file from the Mac arrived damaged"; return }
        guard let dir = Self.receivedFolder else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var url = dir.appendingPathComponent(FileOffer.safeName(f.name))
            let ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
                n += 1
            }
            try Data(f.data).write(to: url, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            receivedFiles = Self.listReceivedFiles()
            lastReceivedFile = url
            lastClipboardNote = "From the Mac: \(url.lastPathComponent)"
            print("# file from the Mac: \(url.lastPathComponent) (\(f.data.count) bytes)")
        } catch {
            lastClipboardNote = "Couldn't save \(f.name): \(error.localizedDescription)"
        }
    }

    /// The newest file from the Mac this session, for the seam bar's share button.
    private(set) var lastReceivedFile: URL?

    func deleteReceived(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if lastReceivedFile == url { lastReceivedFile = nil }
        receivedFiles = Self.listReceivedFiles()
    }

    func refreshReceivedFiles() { receivedFiles = Self.listReceivedFiles() }

    // MARK: battery and heat saver (1.1)

    private func currentCap() -> UInt16 {
        let state = UIDevice.current.batteryState
        let conditions = PowerConditions(unplugged: state == .unplugged,
                                         lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                         thermal: ProcessInfo.processInfo.thermalState.rawValue)
        return conditions.cap(powerSaver)
    }

    private func startPowerWatch() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let nc = NotificationCenter.default
        for name in [UIDevice.batteryStateDidChangeNotification, ProcessInfo.thermalStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            powerObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFrameRateCap() }
            })
        }
    }

    /// Conditions or the setting changed: tell a 1.8 Mac the new cap (it rebuilds the stream at that rate).
    private func updateFrameRateCap() {
        let cap = currentCap()
        guard case .streaming = phase, macCaps.contains(.frameRateCap), let conn = connection, cap != frameRateCap else { return }
        frameRateCap = cap
        print("# power saver: \(cap == 0 ? "full rate" : "\(cap) fps")")
        let m = FrameRateRequest(maxFps: cap).message
        Task { await conn.send([m]) }
    }

    /// The phone's own display refresh while streaming: never faster than the Mac sends.
    var displayFps: Float { frameRateCap == 0 ? 120 : Float(frameRateCap) }

    // MARK: one window (1.1)

    /// The Mac's windows, from the last `WindowListRequest`.
    private(set) var windows: [StreamableWindow] = []
    private(set) var loadingWindows = false

    func requestWindows() {
        guard let conn = connection, macCaps.contains(.windowStreaming) else { return }
        loadingWindows = true
        windowsAsked += 1
        let asked = windowsAsked
        Task {
            await conn.send([WindowListRequest().message])
            // No answer in 4 s (the Mac dropped it, or an old list is all there is): stop the spinner.
            try? await Task.sleep(for: .seconds(4))
            if windowsAsked == asked, loadingWindows { loadingWindows = false; windowsTimedOut = true }
        }
    }
    private var windowsAsked = 0
    /// The last request got no answer: the picker says so and offers Refresh.
    private(set) var windowsTimedOut = false

    /// Stream `window` alone (resized to fit the phone when `fit`), or the whole screen again with nil.
    func stream(window: StreamableWindow?, fit: Bool = true) {
        guard let conn = connection, macCaps.contains(.windowStreaming) else { return }
        let m = (window.map { SourceRequest(windowId: $0.id, fit: fit) } ?? .wholeScreen).message
        pictureZoom.reset()
        Task { await conn.send([m]) }
    }

    // MARK: microphone (1.1)

    /// The phone's microphone on the Mac, as its Clamshell Microphone input. Off at every connect.
    private(set) var micOn = false

    func setMic(_ on: Bool) {
        guard on != micOn, let conn = connection, macCaps.contains(.micOpus) else { return }
        Task {
            if on {
                guard await AVAudioApplication.requestRecordPermission() else {
                    lastClipboardNote = "Microphone access is off: Settings › Apps › Clamshell › Microphone"
                    return
                }
            }
            micOn = on
            restartAudio(conn)
            if !on { lastClipboardNote = "Microphone off" }
            else if hud.micReady == false { lastClipboardNote = "Mic on, but the Mac has no Clamshell Microphone (docs/USAGE.md › Microphone)" }
            else { lastClipboardNote = "Microphone on: pick \"Clamshell Microphone\" as the input on the Mac" }
        }
    }

    /// (Re)builds the phone's audio: the Mac's sound, and the microphone when it's on (one engine, so voice
    /// processing can cancel the Mac's sound out of the microphone).
    private func restartAudio(_ conn: ClientSessionConnection) {
        audio?.stop()
        audio = nil
        let play = macCaps.contains(.audioOpus)
        guard play || micOn else { return }
        do {
            var send: (@Sendable ([AudioPacket]) -> Void)?
            if micOn {
                send = { @Sendable (packets: [AudioPacket]) in
                    let ms: [InnerMessage] = packets.map { $0.message }
                    Task { await conn.send(ms) }
                }
            }
            let a = try AudioPlayer(microphone: send)
            a.muted = !sound || !play
            audio = a
        } catch {
            print("audio: \(error)")
            if micOn { micOn = false; lastClipboardNote = "The microphone couldn't start: \(error.localizedDescription)" }
        }
    }

    /// Phone → Mac, only when asked (reading the pasteboard shows iOS's paste prompt).
    func sendClipboard() {
        guard let conn = connection else { return }
        var items: [ClipboardItem] = []
        if let text = UIPasteboard.general.string { items.append(ClipboardItem(uti: "public.utf8-plain-text", data: Array(text.utf8))) }
        else if let image = UIPasteboard.general.image, let png = image.pngData() { items.append(ClipboardItem(uti: "public.png", data: [UInt8](png))) }
        guard !items.isEmpty else { lastClipboardNote = "The phone's clipboard is empty"; return }
        let offer = ClipboardOffer(items: items, changeCount: UInt64(UIPasteboard.general.changeCount))
        let chunks = bulkOut.send(offer.message, nowNs: PhoneClock.nowNs())
        lastClipboardNote = "Sent the clipboard to the Mac"
        Task {
            for group in stride(from: 0, to: chunks.count, by: 16) {
                await conn.send(Array(chunks[group..<min(group + 16, chunks.count)]))
                if chunks.count > 16 { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }
    }

    /// Files and folders picked in the Files app. A 1.9 Mac takes any size and folders; an older one one file
    /// at a time, up to 32 MB.
    func sendFiles(_ urls: [URL]) {
        guard macCaps.contains(.filesV2) else {
            for url in urls { sendFile(url) }
            return
        }
        guard connection != nil else { return }
        // Keep each pick readable until its files are sent (a folder's access covers what's inside).
        let picks = urls.filter { $0.startAccessingSecurityScopedResource() }
        scopedPicks += picks
        let what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        lastClipboardNote = "Preparing \(what)…"
        Task {
            do {
                let files = try await Task.detached(priority: .userInitiated) { try FileListing.prepare(urls) }.value
                guard !files.isEmpty else { lastClipboardNote = "Nothing to send in \(what)"; releasePicks(); return }
                fileQueue.pruneFinished()
                fileQueue.enqueue(files)
                print("# file: queued \(files.count) for the Mac (\(FileListing.size(files.reduce(0) { $0 + $1.size })))")
                lastClipboardNote = nil
                pumpFiles()
            } catch {
                lastClipboardNote = "Couldn't read \(what): \(error.localizedDescription)"
                releasePicks()
            }
        }
    }

    private func releasePicks() {
        guard !fileQueue.busy else { return }
        for u in scopedPicks { u.stopAccessingSecurityScopedResource() }
        scopedPicks.removeAll()
    }

    private func setUpFileReceiver() {
        fileReceiver.send = { [weak self] m in
            guard let conn = self?.connection else { return }
            Task { await conn.send([m]) }
        }
        fileReceiver.onChange = { [weak self] in self?.updateTransferText() }
        fileReceiver.onSaved = { [weak self] url in
            guard let self else { return }
            receivedFiles = Self.listReceivedFiles()
            lastReceivedFile = url
            lastClipboardNote = "From the Mac: \(url.lastPathComponent)"
            print("# file from the Mac: \(url.lastPathComponent)")
        }
    }

    /// Sends what the file queue has ready: announcements now, segments as bulk transfers.
    private func pumpFiles() {
        guard let conn = connection, macCaps.contains(.filesV2), fileQueue.busy else {
            if transferFraction != nil || !transferText.isEmpty { updateTransferText() }
            if !scopedPicks.isEmpty, !fileQueue.busy { releasePicks() }
            return
        }
        let (control, segments) = fileQueue.poll(nowNs: PhoneClock.nowNs()) { FileListing.read($0, offset: $1, count: $2) }
        var chunks: [InnerMessage] = []
        for seg in segments { chunks += bulkOut.send(seg, nowNs: PhoneClock.nowNs()) }
        if !control.isEmpty || !chunks.isEmpty {
            Task {
                if !control.isEmpty { await conn.send(control) }
                // In groups, so a window of segments doesn't overrun the path at once.
                for group in stride(from: 0, to: chunks.count, by: 16) {
                    await conn.send(Array(chunks[group..<min(group + 16, chunks.count)]))
                    if chunks.count > 16 { try? await Task.sleep(for: .milliseconds(5)) }
                }
            }
        }
        for item in fileQueue.items where item.phase.finished && !reportedFiles.contains(item.id) {
            reportedFiles.insert(item.id)
            if case .failed(let why) = item.phase { lastClipboardNote = "Couldn't send \(item.file.name): \(why)" }
        }
        updateTransferText()
    }

    private func updateTransferText() {
        let now = ContinuousClock.now
        let sending = fileQueue.busy, receiving = fileReceiver.busy
        if sending || receiving, transferFraction != nil, now - lastTransferUpdate < .milliseconds(250) { return }
        lastTransferUpdate = now
        if sending, let cur = fileQueue.current {
            let t = fileQueue.totals
            let n = t.files > 1 ? " \(t.filesDone + 1)/\(t.files)" : ""
            transferText = "\(cur.phase == .checking ? "Checking" : "Sending") \(cur.file.name)\(n) · \(FileListing.size(t.done)) of \(FileListing.size(t.total))"
            transferFraction = t.total == 0 ? 0 : Double(t.done) / Double(t.total)
        } else if receiving, let st = fileReceiver.status {
            let n = st.count > 1 ? " \(st.index + 1)/\(st.count)" : ""
            transferText = "\(st.state == .checking ? "Checking" : "Receiving") \(st.name)\(n) · \(FileListing.size(st.received)) of \(FileListing.size(st.size))"
            transferFraction = st.fraction
        } else {
            if transferFraction != nil, let last = fileQueue.items.last, case .saved = last.phase {
                let t = fileQueue.items.count
                lastClipboardNote = t == 1 ? "Sent \(last.file.name) to the Mac's Downloads" : "Sent \(t) files to the Mac's Downloads"
            }
            if case .failed(let why)? = fileReceiver.status?.state { lastClipboardNote = why }
            transferText = ""
            transferFraction = nil
        }
    }

    /// Stops sending and receiving. What arrived is kept on the other side, so sending again resumes.
    func cancelTransfers() {
        let cancels = fileQueue.cancelAll()
        if let conn = connection, !cancels.isEmpty { Task { await conn.send(cancels) } }
        fileReceiver.cancel()
        bulkOut.cancelAll()
        lastClipboardNote = "Transfers cancelled"
        updateTransferText()
        releasePicks()
    }

    // MARK: privacy screen and unlocking (1.9)

    /// Asks the Mac to hide its own screen, and to turn its keyboard and trackpad off, for this session.
    func setPrivacy(curtain: Bool? = nil, blockLocalInput: Bool? = nil) {
        guard let conn = connection, macCaps.contains(.curtain) else { return }
        let m = PrivacyRequest(curtain: curtain, blockLocalInput: blockLocalInput).message
        Task { await conn.send([m]) }
    }

    /// Types `text` on the Mac, then Return: the unlock sheet. Nothing is kept or logged. Returns why it
    /// can't, or nil once it has started typing.
    func typeOnMac(_ text: String) -> String? {
        guard let input else { return "This Mac doesn't take keys from the phone." }
        let r = PasswordTyping.presses(for: text, layout: input.keyboardLayout)
        guard let presses = r.presses else {
            let ch = r.unmapped.map { String($0) } ?? "?"
            return "“\(ch)” isn't on the Mac's keyboard layout. Type the password at the Mac, or switch its layout."
        }
        Task {
            // A little apart, so each key is its own event on the Mac.
            let gap = Duration.milliseconds(12)
            for p in presses {
                if p.shift { input.key(PasswordTyping.leftShift, down: true); try? await Task.sleep(for: gap) }
                input.key(p.usage, down: true)
                try? await Task.sleep(for: gap)
                input.key(p.usage, down: false)
                try? await Task.sleep(for: gap)
                if p.shift { input.key(PasswordTyping.leftShift, down: false); try? await Task.sleep(for: gap) }
            }
            input.key(PasswordTyping.returnKey, down: true)
            try? await Task.sleep(for: gap)
            input.key(PasswordTyping.returnKey, down: false)
        }
        return nil
    }

    /// Phone → Mac Downloads (M5), up to `FileOffer.maxBytes`. The Mac saves it only if its
    /// "Accept files from the phone" toggle is on, under a sanitised, unused name.
    func sendFile(_ url: URL) {
        guard let conn = connection, macCaps.contains(.filesV1) else { lastClipboardNote = "This Mac doesn't take files"; return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { lastClipboardNote = "Couldn't read \(url.lastPathComponent)"; return }
        guard data.count <= FileOffer.maxBytes else {
            lastClipboardNote = "\(url.lastPathComponent) is over \(FileOffer.maxBytes >> 20) MB"
            return
        }
        let offer = FileOffer(name: url.lastPathComponent, sha256: Array(SHA256.hash(data: data)), data: [UInt8](data))
        let chunks = bulkOut.send(offer.message, nowNs: PhoneClock.nowNs())
        guard !chunks.isEmpty else { lastClipboardNote = "Couldn't send \(url.lastPathComponent)"; return }
        sendingFile = url.lastPathComponent
        lastClipboardNote = "Sending \(url.lastPathComponent)…"
        // The first window goes out now; the 50 ms bulk poll keeps it full and resends what isn't acked.
        Task { await conn.send(chunks) }
    }

    /// The app leaves the foreground: let go of every key and button on the Mac.
    func releaseInput() { input?.releaseAllHeld() }

    /// The posture held 600 ms: ask a 1.4 Mac for the display mode that fits (ADR-0012).
    func displayPostureChanged(_ p: Posture) {
        let mode = PostureModel.mode(for: p)
        guard case .streaming = phase, let conn = connection, macMinor >= 4, mode != displayMode else { return }
        displayMode = mode
        input?.cursor.displaySize = CGSize(width: Double(mode.widthPoints), height: Double(mode.heightPoints))
        let m = DisplayModeRequest(mode: mode).message
        Task { await conn.send([m]) }
        print("# posture: \(p.rawValue) → \(mode.widthPoints)×\(mode.heightPoints)")
    }

    private func connectionEnded(_ reason: String) {
        guard case .streaming = phase else { return }
        pictureZoom.reset()
        disconnect()
        phase = .failed(reason)
    }

    private func refreshHUD() {
        guard let pipeline else { return }
        let s = pipeline.currentStats
        let now = ContinuousClock.now
        if let last = lastStats {
            let dt = Double((now - last.at).components.attoseconds) / 1e18 + Double((now - last.at).components.seconds)
            if dt > 0 {
                hud.decodedFps = Double(s.framesDecoded - last.decoded) / dt
                hud.presentedFps = Double(presentedFrames - last.presented) / dt
                hud.mbps = Double(s.bytesReceived - last.bytes) * 8 / dt / 1e6
            }
        }
        lastStats = (now, s.framesDecoded, s.bytesReceived, presentedFrames)
        hud.decodeMs = s.lastDecodeMs
        hud.keyframes = s.keyframes
        hud.refinements = s.refinements
        hud.framesLost = s.framesLost
        hud.chroma = switch s.chroma { case .yuv444: "4:4:4"; case .yuv422: "4:2:2"; default: "4:2:0" }
        hud.latencyP50 = latency.p50
        hud.latencyP95 = latency.p95
        hud.latencySamples = latency.count
        hud.migrations = udp?.switches ?? 0
        hud.pathName = udp?.activeName ?? "…"
        refreshGlassText()
    }
}

/// What the phone keeps about its Mac (Keychain, `ThisDeviceOnly`).
struct PairedMac: Codable, Equatable {
    var publicKey: Data
    var psk: Data
    var name: String
    var udpPort: UInt16
    var tcpPort: UInt16
    var publicHost: String
    var paired: Date
    var endpointSeq: UInt64?
    /// 1.1: this Mac's away-from-home address as typed or learned (`host:port`); nil: from `publicHost`.
    var address: String?
}

/// A path that never comes up (for a check row with nothing to try).
final class DeadPath: PacketPath {
    let name = "none"
    let datagrams = AsyncStream<[UInt8]> { $0.finish() }
    func start() async throws { throw CancellationError() }
    func send(_ packets: [[UInt8]]) {}
    func stop() {}
}

/// The audio player the receive task feeds: swapped when the microphone turns on or off.
final class AudioSink: Sendable {
    private let box = Mutex<AudioPlayer?>(nil)
    var player: AudioPlayer? {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }
}
