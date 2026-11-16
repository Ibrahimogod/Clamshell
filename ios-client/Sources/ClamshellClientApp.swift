import ClamshellInput
import ClamshellSession
import ClamshellWire
import SwiftUI

@main
struct ClamshellClientApp: App {
    @State private var client = ClientController()

    var body: some Scene {
        WindowGroup {
            RootView(client: client)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .task {
                    if CommandLine.arguments.contains("--probe") { await DecodeProbe.printReport() }
                    client.startBrowsing()
                }
        }
    }
}

struct RootView: View {
    @Bindable var client: ClientController
    @State private var showProbes = false

    var body: some View {
        Group {
        switch client.phase {
        case .streaming:
            StreamView(client: client)
        default:
            NavigationStack {
                ConnectView(client: client)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Probes") { showProbes = true }
                        }
                    }
                    .sheet(isPresented: $showProbes) { ProbeView() }
            }
        }
        }
        .background(PostureSensor(model: client.posture).ignoresSafeArea())
    }
}

struct ConnectView: View {
    @Bindable var client: ClientController

    var body: some View {
        Form {
            PairingSection(client: client)
            Section("Macs on this network") {
                if client.hosts.isEmpty {
                    HStack { ProgressView(); Text("Looking for Clamshell Host…").foregroundStyle(.secondary) }
                }
                ForEach(client.hosts, id: \.name) { host in
                    Button { client.connect(to: host) } label: {
                        HStack {
                            Image(systemName: "laptopcomputer")
                            Text(host.name)
                            Spacer()
                            if case .connecting(let name) = client.phase, name == host.name { ProgressView() }
                        }
                    }
                    .disabled(!client.isPaired)
                }
            }
            Section {
                TextField("203.0.113.7:51820", text: $client.manualAddress)
                    .font(.footnote.monospaced())
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LabeledContent("TCP fallback port") {
                    TextField("443", value: $client.tcpPort, format: .number.grouping(.never))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).font(.footnote.monospaced())
                }
                Button("Connect to this address") { client.connectManual() }
                    .disabled(!client.isPaired || !client.manualAddressValid)
            } header: {
                Text("Away from home")
            } footer: {
                Text("Over cellular or another Wi-Fi the Mac can't be found automatically. Enter your home address and the UDP port forwarded to the Mac. The app also tries TLS on the TCP port (443) for networks that block UDP, and uses whichever answers first (docs/SETUP.md › Away from home).")
            }
            if client.isPaired {
                Section {
                    ForEach(client.checks) { c in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: c.ok == nil ? "circle.dotted" : c.ok == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(c.ok == nil ? Color.secondary : c.ok == true ? Color.green : Color.red)
                            VStack(alignment: .leading) {
                                Text(c.id)
                                Text(c.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button(client.checking ? "Checking…" : "Check connection") { client.runNetworkCheck() }
                        .disabled(client.checking)
                } header: {
                    Text("Network check")
                } footer: {
                    Text("Tries each way to reach the Mac on its own. On a network that blocks UDP, only the TCP line turns green; that's enough. If nothing answers away from home, check the router's port forwards (docs/SETUP.md).")
                }
            }
            if case .failed(let message) = client.phase {
                Section { Text(message).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                Toggle("Glass-to-glass camera test", isOn: $client.cameraTestEnabled)
            } header: {
                Text("Latency test")
            } footer: {
                Text("On the Mac, turn on Clamshell Host › Flash square. Stand this phone 20–40 cm from the Mac with its rear camera facing the Mac's screen, then connect. The result appears in the HUD.")
            }
            Section("This phone") {
                LabeledContent("HEVC 4:4:4 decode", value: client.hevc444Text)
                Toggle("Touch ID before connecting", isOn: $client.requireBiometrics)
                Toggle("Play the Mac's sound", isOn: $client.sound)
            }
        }
        .navigationTitle("Clamshell")
    }
}

struct PairingSection: View {
    @Bindable var client: ClientController
    @State private var code = ""
    @State private var scanning = false

    var body: some View {
        Section {
            if let mac = client.pairedMac {
                LabeledContent("Paired with", value: mac.name.isEmpty ? "Mac" : mac.name)
                Button("Forget this Mac", role: .destructive) { client.forgetMac() }
            } else {
                switch client.pairingStatus {
                case .working:
                    HStack { ProgressView(); Text("Talking to the Mac…").foregroundStyle(.secondary) }
                case .sas(let sas):
                    VStack(spacing: 6) {
                        Text(String(sas.prefix(3)) + " " + String(sas.suffix(3)))
                            .font(.system(size: 40, weight: .semibold, design: .monospaced))
                        Text("Check that the Mac shows the same digits, then click Pair on the Mac.").font(.footnote).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                default:
                    if QRScanner.isAvailable { Button("Scan the Mac's pairing code") { scanning = true } }
                    TextField("ABCD-EFGH-JKLM-NPQR", text: $code)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("Pair with this code") { client.pair(code: code) }
                        .disabled(PairingInvite(string: code) == nil)
                    if case .failed(let m) = client.pairingStatus { Text(m).font(.footnote).foregroundStyle(.red) }
                }
            }
        } header: {
            Text("Pairing")
        } footer: {
            if !client.isPaired {
                Text("At home, on the Mac's Wi-Fi: Clamshell Host › Pair new iPhone…, then scan the code or type it here. You confirm 6 digits on the Mac. Pairing happens only on your network; nothing goes through a server.")
            }
        }
        .sheet(isPresented: $scanning) {
            QRScanner { text in
                scanning = false
                client.pair(code: text)
            }
            .ignoresSafeArea()
        }
    }
}

struct StreamView: View {
    let client: ClientController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showKeyboard = true

    var body: some View {
        GeometryReader { geo in
            let fold = foldRect(in: geo)
            switch client.posture.layout {
            case .laptop: laptop(geo, fold: fold)
            case .book: book(geo, fold: fold)
            case .flat: flat(geo)
            case .cover: cover
            }
        }
        .background(Color(DeckStyle.base).ignoresSafeArea())
        .defersSystemGestures(on: .all)
        .onChange(of: scenePhase) { _, phase in if phase != .active { client.releaseInput() } }
    }

    /// The fold in this view's coordinates, if the phone reports one.
    private func foldRect(in geo: GeometryProxy) -> CGRect? {
        guard let f = client.posture.fold, f.width > 0 || f.height > 0 else { return nil }
        let origin = geo.frame(in: .global).origin
        return f.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    private func screen(direct: Bool, centered: Bool) -> some View {
        ZStack(alignment: .top) {
            Color.black
            VideoSurface(client: client, directTouch: direct && client.input != nil, centered: centered)
            if let banner = client.hud.macBanner { BannerView(text: banner, locked: client.hud.macScreen == .locked) }
            if client.showHUD { VStack { Spacer(); HUDView(hud: client.hud).padding(.bottom, 6) } }
        }
        .clipped()
    }

    /// Laptop: the Mac above the fold, the deck below it. Nothing interactive sits on the fold.
    private func laptop(_ geo: GeometryProxy, fold: CGRect?) -> some View {
        let horizontalFold = fold.map { $0.width >= $0.height } ?? false
        let top = horizontalFold ? max(fold?.minY ?? 0, 100) : min(geo.size.width * 667 / 939, geo.size.height * 0.6)
        let gap = horizontalFold ? fold?.height ?? 0 : 0
        return VStack(spacing: 0) {
            screen(direct: false, centered: false).frame(height: top)
            Color(DeckStyle.base).frame(height: gap).accessibilityHidden(true)
            SeamBar(client: client, showKeyboard: $showKeyboard)
            lower(mode: client.deckMode)
        }
    }

    /// Book: the Mac on the left page, the deck on the right one.
    private func book(_ geo: GeometryProxy, fold: CGRect?) -> some View {
        let verticalFold = fold.map { $0.height > $0.width } ?? false
        let left = verticalFold ? fold?.minX ?? geo.size.width / 2 : geo.size.width / 2
        let gap = verticalFold ? fold?.width ?? 0 : 0
        return HStack(spacing: 0) {
            screen(direct: client.directTouch, centered: true).frame(width: left)
            Color(DeckStyle.base).frame(width: gap).accessibilityHidden(true)
            VStack(spacing: 0) {
                SeamBar(client: client, showKeyboard: $showKeyboard)
                lower(mode: client.deckMode)
            }
        }
    }

    /// Flat: one big screen. Touch clicks where you touch (or the picture is a trackpad), a small keyboard
    /// on demand, edge swipes for Spaces.
    private func flat(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            ZStack {
                screen(direct: client.directTouch, centered: true)
                if !client.directTouch, let input = client.input { Trackpad(input: input, overlay: true) }
            }
            if showKeyboard, let input = client.input {
                KeyboardDeck(input: input).frame(height: min(230, geo.size.height * 0.3))
            }
            SeamBar(client: client, showKeyboard: $showKeyboard)
        }
    }

    /// Closed: a glance at the Mac on the cover screen; touch still clicks.
    private var cover: some View {
        ZStack(alignment: .topTrailing) {
            screen(direct: true, centered: true)
            Button(role: .destructive) { client.disconnect() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                .tint(.white).padding(10)
                .accessibilityLabel("Disconnect")
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func lower(mode: DeckMode) -> some View {
        if let input = client.input {
            Group {
                switch mode {
                case .deck:
                    VStack(spacing: 6) {
                        if showKeyboard { KeyboardDeck(input: input).frame(maxHeight: 260) }
                        Trackpad(input: input).padding(.horizontal, 10)
                    }
                case .split:
                    HStack(spacing: 6) {
                        KeyboardDeck(input: input).frame(maxWidth: .infinity)
                        Trackpad(input: input).frame(maxWidth: 220)
                    }
                    .padding(.horizontal, 6)
                case .pad:
                    Trackpad(input: input).padding(10)
                case .keys:
                    KeyboardDeck(input: input)
                }
            }
            .padding(.bottom, 6)
            .background(Color(DeckStyle.base))
        } else {
            Color(DeckStyle.base).overlay(Text("This Mac doesn't take input from the phone.").font(.footnote).foregroundStyle(.secondary))
        }
    }
}

/// Posture pin, deck mode and touch mode (ADR-0012 overrides).
struct PostureMenu: View {
    @Bindable var client: ClientController

    var body: some View {
        Menu {
            Picker("Posture", selection: Binding(get: { client.posture.pinned }, set: { client.posture.pinned = $0 })) {
                Text("Automatic").tag(Posture?.none)
                Label("Laptop", systemImage: "laptopcomputer").tag(Posture?.some(.laptop))
                Label("Book", systemImage: "book").tag(Posture?.some(.book))
                Label("Flat", systemImage: "rectangle").tag(Posture?.some(.flat))
            }
            Picker("Lower half", selection: $client.deckMode) {
                Text("Keyboard + trackpad").tag(DeckMode.deck)
                Text("Side by side").tag(DeckMode.split)
                Text("Trackpad only").tag(DeckMode.pad)
                Text("Keyboard only").tag(DeckMode.keys)
            }
            Toggle("Touch clicks on the picture", isOn: $client.directTouch)
            Toggle("Sound", isOn: $client.sound)
            if let hw = client.hardware, hw.keyboardConnected {
                Toggle("⌥-Tab and ⌃-Space as ⌘-Tab and ⌘-Space", isOn: Binding(get: { hw.remapEnabled }, set: { hw.remapEnabled = $0 }))
            }
        } label: {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
        }
        .accessibilityLabel("Layout")
    }
}

/// The bar between the screen and the deck: path, HUD, clipboard, keyboard and disconnect.
struct SeamBar: View {
    let client: ClientController
    @Binding var showKeyboard: Bool
    @State private var pickingFile = false

    var body: some View {
        HStack(spacing: 14) {
            Text([client.hud.pathName, client.hud.rttMs.map { String(format: "%.0f ms", $0) } ?? "–"].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color(DeckStyle.ember).opacity(0.25), in: Capsule())
            if let note = client.lastClipboardNote { Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            PostureMenu(client: client)
            Button { client.showHUD.toggle() } label: { Image(systemName: "gauge.with.dots.needle.33percent") }
                .accessibilityLabel("Stream statistics")
            Button { client.sendClipboard() } label: { Image(systemName: "doc.on.clipboard") }
                .accessibilityLabel("Send the phone's clipboard to the Mac")
            if client.macCaps.contains(.filesV1) {
                Button { pickingFile = true } label: { Image(systemName: "square.and.arrow.up.on.square") }
                    .accessibilityLabel("Send a file to the Mac's Downloads")
            }
            Button { showKeyboard.toggle() } label: { Image(systemName: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard") }
                .accessibilityLabel(showKeyboard ? "Hide keyboard" : "Show keyboard")
            Button(role: .destructive) { client.disconnect() } label: { Image(systemName: "xmark.circle") }
                .accessibilityLabel("Disconnect")
        }
        .font(.body)
        .tint(.white)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color(DeckStyle.base))
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { client.sendFile(url) }
        }
    }
}

struct BannerView: View {
    let text: String
    let locked: Bool
    var body: some View {
        Label(text, systemImage: locked ? "lock.fill" : "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.75), in: Capsule())
            .padding(.top, 12)
            .allowsHitTesting(false)
    }
}

struct HUDView: View {
    let hud: HUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%.0f fps shown · %.0f decoded · %.1f Mbit/s · %@", hud.presentedFps, hud.decodedFps, hud.mbps, hud.chroma))
            Text(String(format: "encode %.1f ms (Mac) · decode %.1f ms · keyframes %d · refine %d", hud.encodeMs, hud.decodeMs, hud.keyframes, hud.refinements))
            Text("drops: \(hud.framesLost) lost · \(hud.hostDrops) encoder · \(hud.hostSkipped) busy")
            Text("net: " + [hud.rateText.isEmpty ? nil : hud.rateText, hud.rttMs.map { String(format: "rtt %.0f ms", $0) },
                            hud.migrations > 0 ? "path changes \(hud.migrations)" : nil].compactMap { $0 }.joined(separator: " · "))
            Text(hud.latencyText)
            if let glass = hud.glassText { Text(glass) }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
    }
}
