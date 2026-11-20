import AppKit
import ClamshellFiles
import ClamshellInput
import ClamshellKeychain
import ClamshellRateControl
import ClamshellSession
import ClamshellStream
import ClamshellTransport
import ClamshellVideo
import ClamshellVirtualDisplay
import ClamshellWire
import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import Observation
import os
import ServiceManagement
import SwiftUI

/// Owns the host: Noise/UDP server (Bonjour `_clamshell._udp` on the LAN), and per connected phone a
/// virtual display at the phone's size → ScreenCaptureKit → `HostVideoPipeline` → paced, sealed datagrams.
/// For paths we don't own (cellular, other Wi-Fi) the phone's `ReceiverReport`s drive the bitrate and FEC,
/// and `MacPresence` keeps the Mac from idling into the screen saver and lock while someone watches.
@MainActor
@Observable
final class HostController {
    enum Status: Equatable {
        case starting, waiting(port: UInt16), streaming(peer: String), failed(String)
    }

    private(set) var status: Status = .starting
    /// Phones on the allow-list, and the open pairing window if any (ADR-0014).
    private(set) var devices: [PairedDevice] = []
    private(set) var pairing: PairingState?
    /// Remote access paused: no sessions, the 443 listener is closed. LAN pairing still works.
    private(set) var paused = false
    private var deviceStore = DeviceStore(keychain: nil)
    private let pairingWindow = PairingWindowController()
    private var pairingTimer: Task<Void, Never>?
    /// The router's public address and the name phones dial (ADR-0005, Home address… window).
    let publicAddress = PublicAddressMonitor(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Clamshell"),
        keychain: ProcessInfo.processInfo.environment["CLAMSHELL_EPHEMERAL_KEYS"] == "1" ? nil : KeychainStore(service: "dev.clamshell.host"))
    /// Opens UDP and TCP on the router over UPnP and keeps them pointed at this Mac.
    let portForwarder = PortForwarder()
    private let homeWindow = HomeAddressWindowController()
    var publicAddressText: String {
        guard let a = publicAddress.effective else { return "Public address: unknown (set it up under Home address…)" }
        let n = publicAddress.changesLast30Days
        let ip = publicAddress.ip.map { $0 == a ? "" : " (\($0))" } ?? ""
        return "Public address: \(a)\(ip)" + (publicAddress.learned != nil ? " · from the \(publicAddress.source)" : "")
            + (n > 0 ? " · changed \(n)× in 30 days" : "")
    }

    func showHomeAddress() {
        homeWindow.show(HomeAddressView(monitor: publicAddress, forwarder: portForwarder))
    }
    private(set) var stats = HostVideoPipeline.Stats()
    private(set) var streamDescription = ""
    private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    /// Rate control as last decided (for the menu): bitrate in Mbit/s and FEC overhead in percent.
    private(set) var rateText = ""
    private(set) var macScreen: MacScreenState = .active
    /// The latency barcode patch (harness A) on the streamed screen: for measurements only, so off unless
    /// `defaults write <bundle id> latencyBarcode -bool true`.
    var barcodeEnabled = UserDefaults.standard.bool(forKey: "latencyBarcode") { didSet { updateBarcode() } }
    /// Harness B flash square on the Mac panel and the virtual display. Off by default: it's distracting.
    var flashEnabled = ProcessInfo.processInfo.environment["CLAMSHELL_FLASH"] == "1" { didSet { updateBarcode() } }

    private let log = Logger(subsystem: "dev.clamshell.host", category: "host")
    private let keychain = KeychainStore(service: "dev.clamshell.host")
    private var server: HostSessionServer?
    /// Path P3: TLS + WebSocket on TCP 443 (UserDefaults `tcpPort` to change), same sessions as UDP.
    private var edge: WSSServer?
    private(set) var edgeText = ""
    private var session: StreamSession?
    private var statsTask: Task<Void, Never>?
    private var barcode: BarcodeOverlay?
    private var flash: FlashOverlay?
    /// Held while streaming, so a menu-bar app with no visible window is never App-Napped (timers and
    /// display links throttled). Note: this did *not* fix the ~30 complete SCK frames/s seen on a Mac left
    /// unattended for hours; that's still open (CHANGELOG, M1).
    private var streamingActivity: (any NSObjectProtocol)?
    private let presence = MacPresence()
    private var peerMinor: UInt16 = 0
    private var peerCaps: Capabilities = []
    private(set) var inputAllowed = InputInjector.allowed {
        didSet { if inputAllowed != oldValue { print("input permission: \(inputAllowed ? "allowed" : "NOT allowed")") } }
    }
    /// Show the Mac's own screen (true, default) or add a separate Clamshell display sized for the phone.
    /// Mirroring falls back to the separate display when no real display is on (lid closed, no monitor).
    var mirrorMainDisplay = UserDefaults.standard.object(forKey: "mirrorMainDisplay") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(mirrorMainDisplay, forKey: "mirrorMainDisplay")
            Task { await restartForDisplayChoice() }
        }
    }
    var clipboardSync = UserDefaults.standard.bool(forKey: "clipboardSync") {
        didSet { UserDefaults.standard.set(clipboardSync, forKey: "clipboardSync"); updateClipboard() }
    }
    /// Files dropped on the phone's picture go to Downloads (M5). Off by default: it lets the phone write here.
    var acceptFiles = UserDefaults.standard.bool(forKey: "acceptFiles") {
        didSet { UserDefaults.standard.set(acceptFiles, forKey: "acceptFiles") }
    }
    var keepAwakeOnAC = UserDefaults.standard.bool(forKey: "keepAwakeOnAC") {
        didSet { UserDefaults.standard.set(keepAwakeOnAC, forKey: "keepAwakeOnAC"); presence.keepAwakeOnAC = keepAwakeOnAC }
    }
    /// Start at login (`SMAppService`); the system shows it in Login Items, where it can be turned off too.
    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {
                print("login item: \(error)")
            }
            loginItemTick += 1
        }
    }
    private(set) var loginItemTick = 0
    /// System audio to the phone (M5), when the phone asks for it (`audioOpus`). On by default.
    var streamSound = UserDefaults.standard.object(forKey: "streamSound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(streamSound, forKey: "streamSound"); Task { await restartAudio() } }
    }
    private var audio: AudioCapture?
    private var audioPeer: [UInt8]?
    private var audioSender: Task<Void, Never>?
    /// T9: local input at the Mac pauses the phone's input; Esc×3 at the Mac ends every session.
    @ObservationIgnored private lazy var localGuard = LocalUserGuard(
        onChange: { [weak self] active in
            guard let self else { return }
            if active { self.session?.injector?.releaseAllHeld() }
            print(active ? "local keyboard/mouse in use: phone input paused" : "local keyboard/mouse idle: phone input resumed")
            Task { await self.sendHostState() }
        },
        onPanic: { [weak self] in self?.panic() })
    private(set) var lastFileNote = ""

    // MARK: 1.9: privacy screen, local input block, files of any size

    enum CurtainMode: String, CaseIterable, Identifiable {
        case off, away, always
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: "Never"
            case .away: "When the phone is away from home"
            case .always: "Always"
            }
        }
    }
    /// When to hide this Mac's own screen during a session (the phone can ask otherwise for one session).
    var curtainMode = CurtainMode(rawValue: UserDefaults.standard.string(forKey: "curtainMode") ?? "") ?? .away {
        didSet { UserDefaults.standard.set(curtainMode.rawValue, forKey: "curtainMode"); Task { await applyPrivacy() } }
    }
    /// While the screen is hidden, also turn this Mac's keyboard and trackpad off. Off by default.
    var blockLocalInput = UserDefaults.standard.bool(forKey: "blockLocalInput") {
        didSet { UserDefaults.standard.set(blockLocalInput, forKey: "blockLocalInput"); Task { await applyPrivacy() } }
    }
    /// The phone's choice for this session (`PrivacyRequest`), over the settings above.
    private var sessionCurtain: Bool?
    private var sessionBlock: Bool?
    @ObservationIgnored private let curtain = Curtain()
    @ObservationIgnored private let blocker = LocalInputBlocker()
    private(set) var curtainShown = false
    private(set) var localInputBlocked = false
    /// Esc ×3 at the Mac: the screen comes back at once instead of waiting for a reconnect.
    private var panicked = false

    /// Files to the phone (1.9) and from it, any size, folders, resumable.
    @ObservationIgnored private var fileQueue = FileSendQueue()
    /// The phone `fileQueue` belongs to; another phone connecting drops it.
    @ObservationIgnored private var filePeer: [UInt8]?
    @ObservationIgnored private let fileReceiver = FileReceiver(root: HostController.downloadsFolder)
    nonisolated static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
    /// One line for the menu about what's being sent or received, and its progress (nil: nothing).
    private(set) var transferText = ""
    private(set) var transferFraction: Double?
    var transferring: Bool { fileQueue.busy || fileReceiver.busy }
    /// Bumped when a phone reports its app's expiry, so the menu redraws.
    private(set) var expiryTick = 0
    /// Phone input messages thrown away because someone was using the Mac (for the host log).
    private var droppedInput = 0
    private var bulkOut = BulkSender()
    private var bulkIn = BulkReceiver()
    private var bulkTask: Task<Void, Never>?
    private var cursorMonitor: CursorMonitor?
    private var clipboard: ClipboardSync?
    /// The phone's frame-rate cap (1.8, battery saver): 0 is none.
    private var fpsCap: UInt16 = 0
    /// The one window streamed instead of the whole screen (1.8), if the phone asked for one.
    private var sourceWindow: CGWindowID?
    /// Keeps the input area on a streamed window as it moves; rebuilds the stream when it's resized or closed.
    private var windowWatch: Task<Void, Never>?
    /// The phone's microphone into the Clamshell Microphone driver (1.1).
    private var mic: MicPlayer?
    private var micWarned = false
    /// Finder › Services › Send to iPhone with Clamshell.
    @ObservationIgnored private var service: SendToPhoneService?
    /// Whether the Clamshell Microphone driver is loaded (checked at start and on every session).
    private(set) var micDriverInstalled = MicPlayer.deviceAvailable
    /// The phone being streamed to can take files from the Mac (1.8).
    var canSendFiles: Bool { session != nil && peerCaps.contains(.filesToPhone) }
    @ObservationIgnored private var layoutObserver: NSObjectProtocol?

    func start() {
        setvbuf(stdout, nil, _IOLBF, 0)          // line-buffered, for `ClamshellHost > host.log`
        // First run: ask now, so ClamshellHost appears in System Settings › Screen & System Audio Recording.
        // macOS shows the prompt only once per app; afterwards this just reports the current state.
        if !screenRecordingGranted && ProcessInfo.processInfo.environment["CLAMSHELL_TEST_PATTERN"] != "1" { requestScreenRecording() }
        macScreen = presence.screen
        presence.keepAwakeOnAC = keepAwakeOnAC
        presence.onChange = { [weak self] state in
            guard let self else { return }
            self.macScreen = state
            print("mac screen: \(state)")
            Task { await self.sendHostState() }
        }
        publicAddress.onChange = { [weak self] _ in
            Task { await self?.sendHomeEndpoint() }
        }
        publicAddress.start()
        portForwarder.start()
        layoutObserver = KeyboardLayouts.observe { [weak self] in self?.sendKeyboardLayout() }
        let service = SendToPhoneService { [weak self] urls in self?.sendFilesToPhone(urls) ?? "" }
        self.service = service
        NSApplication.shared.servicesProvider = service
        NSUpdateDynamicServices()
        setUpFileReceiver()
        Task { await run() }
    }

    private func setUpFileReceiver() {
        let r = fileReceiver
        r.accepting = { [weak self] in self?.acceptFiles ?? false }
        r.send = { [weak self] m in
            guard let self, let s = self.session, let server = self.server else { return }
            let peer = s.peerKey
            Task { await server.send([m], to: peer) }
        }
        r.onChange = { [weak self] in self?.updateTransferText() }
        r.onSaved = { [weak self] url in
            self?.lastFileNote = "Saved \(url.lastPathComponent) to Downloads"
            print("file: saved \(url.path)")
        }
    }

    /// Mac → phone (1.3): the away-from-home address, at session start and on every change.
    private func sendHomeEndpoint() async {
        guard let s = session, let server, peerMinor >= 3, let host = publicAddress.effective else { return }
        let tcp = UInt16(UserDefaults.standard.integer(forKey: "tcpPort")).nonZero ?? 443
        let now = UInt64(Date().timeIntervalSince1970)
        let msg = HomeEndpoint(host: host, udpPort: await server.boundPort ?? 51820, tcpPort: edge == nil ? 0 : tcp, observedAt: now, seq: now)
        await server.send([msg.message], to: s.peerKey)
    }

    /// Mac → phone (1.6): the selected keyboard layout and what its keys type, so the phone's keys match.
    private func sendKeyboardLayout() {
        guard session != nil, peerMinor >= 6, let layout = KeyboardLayouts.current() else { return }
        print("keyboard layout: \(layout.name) (\(layout.language.isEmpty ? "?" : layout.language), \(layout.keys.count) keys)")
        sendBulk(layout.message)
    }

    func requestScreenRecording() {
        screenRecordingGranted = CGRequestScreenCaptureAccess()
    }

    /// Keyboard and mouse from the phone need Accessibility. macOS shows its own prompt, which opens
    /// System Settings › Privacy & Security › Accessibility; the person at the Mac switches it on.
    func requestInputAccess() {
        inputAllowed = CGRequestPostEventAccess()
    }

    // MARK: pairing and devices (ADR-0014)

    /// Opens a 120 s pairing window after the Mac's owner authenticates.
    func openPairing(skipAuth: Bool = false) async {
        guard let server else { return }
        if pairing != nil { pairingWindow.show(pairingView()); return }
        guard devices.count < DeviceStore.limit else {
            status = .failed("\(DeviceStore.limit) phones are paired already. Revoke one first.")
            return
        }
        if !skipAuth { guard await PairingSupport.authorize() else { return } }
        let port = await server.boundPort ?? 51820
        let invite = PairingInvite(macPublicKey: await server.publicKey, secret: PairingInvite.newSecret(),
                                   macName: Host.current().localizedName ?? "Mac", port: port, addresses: PairingSupport.lanAddresses())
        await server.openPairing(invite)
        let state = PairingState(invite: invite, seconds: 120)
        pairing = state
        print("CLAMSHELL_PAIR_INVITE=\(invite.string)")
        print("CLAMSHELL_PAIR_CODE=\(invite.manualCode)")
        pairingWindow.show(pairingView())
        pairingTimer?.cancel()
        pairingTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self, self.pairing === state, state.requests.isEmpty else { return }
            await self.closePairing()
        }
    }

    private func pairingView() -> some View {
        PairingView(state: pairing ?? PairingState(invite: PairingInvite(macPublicKey: nil, secret: []), seconds: 0),
                    confirm: { [weak self] id in Task { await self?.confirmPairing(id) } },
                    reject: { [weak self] id in Task { await self?.rejectPairing(id) } },
                    cancel: { [weak self] in Task { await self?.closePairing() } })
    }

    func closePairing() async {
        pairingTimer?.cancel()
        pairing = nil
        pairingWindow.close()
        await server?.closePairing()
    }

    private func confirmPairing(_ id: UInt32) async {
        guard let server, let state = pairing else { return }
        guard devices.count < DeviceStore.limit else { state.message = "Too many paired phones."; return }
        let tcp = UInt16(UserDefaults.standard.integer(forKey: "tcpPort")).nonZero ?? 443
        let publicHost = publicAddress.effective ?? ""
        do {
            let peer = try await server.confirmPairing(id, accept: PairingAccept(accepted: true, udpPort: await server.boundPort ?? 51820,
                                                                                  tcpPort: tcp, publicHost: publicHost))
            try deviceStore.add(peer)
            devices = deviceStore.devices
            state.requests.removeAll { $0.id == id }
            state.message = "Paired with \(peer.name.isEmpty ? "the phone" : peer.name)."
            state.done = true
            print("paired: \(peer.name)")
            // Keep the window (and the server's cached answer) a few seconds for a phone that missed it.
            pairingTimer?.cancel()
            pairingTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await self?.server?.closePairing()
            }
        } catch {
            state.message = "Pairing failed: \(error)"
        }
    }

    private func rejectPairing(_ id: UInt32) async {
        await server?.rejectPairing(id)
        pairing?.requests.removeAll { $0.id == id }
    }

    /// Removes the phone from the allow-list and ends its session now.
    func revoke(_ device: PairedDevice) async {
        await server?.revoke(peerKey: [UInt8](device.publicKey))
        try? deviceStore.remove(device.publicKey)
        devices = deviceStore.devices
    }

    /// Ends every live session; pairings stay.
    func disconnectAll() async {
        await server?.disconnectAll()
    }

    func setPaused(_ on: Bool) async {
        guard let server else { return }
        paused = on
        await server.setPaused(on)
        portForwarder.setPaused(on)
        if on {
            edge?.stop()
            edge = nil
            edgeText = "Remote access paused"
        } else {
            await startEdge(server)
        }
    }

    private func run() async {
        do {
            let identity: StaticIdentity
            let ephemeral = ProcessInfo.processInfo.environment["CLAMSHELL_EPHEMERAL_KEYS"] == "1"
            if ephemeral {
                // Tests and unsigned local builds: an ad-hoc signature changes every build, so the login
                // keychain would ask for permission each launch. Keys and pairings live only for this run.
                identity = StaticIdentity()
            } else {
                identity = try StaticIdentity(rawPrivateKey: [UInt8](keychain.dataOrCreate("identity") { Data(StaticIdentity().rawPrivateKey) }))
                try? keychain.delete("dev-psk")          // M1 development pairing is gone
            }
            deviceStore = DeviceStore(keychain: ephemeral ? nil : keychain)
            devices = deviceStore.devices
            let hello = Hello(appVersion: AppVersion.short, build: AppVersion.build, capabilities: [.refinementFrames, .benchBarcode, .receiverReports, .fecXor, .inputV1, .clientCursor, .clipboardV1, .filesV1, .audioOpus,
                                                                                .filesToPhone, .micOpus, .windowStreaming, .frameRateCap, .filesV2, .curtain],
                              displayModes: [], maxFps: 120, deviceName: Host.current().localizedName ?? "Mac")
            let server = HostSessionServer(responder: HostResponder(identity: identity, peers: devices.map(\.peer)), hello: hello)
            self.server = server
            let port = try await server.start(port: UInt16(UserDefaults.standard.integer(forKey: "udpPort")).nonZero,
                                              bonjourName: Host.current().localizedName ?? "Clamshell Mac")
            status = .waiting(port: port)
            log.notice("listening on UDP \(port)")
            print("CLAMSHELL_UDP_PORT=\(port)")
            portForwarder.set(.udp, port)
            await startEdge(server)
            #if DEBUG
            // Automation: open a pairing window at launch (no owner check) and print the invite.
            if ProcessInfo.processInfo.environment["CLAMSHELL_PAIR_ON_START"] == "1" { Task { await openPairing(skipAuth: true) } }
            #endif
            for await event in server.events { await handle(event, server: server) }
        } catch {
            status = .failed("\(error)")
            log.error("host failed: \(String(describing: error))")
        }
    }

    private func startEdge(_ server: HostSessionServer) async {
        edge?.stop()
        let port = UInt16(UserDefaults.standard.integer(forKey: "tcpPort")).nonZero ?? 443
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        do {
            let identity = try EdgeIdentity.loadOrCreate(directory: support.appendingPathComponent("Clamshell"))
            let w = WSSServer()
            let bound = try await w.start(port: port, identity: identity)
            await server.attach(w.datagrams)
            edge = w
            edgeText = "Internet fallback: TCP \(bound) (TLS + WebSocket)"
            print("CLAMSHELL_TCP_PORT=\(bound)")
            portForwarder.set(.tcp, bound)
            print("accessibility trusted: \(AXIsProcessTrusted()) · post events: \(CGPreflightPostEventAccess()) · bundle \(Bundle.main.bundlePath)")
            print("input permission: \(InputInjector.allowed ? "allowed" : "NOT allowed") · screen recording: \(CGPreflightScreenCaptureAccess() ? "allowed" : "NOT allowed")")
        } catch {
            edgeText = "TCP \(port) unavailable: \(error)"
            log.error("edge failed on TCP \(port): \(String(describing: error))")
            print("CLAMSHELL_TCP_PORT=failed \(error)")
            portForwarder.set(.tcp, nil)
        }
    }

    private func handle(_ event: HostSessionServer.Event, server: HostSessionServer) async {
        switch event {
        case .peerConnected(let key, let hello, _, _):
            LocalUserGuard.notifySessionStarted(phone: hello.deviceName.isEmpty ? "Your iPhone" : hello.deviceName)
            await stopStreaming()
            // 1.8 phones send their battery saver's cap in the Hello (1.0–1.7 sent 120 meaning "any").
            fpsCap = hello.protoMinor >= 8 && hello.maxFps < 120 ? hello.maxFps : 0
            sourceWindow = nil
            micDriverInstalled = MicPlayer.deviceAvailable
            PhoneAppExpiry.record(hello.appExpires, for: key)
            expiryTick += 1
            let phone = hello.deviceName.isEmpty ? "your iPhone" : hello.deviceName
            Task { await PhoneAppExpiry.scheduleReminder(key, phone: phone) }
            panicked = false
            if filePeer == key {
                fileQueue.reconnected()          // resume what was being sent
            } else {
                fileQueue = FileSendQueue()
                filePeer = key
                sessionCurtain = nil
                sessionBlock = nil
            }
            await startStream(key: key, hello: hello, mode: initialMode(hello), continuing: nil, server: server)
        case .messages(let key, let messages):
            guard let session, session.peerKey == key else { return }
            // Mirroring: a fold only changes how the phone lays the picture out, never the Mac's display.
            if !session.mirroring, let m = messages.first(where: { $0.type == .displayModeRequest }), let req = try? DisplayModeRequest(m),
               let hello = streamHello, req.mode != session.mode, Self.acceptable(req.mode) {
                let carry = session.pipeline.position
                await stopStreaming()
                await startStream(key: key, hello: hello, mode: req.mode, continuing: (carry.frameId &+ 16, carry.generation), server: server)
                return
            }
            await handleMessages(session: session, key: key, messages: messages, server: server)
        default:
            await handleOther(event, server: server)
        }
    }

    /// The first stream's mode: the phone's current posture for a separate display; for mirroring the
    /// largest one it offers, so the picture stays sharp in every posture without rebuilding.
    private func initialMode(_ hello: Hello) -> DisplayMode {
        let first = hello.displayModes.first ?? .laptop
        guard mirrorMainDisplay else { return first }
        return hello.displayModes.filter(Self.acceptable).max { $0.widthPixels * $0.heightPixels < $1.widthPixels * $1.heightPixels } ?? first
    }

    /// The display choice changed mid-session: rebuild the stream the new way.
    private func restartForDisplayChoice() async {
        guard let s = session, let hello = streamHello, let server else { return }
        let key = s.peerKey
        let carry = s.pipeline.position
        await stopStreaming()
        await startStream(key: key, hello: hello, mode: initialMode(hello), continuing: (carry.frameId &+ 16, carry.generation), server: server)
    }

    /// A requested mode the Mac will build: the four posture modes, or anything of the same size class.
    static func acceptable(_ m: DisplayMode) -> Bool {
        (320...2560).contains(m.widthPoints) && (320...2560).contains(m.heightPoints) && (1...3).contains(m.scale) && (30...120).contains(m.refreshHz)
    }

    private func startStream(key: [UInt8], hello: Hello, mode: DisplayMode, continuing: (frameId: UInt32, generation: UInt16)?,
                             server: HostSessionServer) async {
            streamHello = hello
            presence.wakeDisplay()
            // Away from home the Mac's upload is the bottleneck: a lighter stream (see StreamSession.Profile).
            let remote = await isRemote(key, server: server)
            let use444 = hello.capabilities.contains(.hevc444Decode) && !remote
            do {
                streamingActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .latencyCritical], reason: "Streaming the screen to \(hello.deviceName)")
                presence.holdAwake(reason: "Clamshell is streaming this screen to \(hello.deviceName)")
                peerMinor = hello.protoMinor
                peerCaps = hello.capabilities
                // Only for a new connection. A rebuild of the stream (a window, a posture, a frame-rate cap) keeps
                // them: the phone remembers finished transfer ids, so a fresh sender restarting at id 1 had
                // its cursor shapes, window lists and files acknowledged and dropped as repeats.
                if continuing == nil {
                    bulkOut = BulkSender()
                    bulkIn = BulkReceiver()
                }
                let clientCursor = hello.capabilities.contains(.clientCursor)
                let session: StreamSession
                do {
                    session = try await StreamSession(peerKey: key, mode: mode, use444: use444,
                                                      adaptive: hello.capabilities.contains(.receiverReports),
                                                      fec: hello.capabilities.contains(.fecXor), clientCursor: clientCursor,
                                                      mirror: mirrorMainDisplay, remote: remote, continuing: continuing,
                                                      window: sourceWindow, fpsCap: fpsCap,
                                                      excluding: curtain.shown ? curtain.windowIDs : [], server: server)
                } catch where sourceWindow != nil {
                    // The window closed or can't be captured: back to the whole screen.
                    print("window stream failed (\(error)): streaming the whole screen")
                    sourceWindow = nil
                    session = try await StreamSession(peerKey: key, mode: mode, use444: use444,
                                                      adaptive: hello.capabilities.contains(.receiverReports),
                                                      fec: hello.capabilities.contains(.fecXor), clientCursor: clientCursor,
                                                      mirror: mirrorMainDisplay, remote: remote, continuing: continuing,
                                                      window: nil, fpsCap: fpsCap,
                                                      excluding: curtain.shown ? curtain.windowIDs : [], server: server)
                }
                self.session = session
                if hello.capabilities.contains(.inputV1) { startInput(session, cursor: clientCursor, server: server) }
                localGuard.start()
                startBulk(server: server, peer: key)
                updateClipboard()
                audioPeer = hello.capabilities.contains(.audioOpus) ? key : nil
                await restartAudio()
                status = .streaming(peer: hello.deviceName)
                streamDescription = (session.window.map { "window \"\($0.title.isEmpty ? $0.app : $0.title)\", \(session.width)×\(session.height) px" }
                    ?? (session.mirroring ? "this Mac's screen, \(session.width)×\(session.height) px" : "\(mode.widthPoints)×\(mode.heightPoints) pt @\(mode.scale)×"))
                    + " \(session.fps) Hz · HEVC \(use444 ? "4:4:4" : "4:2:0")" + (remote ? " · internet" : "")
                screenRecordingGranted = true
                startStats()
                updateBarcode()
                watchWindow(session)
                await applyPrivacy()
                await sendHomeEndpoint()
                sendKeyboardLayout()
                print("streaming to \(hello.deviceName): \(streamDescription) · \(await server.pathDescription(of: key) ?? "?")")
            } catch {
                status = .failed("\(error)")
                screenRecordingGranted = CGPreflightScreenCaptureAccess()
                log.error("stream start failed: \(String(describing: error))")
                print("stream start failed: \(error)")
            }
    }

    private func handleMessages(session: StreamSession, key: [UInt8], messages: [InnerMessage], server: HostSessionServer) async {
            let input = messages.filter { $0.channel == .input }
            if !input.isEmpty {
                // With the keyboard and trackpad off, local events never arrive: nothing to pause for.
                if localGuard.active && !blocker.active { droppedInput += input.count } else { session.injector?.handle(input) }
            }
            let t2 = HostClock.nowNs()
            var replies: [InnerMessage] = []
            var rebuild = false
            var filesChanged = false
            for m in messages {
                switch m.type {
                case .audioPacket:
                    if let p = try? AudioPacket(m) { micPacket(p) }
                case .frameRateRequest:
                    guard let r = try? FrameRateRequest(m) else { continue }
                    let cap = r.maxFps >= 120 ? 0 : r.maxFps
                    if cap != fpsCap {
                        fpsCap = cap
                        print("frame rate: the phone asks for \(cap == 0 ? "full rate" : "at most \(cap) fps")")
                        rebuild = FrameRateRequest.effective(modeHz: Int(session.mode.refreshHz), cap: cap) != session.fps || rebuild
                    }
                case .windowListRequest:
                    Task { await self.sendWindowList() }
                case .sourceRequest:
                    guard let r = try? SourceRequest(m) else { continue }
                    let id: CGWindowID? = r.windowId == 0 ? nil : r.windowId
                    if id != sourceWindow || r.fit {
                        if let id, r.fit { fitWindow(id, session: session) }
                        sourceWindow = id
                        print(id.map { "source: window \($0)" + (r.fit ? ", resized to fit the phone" : "") } ?? "source: the whole screen")
                        rebuild = true
                    }
                case .keyframeRequest:
                    let req = try? KeyframeRequest(m)
                    tally.request(req?.reason)
                    session.pipeline.requestKeyframe(lastGoodFrameId: req?.lastGoodFrameId)
                case .ping:
                    if let p = try? Ping(m) { replies.append(Pong(id: p.id, t1: p.t1, t2: t2, t3: HostClock.nowNs()).message) }
                case .receiverReport:
                    if let r = try? ReceiverReport(m) {
                        tally.add(r)
                        if session.handle(r) { rateText = session.rateText }
                    }
                case .bulkChunk:
                    guard let c = try? BulkChunk(m) else { continue }
                    let (ack, done) = bulkIn.add(c, nowNs: t2)
                    replies.append(ack.message)
                    if let done { received(done) }
                case .bulkAck:
                    if let a = try? BulkAck(m) { bulkOut.handle(a) }
                case .privacyRequest:
                    guard let r = try? PrivacyRequest(m) else { continue }
                    if let c = r.curtain { sessionCurtain = c }
                    if let b = r.blockLocalInput { sessionBlock = b }
                    print("privacy: the phone asks for the screen \(r.curtain.map { $0 ? "hidden" : "shown" } ?? "unchanged"), local input \(r.blockLocalInput.map { $0 ? "off" : "on" } ?? "unchanged")")
                    Task { await self.applyPrivacy() }
                case .fileBegin:
                    if let b = try? FileBegin(m) { fileReceiver.handle(b, nowNs: t2) }
                case .fileAccept:
                    if let a = try? FileAccept(m) { fileQueue.handle(a, nowNs: t2); filesChanged = true }
                case .fileProgress:
                    if let p = try? FileProgress(m) { fileQueue.handle(p, nowNs: t2); filesChanged = true }
                case .fileCancel:
                    if let c = try? FileCancel(m) { fileQueue.handle(c); fileReceiver.handle(c); filesChanged = true }
                default:
                    break
                }
            }
            if !replies.isEmpty { await server.send(replies, to: key) }
            if filesChanged { pumpFiles() }
            if rebuild {
                // A resized window takes a moment to settle before it's captured at its new size.
                if sourceWindow != nil { try? await Task.sleep(for: .milliseconds(200)) }
                await restartForDisplayChoice()
            }
    }

    // MARK: 1.1 features

    /// Mac → phone: the windows it can stream on their own, as a bulk transfer.
    private func sendWindowList() async {
        guard session != nil, peerCaps.contains(.windowStreaming) else { return }
        let list = WindowList(windows: await WindowSources.list())
        sendBulk(list.message)
    }

    /// `fit`: the window's size that shows at 1:1 on the phone's largest picture, inside its screen.
    private func fitWindow(_ id: CGWindowID, session: StreamSession) {
        guard let hello = streamHello, let info = WindowSources.info(id) else { return }
        let mode = initialMode(hello)
        let screen = WindowSources.visibleFrame(around: info.frame)
        let size = WindowSpace.fitted(pictureWidth: Double(mode.widthPoints), pictureHeight: Double(mode.heightPoints),
                                      screenWidth: screen.width, screenHeight: screen.height)
        let ok = WindowSources.resize(id, to: CGSize(width: size.width, height: size.height))
        print("window \(id): " + (ok ? "resized to \(Int(size.width))×\(Int(size.height)) pt" : "couldn't be resized (the app refused, or no Accessibility)"))
    }

    /// While a window is streamed: follow it as it moves (the input area), rebuild when it's resized,
    /// and go back to the whole screen when it closes.
    private func watchWindow(_ session: StreamSession) {
        windowWatch?.cancel()
        windowWatch = nil
        guard let w = session.window else { return }
        session.injector?.setArea(w.frame)
        // Captured on its own, the window shows on the phone even behind other windows; clicks would land on
        // whatever covers it. Bring it to the front now, and again before a click if something covers it.
        WindowSources.raise(w.id)
        session.injector?.beforeClick = { point in
            if !WindowSources.isFrontmost(w.id, at: point) { WindowSources.raise(w.id, wait: true) }
        }
        windowWatch = Task { [weak self] in
            var last = w.frame
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, self.session === session else { return }
                guard let now = WindowSources.info(w.id) else {
                    print("window \(w.id) closed: streaming the whole screen")
                    self.sourceWindow = nil
                    Task { await self.restartForDisplayChoice() }
                    return
                }
                if abs(now.frame.width - w.frame.width) > 2 || abs(now.frame.height - w.frame.height) > 2 {
                    print("window \(w.id) resized to \(Int(now.frame.width))×\(Int(now.frame.height)) pt: rebuilding the stream")
                    Task { await self.restartForDisplayChoice() }
                    return
                }
                if now.frame != last {
                    last = now.frame
                    session.injector?.setArea(now.frame)
                }
            }
        }
    }

    /// The phone's microphone, into the Clamshell Microphone driver (made on the first packet).
    private func micPacket(_ p: AudioPacket) {
        if mic == nil {
            do {
                mic = try MicPlayer()
                micDriverInstalled = true
                print("microphone: the phone's microphone plays into Clamshell Microphone")
            } catch {
                if !micWarned { print("microphone: \(error)"); micWarned = true }
                micDriverInstalled = false
                return
            }
        }
        mic?.handle(p)
    }

    /// Files to the phone (menu or Finder › Services). Returns a note for the menu (empty when all went).
    @discardableResult
    func sendFilesToPhone(_ urls: [URL]) -> String {
        guard session != nil else { lastFileNote = "Connect the phone first."; return lastFileNote }
        if peerCaps.contains(.filesV2) { queueFilesForPhone(urls); return "" }
        guard peerCaps.contains(.filesToPhone) else { lastFileNote = "The phone's app is too old to take files: update it."; return lastFileNote }
        var sent: [String] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { lastFileNote = "\(url.lastPathComponent) is a folder: zip it first."; continue }
            if let size = values?.fileSize, size > FileOffer.maxBytes {
                lastFileNote = "\(url.lastPathComponent) is over \(FileOffer.maxBytes / 1_048_576) MB."
                continue
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                lastFileNote = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            let bytes = [UInt8](data)
            sendBulk(FileOffer(name: FileOffer.safeName(url.lastPathComponent), sha256: Array(SHA256.hash(data: bytes)), data: bytes).message)
            sent.append(url.lastPathComponent)
            print("file: sent \(url.lastPathComponent) (\(bytes.count) bytes) to the phone")
        }
        if !sent.isEmpty { lastFileNote = "Sent " + (sent.count == 1 ? sent[0] : "\(sent.count) files") + " to the phone" }
        return sent.count == urls.count ? "" : lastFileNote
    }

    /// The menu's "Send a File to the iPhone…".
    func chooseFilesForPhone() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        let v2 = peerCaps.contains(.filesV2)
        panel.canChooseDirectories = v2
        panel.message = v2 ? "Choose files or folders for the phone. They go to Files › On My iPhone › Clamshell › From Mac."
                           : "Choose files for the phone (up to \(FileOffer.maxBytes / 1_048_576) MB each). They go to Files › On My iPhone › Clamshell › From Mac."
        panel.prompt = "Send"
        NSApplication.shared.activate()
        guard panel.runModal() == .OK else { return }
        sendFilesToPhone(panel.urls)
    }

    private func handleOther(_ event: HostSessionServer.Event, server: HostSessionServer) async {
        switch event {
        case .peerConnected, .messages:
            break
        case .pairingRequest(let r):
            print("pairing request from \(r.phoneName): SAS \(r.sas)")
            pairing?.requests.append(r)
            pairingTimer?.cancel()
            pairingWindow.show(pairingView())
            #if DEBUG
            if ProcessInfo.processInfo.environment["CLAMSHELL_PAIR_AUTOCONFIRM"] == "1" { await confirmPairing(r.id) }
            #endif
        case .pairingClosed:
            if let state = pairing, !state.done { state.message = "Pairing closed after failed attempts." }
            pairing = nil
            pairingWindow.close()
        case .peerDisconnected(let key):
            if session?.peerKey == key {
                endPrivacy(phoneMayReturn: !panicked)
                fileReceiver.suspend()
                await stopStreaming()
                if case .streaming = status, let port = await server.boundPort { status = .waiting(port: port) }
            }
        }
    }

    /// The Hello of the phone being streamed to, kept for a display mode rebuild.
    private var streamHello: Hello?

    private func stopStreaming() async {
        statsTask?.cancel()
        statsTask = nil
        bulkTask?.cancel()
        bulkTask = nil
        cursorMonitor?.stop()
        cursorMonitor = nil
        windowWatch?.cancel()
        windowWatch = nil
        mic?.stop()
        mic = nil
        clipboard?.stop()
        clipboard = nil
        if let a = audio { audio = nil; await a.stop() }
        localGuard.stop()
        barcode?.close()
        barcode = nil
        flash?.close()
        flash = nil
        if let s = session {
            session = nil
            await s.stop()
        }
        streamDescription = ""
        rateText = ""
        presence.release()
        if let a = streamingActivity { ProcessInfo.processInfo.endActivity(a); streamingActivity = nil }
    }

    private func restartAudio() async {
        if let a = audio { audio = nil; await a.stop() }
        audioSender?.cancel()
        audioSender = nil
        guard streamSound, session != nil, let peer = audioPeer, let server else { return }
        do {
            // One sender keeps packets in order; a stuck send drops old audio rather than queueing it.
            let (stream, out) = AsyncStream.makeStream(of: [AudioPacket].self, bufferingPolicy: .bufferingNewest(8))
            let a = try AudioCapture { packets in out.yield(packets) }
            audioSender?.cancel()
            audioSender = Task.detached(priority: .userInitiated) {
                for await p in stream { await server.send(p.map(\.message), to: peer) }
            }
            try await a.start()
            audio = a
        } catch {
            print("audio: \(error)")
        }
    }

    private func startStats() {
        lastLogged = nil          // a new session's counters start at zero
        tally = PathTally()
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let s = self.session, let server = self.server else { return }
                n += 1
                if s.checkReportsStale() { self.rateText = s.rateText }
                if n % 4 == 0 { await self.sendHostState() }
                // The phone moved between home Wi-Fi and the internet: rebuild the stream for the new path.
                if n % 4 == 0, await server.isLocalPath(of: s.peerKey) != nil, await self.isRemote(s.peerKey, server: server) != s.remote {
                    print("path changed to \(s.remote ? "this network" : "the internet"): restarting the stream")
                    // In a new task: the restart cancels this one (stopStreaming), which would cancel the restart too.
                    Task { await self.restartForDisplayChoice() }
                    return
                }
                let st = s.pipeline.currentStats
                if n % 20 == 0 { self.logStats(st, session: s) }
                self.stats = st
                let msg = HostStats(encodeMicros: UInt32(clamping: Int(st.lastEncodeMs * 1000)), framesSent: UInt32(clamping: st.framesSent),
                                    keyframes: UInt32(clamping: st.keyframes), refinements: UInt32(clamping: st.refinements),
                                    bytesSent: UInt64(st.bytesSent), encoderDrops: UInt32(clamping: st.encoderDrops),
                                    skippedWhileBusy: UInt32(clamping: st.skippedWhileBusy))
                await server.send([msg.message], to: s.peerKey)
            }
        }
    }

    /// Away from home: the session isn't on this network. A phone at home that dials the home's public address
    /// arrives from that address (the router loops it back), so it counts as home.
    private func isRemote(_ key: [UInt8], server: HostSessionServer) async -> Bool {
        if await server.isLocalPath(of: key) ?? true { return false }
        guard let home = publicAddress.ip, !home.isEmpty else { return true }
        return await server.sourceHost(of: key) != home
    }

    @ObservationIgnored private var lastLogged: (stats: HostVideoPipeline.Stats, at: ContinuousClock.Instant)?
    @ObservationIgnored private var tally = PathTally()

    /// Every 10 s while streaming, for diagnosing a session afterwards (host.log).
    private func logStats(_ st: HostVideoPipeline.Stats, session s: StreamSession) {
        let now = ContinuousClock.now
        defer { lastLogged = (st, now) }
        guard let (prev, at) = lastLogged else { return }
        let secs = max(Double((now - at).components.seconds), 1)
        let frames = st.framesSent - prev.framesSent
        print(String(format: "stats: %.0f fps · %.2f Mbit/s (target %.2f) · encode %.1f ms · %d keyframes · %d refines · dropped %d encoder %d busy",
                     Double(frames) / secs, Double(st.bytesSent - prev.bytesSent) * 8 / secs / 1e6, Double(s.targetBitrate) / 1e6,
                     st.lastEncodeMs, st.keyframes - prev.keyframes, st.refinements - prev.refinements,
                     st.encoderDrops - prev.encoderDrops, st.skippedWhileBusy - prev.skippedWhileBusy))
        print("path: " + tally.summary)
        tally = PathTally()
        if let c = s.injector?.takeCounts() {
            print("input: \(c.messages) messages from the phone · \(c.actions) posted · \(c.refused) refused (no Accessibility) · \(droppedInput) dropped while the Mac was in use")
        } else if droppedInput > 0 || s.injector == nil {
            print("input: no injector (the phone didn't offer input) · \(droppedInput) dropped")
        }
        droppedInput = 0
    }

    /// Mac → phone on every change and every 2 s (protocol 1.1 phones only).
    private func sendHostState() async {
        guard let s = session, let server, peerMinor >= 1 else { return }
        inputAllowed = InputInjector.allowed
        let msg = HostState(screen: presence.screen, keepsAwake: presence.holdingAwake,
                            targetBitrateKbps: UInt32(clamping: s.targetBitrate / 1000), fecPercent: s.fecPercent,
                            inputAllowed: peerCaps.contains(.inputV1) ? inputAllowed : nil, localUser: localGuard.active,
                            micReady: peerCaps.contains(.micOpus) ? micDriverInstalled : nil,
                            window: s.window.map { $0.title.isEmpty ? $0.app : $0.title }, fps: UInt16(clamping: s.fps),
                            curtain: curtainShown, localInputBlocked: localInputBlocked)
        await server.send([msg.message], to: s.peerKey)
    }

    private func startInput(_ session: StreamSession, cursor: Bool, server: HostSessionServer) {
        let peer = session.peerKey
        let scale = Double(max(session.mode.scale, 1))
        let size = CGSize(width: Double(session.width) / scale, height: Double(session.height) / scale)
        let injector = InputInjector(displayID: session.displayID, reportSize: size) { pos in
            let m = pos.message
            Task { await server.send([m], to: peer) }
        }
        session.injector = injector
        if let w = session.window { injector.setArea(w.frame) }
        injector.start()
        guard cursor else { return }
        let space = injector.pointerSpace
        if !space.isIdentity { print(String(format: "pointer: picture is smaller than the display, moves ×%.2f", space.scaleX)) }
        let monitor = CursorMonitor { [weak self] shape, isNew in
            injector.setShape(shape.shapeId)
            if isNew { self?.sendBulk(space.pictureShape(shape).message) }
        }
        cursorMonitor = monitor
        monitor.start()
    }

    /// Big messages (cursor images, clipboard) as reliable chunked transfers; resends every 150 ms.
    private func startBulk(server: HostSessionServer, peer: [UInt8]) {
        bulkTask?.cancel()
        bulkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                let resend = self.bulkOut.poll(nowNs: HostClock.nowNs())
                if !resend.isEmpty { await server.send(resend, to: peer) }
                self.pumpFiles()
            }
        }
    }

    private func sendBulk(_ m: InnerMessage) {
        guard let s = session, let server else { return }
        let chunks = bulkOut.send(m, nowNs: HostClock.nowNs())
        let peer = s.peerKey
        Task {
            // A burst of up to 4 MiB: in groups, so a big clipboard doesn't overrun the path at once.
            for group in stride(from: 0, to: chunks.count, by: 16) {
                await server.send(Array(chunks[group..<min(group + 16, chunks.count)]), to: peer)
                if chunks.count > 16 { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }
    }

    private func received(_ m: InnerMessage) {
        switch m.type {
        case .clipboardOffer:
            if clipboardSync, let offer = try? ClipboardOffer(m) { clipboard?.apply(offer) }
        case .fileOffer:
            // Always advertised so the phone offers it; refused here unless the menu toggle is on.
            guard let f = try? FileOffer(m) else { return }
            guard acceptFiles else {
                lastFileNote = "Refused \(FileOffer.safeName(f.name)) from the phone: turn on Accept files."
                return
            }
            saveFile(f)
        case .fileSegment:
            if let seg = try? FileSegment(m) { fileReceiver.handle(seg, nowNs: HostClock.nowNs()) }
        default:
            break
        }
    }

    // MARK: 1.9 privacy screen and files

    private var curtainWanted: Bool {
        guard let s = session else { return false }
        if let c = sessionCurtain { return c }
        switch curtainMode {
        case .off: return false
        case .away: return s.remote
        case .always: return true
        }
    }

    /// Puts the privacy screen and the input block in the state the settings and the phone ask for.
    private func applyPrivacy() async {
        guard let s = session else { return }
        if curtainWanted {
            let phone = streamHello?.deviceName ?? ""
            let ids = curtain.prepare(phone: phone, skipping: s.mirroring ? nil : s.displayID)
            curtain.onWindowsChanged = { [weak self] ids in
                guard let self, let s = self.session else { return }
                Task { if !(await s.exclude(ids)) { print("privacy: the new panels couldn't be left out of the picture") } }
            }
            if await s.exclude(ids) {
                curtain.reveal()
                if !curtainShown { print("privacy: this Mac's screen is hidden (\(ids.count) panel\(ids.count == 1 ? "" : "s"))") }
                curtainShown = true
            } else {
                // Never show the phone a black screen: no curtain rather than a broken one.
                print("privacy: couldn't leave the panels out of the picture; the screen stays visible")
                curtain.hide()
                curtainShown = false
            }
        } else if curtain.shown {
            curtain.hide()
            _ = await s.exclude([])
            curtainShown = false
            print("privacy: this Mac's screen is visible again")
        }
        let block = curtainShown && (sessionBlock ?? blockLocalInput) && InputInjector.allowed
        if block {
            blocker.onPanic = { [weak self] in self?.panic() }
            blocker.onAttempt = { [weak self] in self?.curtain.localAttempt() }
            blocker.start()
        } else {
            blocker.stop()
        }
        localInputBlocked = blocker.active
        curtain.setInputBlocked(blocker.active)
        await sendHostState()
    }

    /// The session ended: the keyboard and trackpad come back at once; the screen stays hidden a little
    /// longer if the phone may just be reconnecting.
    private func endPrivacy(phoneMayReturn: Bool) {
        blocker.stop()
        localInputBlocked = false
        if curtain.shown {
            if phoneMayReturn { curtain.linger(seconds: 20) } else { curtain.hide() }
        }
        curtainShown = false
    }

    /// Esc ×3 at the Mac.
    private func panic() {
        panicked = true
        endPrivacy(phoneMayReturn: false)
        Task { await disconnectAll() }
    }

    /// Prepares (hashes) and queues files and folders for the phone (1.9).
    private func queueFilesForPhone(_ urls: [URL]) {
        let what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        lastFileNote = "Preparing \(what)…"
        Task {
            do {
                let files = try await Task.detached(priority: .userInitiated) { try FileListing.prepare(urls) }.value
                guard !files.isEmpty else { lastFileNote = "Nothing to send in \(what) (empty, or only hidden files)."; return }
                fileQueue.pruneFinished()
                fileQueue.enqueue(files)
                let total = files.reduce(UInt64(0)) { $0 + $1.size }
                lastFileNote = ""
                print("file: queued \(files.count) file\(files.count == 1 ? "" : "s") (\(FileListing.size(total))) for the phone")
                pumpFiles()
            } catch {
                lastFileNote = "Couldn't read \(what): \(error.localizedDescription)"
            }
        }
    }

    /// Sends what the file queue has ready: announcements, and segments as bulk transfers.
    private func pumpFiles() {
        guard let s = session, let server, peerCaps.contains(.filesV2), fileQueue.busy else {
            if transferFraction != nil || !transferText.isEmpty { updateTransferText() }
            return
        }
        let (control, segments) = fileQueue.poll(nowNs: HostClock.nowNs()) { FileListing.read($0, offset: $1, count: $2) }
        if !control.isEmpty {
            let peer = s.peerKey
            Task { await server.send(control, to: peer) }
        }
        for m in segments { sendBulk(m) }
        updateTransferText()
        for item in fileQueue.items where item.phase.finished && !reported.contains(item.id) {
            reported.insert(item.id)
            switch item.phase {
            case .saved(let name): print("file: \(name) saved on the phone")
            case .failed(let why): lastFileNote = "Couldn't send \(item.file.name): \(why)"; print("file: \(item.file.path) failed: \(why)")
            default: break
            }
        }
    }
    @ObservationIgnored private var reported: Set<UInt32> = []
    @ObservationIgnored private var lastTransferUpdate = ContinuousClock.now

    private func updateTransferText() {
        let now = ContinuousClock.now
        let sending = fileQueue.busy, receiving = fileReceiver.busy
        // At most 4 redraws a second while bytes flow; at once when something starts or ends.
        if (sending || receiving), transferFraction != nil, now - lastTransferUpdate < .milliseconds(250) { return }
        lastTransferUpdate = now
        if sending, let cur = fileQueue.current {
            let t = fileQueue.totals
            let files = t.files > 1 ? " (\(t.filesDone + 1) of \(t.files))" : ""
            let verb = cur.phase == .checking ? "Checking" : "Sending"
            transferText = "\(verb) \(cur.file.name)\(files) to the phone · \(FileListing.size(t.done)) of \(FileListing.size(t.total))"
            transferFraction = t.total == 0 ? 0 : Double(t.done) / Double(t.total)
        } else if receiving, let st = fileReceiver.status {
            let files = st.count > 1 ? " (\(st.index + 1) of \(st.count))" : ""
            let verb = st.state == .checking ? "Checking" : "Receiving"
            transferText = "\(verb) \(st.name)\(files) · \(FileListing.size(st.received)) of \(FileListing.size(st.size))"
            transferFraction = st.fraction
        } else {
            transferText = ""
            transferFraction = nil
            if case .failed(let why)? = fileReceiver.status?.state { lastFileNote = why }
        }
    }

    /// The menu's "Cancel Transfers": stops sending and receiving. A partial file stays, so sending it
    /// again later resumes it.
    func cancelTransfers() {
        let cancels = fileQueue.cancelAll()
        if let s = session, let server, !cancels.isEmpty {
            let peer = s.peerKey
            Task { await server.send(cancels, to: peer) }
        }
        fileReceiver.cancel()
        bulkOut.cancelAll()
        lastFileNote = "Transfers cancelled"
        updateTransferText()
    }

    /// A file from the phone: checked against its SHA-256, then written to Downloads under a safe, unused name.
    private func saveFile(_ f: FileOffer) {
        guard Array(SHA256.hash(data: f.data)) == f.sha256 else {
            lastFileNote = "A file from the phone arrived damaged and was not saved."
            print("file: hash mismatch for \(f.name)")
            return
        }
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let url = Self.unusedURL(in: downloads, name: FileOffer.safeName(f.name))
        do {
            try Data(f.data).write(to: url, options: [.withoutOverwriting])
            lastFileNote = "Saved \(url.lastPathComponent) to Downloads"
            print("file: saved \(url.path) (\(f.data.count) bytes)")
        } catch {
            lastFileNote = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
            print("file: \(error)")
        }
    }

    static func unusedURL(in dir: URL, name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        let ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return url
    }

    private func updateClipboard() {
        clipboard?.stop()
        clipboard = nil
        guard clipboardSync, session != nil, peerCaps.contains(.clipboardV1) else { return }
        let c = ClipboardSync { [weak self] offer in self?.sendBulk(offer.message) }
        clipboard = c
        c.start()
    }

    private func updateBarcode() {
        barcode?.close()
        barcode = nil
        if barcodeEnabled, let s = session { barcode = BarcodeOverlay(displayID: s.displayID) }
        flash?.close()
        flash = nil
        if flashEnabled, let s = session { flash = FlashOverlay(virtualDisplayID: s.displayID) }
    }
}

/// One phone's stream: the virtual display lives exactly as long as the session.
@MainActor
final class StreamSession {
    let peerKey: [UInt8]
    let mode: DisplayMode
    /// The display streamed and driven: the Mac's main display when mirroring, else the virtual one.
    let displayID: CGDirectDisplayID
    let mirroring: Bool
    let width: Int, height: Int
    /// Only for a separate display; it lives exactly as long as the session.
    private let virtualDisplay: VirtualDisplay?
    let pipeline: HostVideoPipeline
    private let capture: ScreenCapture
    private var patternTask: Task<Void, Never>?
    private let sender: Task<Void, Never>
    private let outbox: AsyncStream<OutFrame>.Continuation
    private let pacer: OSAllocatedUnfairLock<Pacer>
    /// Nil for a phone that sends no `ReceiverReport`s (protocol 1.0): it gets the fixed bitrate.
    private var controller: BitrateController?
    private let fecAllowed: Bool
    private var lastReport: (atNs: UInt64, wireBytes: Int)?
    private var sentEWMA = 0.0
    private(set) var targetBitrate: Int
    var injector: InputInjector?
    let remote: Bool
    let fps: Int
    /// The one window streamed (1.8), with its frame when the stream started; nil for a whole screen.
    let window: StreamedWindow?
    struct StreamedWindow: Sendable {
        let id: CGWindowID
        let frame: CGRect
        let title: String
        let app: String
    }
    static let remoteMaxWidth = 1600
    /// One pass at 400 ms to a readable QP, instead of 120 ms + 400 ms down to near-lossless QP 12.
    static let remoteRefinement = [RefinementScheduler.Stage(delay: .milliseconds(400), maxQP: 24)]

    /// - Parameters:
    ///   - adaptive: the phone sends `ReceiverReport`s, so rate control and pacing are on.
    ///   - fec: the phone understands XOR parity fragments (`fecXor`). Never send parity to one that doesn't:
    ///     it would take a parity fragment for a data one.
    ///   - remote: the phone is on the internet, not this network. The Mac's upload (often a few Mbit/s) is
    ///     then the bottleneck, and a full-size 4:4:4 frame takes seconds to send, so: at most 1600 px wide,
    ///     4:2:0, 60 fps, a lower start bitrate, and one lighter refinement instead of a near-lossless one.
    init(peerKey: [UInt8], mode: DisplayMode, use444: Bool, adaptive: Bool, fec: Bool, clientCursor: Bool, mirror: Bool,
         remote: Bool = false, continuing: (frameId: UInt32, generation: UInt16)? = nil,
         window windowID: CGWindowID? = nil, fpsCap: UInt16 = 0, excluding: [CGWindowID] = [], server: HostSessionServer) async throws {
        self.peerKey = peerKey
        self.mode = mode
        self.remote = remote
        fps = FrameRateRequest.effective(modeHz: remote ? min(Int(mode.refreshHz), 60) : Int(mode.refreshHz), cap: fpsCap)
        let testPattern = ProcessInfo.processInfo.environment["CLAMSHELL_TEST_PATTERN"] == "1"
        guard testPattern || CGPreflightScreenCaptureAccess() else { throw StartError.noScreenRecording }
        let w: Int, h: Int
        if let windowID, !testPattern {
            // One window (1.8): at its own pixels, scaled down to fit the phone's picture (never up).
            guard let info = WindowSources.info(windowID), let display = WindowSources.display(for: info.frame) else { throw StartError.windowGone }
            let (pw, _) = Self.pixelSize(display)
            let backing = max(1, Double(pw) / max(CGDisplayBounds(display).width, 1))
            let ww = info.frame.width * backing, wh = info.frame.height * backing
            var fit = min(Double(mode.widthPixels) / ww, Double(mode.heightPixels) / wh, 1)
            if remote { fit = min(fit, Double(Self.remoteMaxWidth) / ww) }
            w = max(Int(ww * fit) & ~1, 64)
            h = max(Int(wh * fit) & ~1, 64)
            displayID = display
            virtualDisplay = nil
            mirroring = true
            window = StreamedWindow(id: windowID, frame: info.frame, title: info.title, app: info.app)
        } else if mirror, let main = Self.realDisplay() {
            // The whole Mac: its main display, scaled down to fit the phone's largest posture (never up).
            let (pw, ph) = Self.pixelSize(main)
            var fit = min(Double(mode.widthPixels) / Double(pw), Double(mode.heightPixels) / Double(ph), 1)
            if remote { fit = min(fit, Double(Self.remoteMaxWidth) / Double(pw)) }
            w = Int(Double(pw) * fit) & ~1
            h = Int(Double(ph) * fit) & ~1
            displayID = main
            virtualDisplay = nil
            mirroring = true
            window = nil
        } else {
            w = Int(mode.widthPixels)
            h = Int(mode.heightPixels)
            let v = try VirtualDisplay(name: "Clamshell", pixelWidth: w, pixelHeight: h, refreshHz: Double(mode.refreshHz))
            _ = await v.waitUntilOnline()
            _ = v.selectMode()
            displayID = v.displayID
            virtualDisplay = v
            mirroring = false
            window = nil
        }
        width = w
        height = h

        var cfg = EncoderConfig(width: w, height: h)
        cfg.fps = fps
        // Ceiling 50 Mbit/s (M1: 25 dropped ~half the frames of a continuous full-screen scroll on the LAN).
        // Override: `defaults write <bundle id> bitrateMbps 80`. With reports the controller starts at
        // 8 Mbit/s, below a typical hotel or LTE downlink; its start-up ramp reaches a LAN's ceiling in ~2 s.
        let mbps = UserDefaults.standard.integer(forKey: "bitrateMbps")
        let ceiling = (mbps > 0 ? mbps : 50) * 1_000_000
        let start = adaptive ? min(ceiling, remote ? 3_000_000 : 8_000_000) : ceiling
        cfg.averageBitrate = start
        targetBitrate = start
        controller = adaptive ? BitrateController(start: start, min: 1_500_000, max: ceiling) : nil
        fecAllowed = fec
        let pacer = OSAllocatedUnfairLock(initialState: Pacer(bitrate: Int(Double(start) * BitrateController.pacingFactor), factor: 1))
        self.pacer = pacer
        if use444 { cfg.profile = .named("HEVC_Main444_AutoLevel") }

        // Frames go out in order through one sender task. Encoded frames are never dropped (a lost P-frame
        // breaks the chain); instead the pipeline stops encoding while 2 frames are unsent, and the newest
        // capture waits. The outbox can't grow past that, so it is unbounded.
        let (stream, outbox) = AsyncStream.makeStream(of: OutFrame.self, bufferingPolicy: .unbounded)
        self.outbox = outbox
        let pipeline = try HostVideoPipeline(config: cfg, chroma: use444 ? .yuv444 : .yuv420,
                                             refinement: remote ? Self.remoteRefinement : RefinementScheduler.defaultStages,
                                             sessionOverhead: SecureSession.overhead, maxUnsentFrames: 2,
                                             continuing: continuing, keyframeBitrateCeiling: ceiling) { payloads, id, key in
            outbox.yield(OutFrame(payloads: payloads, frameId: id, isKeyframe: key))
        }
        self.pipeline = pipeline
        sender = Task.detached(priority: .userInitiated) {
            for await frame in stream {
                await Self.send(frame, server: server, to: peerKey, pacer: adaptive ? pacer : nil, pipeline: pipeline)
                pipeline.frameSent()
            }
        }
        pipeline.start()
        capture = ScreenCapture { frame, captureNs, damaged in
            pipeline.submit(frame, captureTimeNs: captureNs, damaged: damaged)
        }
        if testPattern {
            // No capture: synthetic code text scrolls for 1 s, then holds still for 1 s (damage skip +
            // refinement), at the display's rate. Lets the network path be tested without Screen Recording.
            patternTask = Task.detached(priority: .userInitiated) {
                let fps = Int(mode.refreshHz)
                var frames: [SharedPixelBuffer] = []
                for i in 0..<fps { if let b = TestPattern.pixelBuffer(width: w, height: h, phase: i * 2) { frames.append(SharedPixelBuffer(b)) } }
                guard !frames.isEmpty else { return }
                var tick = 0
                while !Task.isCancelled {
                    let cycle = tick % (2 * fps)
                    let moving = cycle < fps
                    pipeline.submit(frames[min(cycle, frames.count - 1)], captureTimeNs: HostClock.nowNs(), damaged: moving)
                    tick += 1
                    try? await Task.sleep(for: .microseconds(1_000_000 / fps))
                }
            }
            return
        }
        // 4:4:4 needs full chroma from SCK, so BGRA (the pipeline converts to 444v); 4:2:0 takes 420v as is.
        try await capture.start(displayID: displayID, windowID: window?.id, width: w, height: h, fps: fps, showsCursor: !clientCursor,
                                pixelFormat: use444 ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                excluding: excluding)
    }

    /// Leaves these windows (the privacy screen) out of the picture. True once they are.
    func exclude(_ ids: [CGWindowID]) async -> Bool {
        if ProcessInfo.processInfo.environment["CLAMSHELL_TEST_PATTERN"] == "1" { return true }
        return await capture.exclude(ids)
    }

    /// `CLAMSHELL_RATE_LOG=1`: one line per receiver report (10 a second), for netsim runs.
    private static let rateLog = ProcessInfo.processInfo.environment["CLAMSHELL_RATE_LOG"] == "1"

    var fecPercent: UInt8 {
        guard fecAllowed, let g = controller?.parityGroup, g > 0 else { return 0 }
        return UInt8(clamping: 100 / g)
    }

    var rateText: String {
        String(format: "%.1f Mbit/s", Double(targetBitrate) / 1e6) + (fecPercent > 0 ? " · FEC \(fecPercent)%" : "")
    }

    /// Feeds one `ReceiverReport` to the controller. Returns whether the rate changed.
    func handle(_ r: ReceiverReport) -> Bool {
        let now = HostClock.nowNs()
        let wire = pipeline.currentStats.wireBytes
        if let last = lastReport, now > last.atNs {
            // Frames leave in lumps (a big one, then nothing for 100 ms): average over ~1 s.
            let instant = Double(wire - last.wireBytes) * 8 / (Double(now - last.atNs) / 1e9)
            sentEWMA = sentEWMA * 0.9 + instant * 0.1
        }
        lastReport = (now, wire)
        let sent = Int(sentEWMA)
        // The phone measures the path alone (ping RTT inflation). `own` is the Mac's waiting, for the log.
        let ownMicros = Int(pipeline.currentStats.senderDelayMicros)
        let pathMs = Double(r.queuingDelayMicros) / 1000
        if Self.rateLog {
            print(String(format: "rate: path q %.1f own %.1f rtt %.1f ms · loss %.3f lost %d · sent %.2f · target %.2f pace %.2f Mbit/s",
                         pathMs, Double(ownMicros) / 1000, Double(r.rttMicros) / 1000, r.fragmentLoss, Int(r.framesLost),
                         Double(sent) / 1e6, Double(targetBitrate) / 1e6, Double(controller?.pacingRate ?? 0) / 1e6))
        }
        return apply(nowNs: now, loss: r.fragmentLoss, framesLost: Int(r.framesLost),
                     queuingDelayMs: pathMs, sentBitrate: sent, rttMicros: r.rttMicros)
    }

    /// No report for a second while streaming means the path back is gone or badly congested: back off as
    /// if a tenth of everything were lost. Returns whether the rate changed.
    func checkReportsStale() -> Bool {
        guard controller != nil, let last = lastReport else { return false }
        let now = HostClock.nowNs()
        guard now > last.atNs + 1_000_000_000 else { return false }
        return apply(nowNs: now, loss: 0.11, framesLost: 1, queuingDelayMs: 0, sentBitrate: 0, rttMicros: 0)
    }

    private func apply(nowNs: UInt64, loss: Double, framesLost: Int, queuingDelayMs: Double, sentBitrate: Int, rttMicros: UInt32) -> Bool {
        guard var c = controller else { return false }
        let before = c.decision
        let d = c.update(nowNs: nowNs, loss: loss, framesLost: framesLost, queuingDelayMs: queuingDelayMs, sentBitrate: sentBitrate)
        controller = c
        targetBitrate = d.bitrate
        pipeline.setRate(bitrate: d.bitrate, parityGroup: fecAllowed ? d.parityGroup : 0, rttMicros: rttMicros)
        pacer.withLock { $0.bitrate = d.pacingRate }
        return d != before
    }

    /// One frame's datagrams, spread out by the pacer (nil = all at once, for 1.0 phones). Datagrams that
    /// fit the pacer's burst go in one batch; then it waits for the budget to refill.
    struct OutFrame: Sendable {
        let payloads: [[UInt8]]
        let frameId: UInt32
        let isKeyframe: Bool
    }

    nonisolated private static func send(_ frame: OutFrame, server: HostSessionServer, to peer: [UInt8],
                                         pacer: OSAllocatedUnfairLock<Pacer>?, pipeline: HostVideoPipeline) async {
        guard let pacer else {
            pipeline.sendStarted(frameId: frame.frameId, nowNs: HostClock.nowNs())
            await server.sendPayloads(frame.payloads, to: peer)
            return
        }
        // The pacer's bitrate is the controller's pacing rate (≤ 2.5 × target); keyframes go at half of it.
        pacer.withLock { $0.factor = frame.isKeyframe ? 0.5 : 1 }
        var batch: [[UInt8]] = []
        for (i, p) in frame.payloads.enumerated() {
            let size = p.count + SecureSession.overhead + 28          // + IPv4/UDP headers
            let wait = pacer.withLock { $0.delayNs(for: size, nowNs: HostClock.nowNs()) }
            if wait > 0 {
                if !batch.isEmpty { await server.sendPayloads(batch, to: peer); batch.removeAll(keepingCapacity: true) }
                try? await Task.sleep(for: .nanoseconds(Int(wait)))
            }
            if i == 0 { pipeline.sendStarted(frameId: frame.frameId, nowNs: HostClock.nowNs()) }
            pacer.withLock { $0.sent(size, nowNs: HostClock.nowNs()) }
            batch.append(p)
        }
        if !batch.isEmpty { await server.sendPayloads(batch, to: peer) }
    }

    func stop() async {
        injector?.stop()
        injector = nil
        patternTask?.cancel()
        await capture.stop()
        pipeline.stop()
        outbox.finish()
        sender.cancel()
    }

    /// The main display if it's on, else any other real (non-Clamshell) display that is; nil with the lid
    /// closed and no monitor.
    static func realDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &n) == .success else { return nil }
        let active = ids.prefix(Int(n)).filter { CGDisplayVendorNumber($0) != VirtualDisplay.vendorID && CGDisplayIsAsleep($0) == 0 }
        let main = CGMainDisplayID()
        return active.contains(main) ? main : active.first
    }

    static func pixelSize(_ id: CGDirectDisplayID) -> (Int, Int) {
        if let m = CGDisplayCopyDisplayMode(id) { return (m.pixelWidth, m.pixelHeight) }
        return (CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id))
    }

    enum StartError: Error, CustomStringConvertible {
        case noScreenRecording, windowGone
        var description: String {
            switch self {
            case .noScreenRecording: "Screen Recording is not allowed for Clamshell Host (System Settings › Privacy & Security)"
            case .windowGone: "the window closed"
            }
        }
    }
}

private extension UInt16 {
    var nonZero: UInt16? { self == 0 ? nil : self }
}

/// What the phone said about the path between two `stats:` lines: its loss, delay and keyframe requests.
struct PathTally {
    private var expected = 0, received = 0, fec = 0, lost = 0, completed = 0, bytes = 0
    private var maxDelayUs: UInt32 = 0, rttUs: UInt32 = 0
    private var reasons: [String: Int] = [:]

    mutating func add(_ r: ReceiverReport) {
        bytes += Int(r.bytesReceived)
        expected += Int(r.fragmentsExpected)
        received += Int(r.fragmentsReceived)
        fec += Int(r.fecRecovered)
        lost += Int(r.framesLost)
        completed += Int(r.framesCompleted)
        maxDelayUs = max(maxDelayUs, r.queuingDelayMicros)
        rttUs = r.rttMicros
    }

    mutating func request(_ reason: KeyframeReason?) {
        let name = switch reason {
        case .sessionStart: "start"
        case .frameLost: "lost"
        case .decoderError: "decoder"
        case .formatChanged: "format"
        case .unknown, nil: "other"
        }
        reasons[name, default: 0] += 1
    }

    var summary: String {
        let loss = expected > 0 ? Double(expected - received) / Double(expected) * 100 : 0
        let asks = reasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return String(format: "phone got %.0f KB · fragment loss %.1f%% (%d fixed by FEC) · frames %d shown %d lost · delay up to %d ms · rtt %d ms · keyframe asks: %@",
                      Double(bytes) / 1024, loss, fec, completed, lost, Int(maxDelayUs / 1000), Int(rttUs / 1000), asks.isEmpty ? "none" : asks)
    }
}
