import AppKit
import SwiftUI

/// The privacy screen (ADR-0015, docs/security.md T9): while a phone uses this Mac from elsewhere, every
/// physical screen shows a black panel saying so, instead of what the phone is doing. The phone still sees
/// the real screen: the panels are left out of the capture (`ScreenCapture.exclude`).
///
/// The panels sit at the shielding level, take no clicks or keys (`ignoresMouseEvents`, never key), and
/// close with the process, so a crash never leaves the Mac covered. A separate Clamshell display (not
/// mirroring) is never covered: it is the phone's own screen.
@MainActor
final class Curtain {
    private var windows: [NSWindow] = []
    private var info = Info(phone: "", since: .now, inputBlocked: false, attempt: false, lingering: false)
    private var skipDisplay: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?
    private var lingerTimer: Task<Void, Never>?
    private var lingerMonitor: Any?
    private var attemptReset: Task<Void, Never>?
    /// Called when the panels were rebuilt (screens added, removed or resized): exclude the new ones.
    var onWindowsChanged: (([CGWindowID]) -> Void)?

    struct Info: Equatable {
        var phone: String
        var since: Date
        var inputBlocked: Bool
        /// Someone at the Mac just tried to use it.
        var attempt: Bool
        /// The phone dropped; the panels stay a moment in case it comes back.
        var lingering: Bool
    }

    var shown: Bool { !windows.isEmpty }
    var windowIDs: [CGWindowID] { windows.map { CGWindowID($0.windowNumber) } }

    /// Puts the panels up, transparent: call `reveal()` once the capture leaves them out, so the phone never
    /// sees a black frame. Returns their window ids.
    @discardableResult
    func prepare(phone: String, skipping display: CGDirectDisplayID?) -> [CGWindowID] {
        cancelLinger()
        let keep = shown ? info.since : Date.now
        info = Info(phone: phone, since: keep, inputBlocked: info.inputBlocked, attempt: false, lingering: false)
        skipDisplay = display
        if !shown { build(alpha: 0) } else { refresh() }
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
        return windowIDs
    }

    func reveal() {
        for w in windows { w.alphaValue = 1 }
    }

    func hide() {
        cancelLinger()
        attemptReset?.cancel()
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
    }

    func setInputBlocked(_ on: Bool) {
        guard info.inputBlocked != on else { return }
        info.inputBlocked = on
        refresh()
    }

    /// Someone at the Mac pressed a key or touched the trackpad: say why nothing happens, for a few seconds.
    func localAttempt() {
        guard shown else { return }
        if !info.attempt { info.attempt = true; refresh() }
        attemptReset?.cancel()
        attemptReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.info.attempt = false
            self.refresh()
        }
    }

    /// The phone dropped: keep the screen covered for `seconds` in case it reconnects, unless someone at the
    /// Mac presses a key or clicks (then it goes at once).
    func linger(seconds: Double) {
        guard shown else { return }
        info.lingering = true
        info.inputBlocked = false
        refresh()
        lingerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        lingerTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func cancelLinger() {
        lingerTimer?.cancel()
        lingerTimer = nil
        if let m = lingerMonitor { NSEvent.removeMonitor(m) }
        lingerMonitor = nil
        if info.lingering { info.lingering = false; refresh() }
    }

    private func rebuild() {
        guard shown else { return }
        let alpha = windows.first?.alphaValue ?? 1
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
        build(alpha: alpha)
        onWindowsChanged?(windowIDs)
    }

    private func build(alpha: CGFloat) {
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            if let id, id == skipDisplay { continue }
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.backgroundColor = .black
            w.isOpaque = true
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.sharingType = .none            // older capture APIs; ScreenCaptureKit gets an explicit exclusion
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.contentView = NSHostingView(rootView: CurtainView(info: info))
            w.alphaValue = alpha
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    private func refresh() {
        for w in windows { w.contentView = NSHostingView(rootView: CurtainView(info: info)) }
    }
}

private struct CurtainView: View {
    let info: Curtain.Info

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 14) {
                Image(systemName: info.lingering ? "wifi.exclamationmark" : "lock.display")
                    .font(.system(size: 54, weight: .light))
                Text(info.lingering ? "Waiting for \(phone) to reconnect" : "In use remotely — Clamshell")
                    .font(.system(size: 30, weight: .semibold))
                Text(detail).font(.title3).multilineTextAlignment(.center)
                if info.attempt && info.inputBlocked {
                    Text("This Mac's keyboard and trackpad are turned off during the session.")
                        .font(.title3.weight(.medium)).foregroundStyle(.orange)
                }
                Text(info.lingering ? "Press any key or click to show the screen now." : "Press Esc three times to end the session.")
                    .font(.headline).foregroundStyle(.white.opacity(0.75)).padding(.top, 8)
            }
            .foregroundStyle(.white)
            .padding(40)
        }
    }

    private var phone: String { info.phone.isEmpty ? "the iPhone" : info.phone }

    private var detail: String {
        let since = info.since.formatted(date: .omitted, time: .shortened)
        return "\(phone) has been using this Mac since \(since). Its screen is hidden here."
    }
}
