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
            if !host.lastFileNote.isEmpty { Text(host.lastFileNote).font(.caption).foregroundStyle(.secondary) }
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
            Text("Paired phones").font(.caption).foregroundStyle(.secondary)
            if host.devices.isEmpty { Text("None yet. Pair one at home, on this Wi-Fi.").font(.callout) }
            ForEach(host.devices) { d in
                HStack {
                    Text(d.name.isEmpty ? "iPhone" : d.name).font(.callout)
                    Text(d.created, format: .dateTime.day().month()).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revoke") { Task { await host.revoke(d) } }
                        .help("Removes this phone; its session ends now and it must pair again at home.")
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
