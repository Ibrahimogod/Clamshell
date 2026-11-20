import SwiftUI

@main
struct ClamshellHostApp: App {
    @State private var host = HostController()

    init() { Self.logToFileIfDetached() }

    /// Launched from Finder, the Dock or as a login item, stdout goes nowhere: append it to
    /// ~/Library/Logs/Clamshell/host.log instead, so a session can still be diagnosed afterwards.
    private static func logToFileIfDetached() {
        var st = stat()
        guard fstat(STDOUT_FILENO, &st) == 0, (st.st_mode & S_IFMT) == S_IFCHR, isatty(STDOUT_FILENO) == 0 else { return }
        guard let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Clamshell", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("host.log").path
        guard freopen(path, "a", stdout) != nil else { return }
        _ = freopen(path, "a", stderr)
        setvbuf(stdout, nil, _IOLBF, 0)
        print("--- Clamshell Host started \(Date())")
    }

    var body: some Scene {
        MenuBarExtra {
            HostMenu(host: host)
        } label: {
            Image(systemName: host.isStreaming ? "laptopcomputer.and.iphone" : "laptopcomputer")
                .task { host.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

struct HostMenu: View {
    let host: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clamshell Host").font(.headline)
            Text(host.statusText).font(.callout).foregroundStyle(.secondary)
            if !host.edgeText.isEmpty { Text(host.edgeText).font(.caption).foregroundStyle(.secondary) }
            Text(host.publicAddressText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !host.publicAddress.routerStatus.isEmpty, !host.publicAddress.routerStatus.hasPrefix("Router: \(host.publicAddress.learned ?? "-")") {
                Text(host.publicAddress.routerStatus).font(.caption).foregroundStyle(.orange)
            }
            if !host.portForwarder.problem.isEmpty {
                Text("Port forwarding: " + host.portForwarder.problem).font(.caption).foregroundStyle(.orange)
            }
            Button("Home address…") { host.showHomeAddress() }
            if !host.streamDescription.isEmpty { Text(host.streamDescription).font(.caption.monospaced()) }

            if !host.screenRecordingGranted {
                Divider()
                Text("Screen Recording permission is needed to stream.").font(.callout)
                Button("Allow Screen Recording…") { host.requestScreenRecording() }
            }

            if !host.inputAllowed {
                Divider()
                Text("To use this Mac's keyboard and mouse from the phone, allow Clamshell Host in Accessibility.").font(.callout)
                Button("Allow keyboard & mouse control…") { host.requestInputAccess() }
            }
            Toggle("Show this Mac's own screen (off: a separate screen for the phone)",
                   isOn: Binding(get: { host.mirrorMainDisplay }, set: { host.mirrorMainDisplay = $0 }))
            Toggle("Sync clipboard with the phone", isOn: Binding(get: { host.clipboardSync }, set: { host.clipboardSync = $0 }))
            Toggle("Play this Mac's sound on the phone", isOn: Binding(get: { host.streamSound }, set: { host.streamSound = $0 }))
            Toggle("Accept files from the phone (to Downloads)", isOn: Binding(get: { host.acceptFiles }, set: { host.acceptFiles = $0 }))
            if host.canSendFiles {
                Button("Send Files to the iPhone…") { host.chooseFilesForPhone() }
                    .help("Files or whole folders, any size. Or in Finder: right-click › Services › Send to iPhone with Clamshell.")
            }
            if let f = host.transferFraction {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: f).progressViewStyle(.linear)
                    HStack(alignment: .top) {
                        Text(host.transferText).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel Transfers") { host.cancelTransfers() }.font(.caption)
                            .help("Stops now. What arrived so far is kept: sending the same file again picks up where it stopped.")
                    }
                }
            }
            if !host.lastFileNote.isEmpty { Text(host.lastFileNote).font(.caption).foregroundStyle(.secondary) }
            Divider()
            Picker("Hide this Mac's screen during a session", selection: Binding(get: { host.curtainMode }, set: { host.curtainMode = $0 })) {
                ForEach(HostController.CurtainMode.allCases) { Text($0.label).tag($0) }
            }
            .font(.callout)
            .help("Anyone at the Mac sees a black screen saying it's in use remotely; the phone still sees everything. The phone can change this for one session.")
            Toggle("While hidden, also turn off this Mac's keyboard and trackpad", isOn: Binding(get: { host.blockLocalInput }, set: { host.blockLocalInput = $0 }))
                .font(.callout)
                .disabled(host.curtainMode == .off)
                .help("Esc pressed three times at the Mac always ends the session and turns them back on.")
            if host.curtainShown {
                Label(host.localInputBlocked ? "Screen hidden · keyboard and trackpad off" : "Screen hidden", systemImage: "lock.display")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Keep this Mac awake while plugged in", isOn: Binding(get: { host.keepAwakeOnAC }, set: { host.keepAwakeOnAC = $0 }))
            Toggle("Open at login", isOn: Binding(get: { _ = host.loginItemTick; return host.openAtLogin }, set: { host.openAtLogin = $0 }))
                .font(.callout)

            if host.isStreaming {
                Divider()
                let s = host.stats
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    GridRow { Text("frames"); Text("\(s.framesSent) (\(s.keyframes) key, \(s.refinements) refine)") }
                    GridRow { Text("encode"); Text(String(format: "%.1f ms, last %.1f KB", s.lastEncodeMs, Double(s.lastFrameBytes) / 1024)) }
                    GridRow { Text("sent"); Text(String(format: "%.1f MB", Double(s.bytesSent) / 1e6)) }
                    GridRow { Text("dropped"); Text("\(s.encoderDrops) encoder, \(s.skippedWhileBusy) busy") }
                    if !host.rateText.isEmpty { GridRow { Text("rate"); Text(host.rateText) } }
                    GridRow { Text("mac"); Text(host.macScreenText) }
                }
                .font(.caption.monospaced())
                Toggle("Latency barcode (harness A)", isOn: Binding(get: { host.barcodeEnabled }, set: { host.barcodeEnabled = $0 }))
                    .font(.callout)
                Toggle("Flash square (glass-to-glass test)", isOn: Binding(get: { host.flashEnabled }, set: { host.flashEnabled = $0 }))
                    .font(.callout)
            }

            Divider()
            HStack {
                Image(systemName: host.micDriverInstalled ? "mic" : "mic.slash").foregroundStyle(.secondary)
                Text(host.micDriverInstalled ? "Clamshell Microphone is installed: pick it as the input in your app to use the phone's mic."
                                             : "For the phone's microphone on this Mac, install Clamshell Microphone: run tools/scripts/install-microphone.sh in Terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Text("Paired phones").font(.caption).foregroundStyle(.secondary)
            if host.devices.isEmpty { Text("None yet. Pair one at home, on this Wi-Fi.").font(.callout) }
            ForEach(host.devices) { d in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(d.name.isEmpty ? "iPhone" : d.name).font(.callout)
                        Text(d.created, format: .dateTime.day().month()).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Revoke") { Task { await host.revoke(d) } }
                            .help("Removes this phone; its session ends now and it must pair again at home.")
                    }
                    let _ = host.expiryTick
                    if let note = PhoneAppExpiry.text([UInt8](d.publicKey)) {
                        Text(note).font(.caption)
                            .foregroundStyle(PhoneAppExpiry.isUrgent([UInt8](d.publicKey)) ? Color.orange : Color.secondary)
                    }
                }
            }
            HStack {
                Button("Pair new iPhone…") { Task { await host.openPairing() } }
                    .disabled(host.devices.count >= DeviceStore.limit)
                if host.isStreaming { Button("Disconnect all") { Task { await host.disconnectAll() } } }
            }
            Toggle("Pause remote access", isOn: Binding(get: { host.paused }, set: { on in Task { await host.setPaused(on) } }))
                .font(.callout)
                .help("Ends every session and closes the internet listener until you switch it off. Pairings stay.")
            Divider()
            Button("Quit Clamshell Host") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
    }
}

extension HostController {
    var isStreaming: Bool { if case .streaming = status { true } else { false } }

    var macScreenText: String {
        switch macScreen {
        case .active: "awake"
        case .screenSaver: "screen saver running"
        case .locked: "locked"
        case .unknown: "unknown"
        }
    }

    var statusText: String {
        switch status {
        case .starting: "Starting…"
        case .waiting(let port): "Waiting for the phone (UDP \(port), Bonjour)"
        case .streaming(let peer): "Streaming to \(peer)"
        case .failed(let e): "Error: \(e)"
        }
    }
}
