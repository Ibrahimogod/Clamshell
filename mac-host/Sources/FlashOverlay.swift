import AppKit
import QuartzCore

/// Harness B (docs/video.md §2): a square that flips black ↔ white on **both** the Mac's own screen and
/// the virtual display, in the same main-thread step. Either the Duo's own rear camera watches the Mac's
/// square while its screen shows the stream (one device, no filming: the iOS client's "glass-to-glass
/// camera test"), or a second phone films both screens at 240 fps for `tools/bench/harness_b.py`.
///
/// The two screens scan out on their own vsyncs, so the Mac-side reference carries up to one refresh
/// (8.3 ms at 120 Hz) of skew. Flips are every 400–500 ms (random) so they never alias with the camera.
///
/// ProMotion drops a still panel's refresh rate, so a flip after 400 ms of nothing changing reached the
/// Mac's own glass after a variable delay. That made the camera's reference late and jittery (measured lags of
/// 4–330 ms). A 2 pt dot in the local square's corner changes on every display-link tick, which keeps
/// that panel at its full rate for the whole test.
@MainActor
final class FlashOverlay {
    /// On the virtual display: 160 pt, 16 pt from the top-right corner of the *full* frame (above the menu bar),
    /// so on the 2× display it always covers pixels (W−352…W−32, 32…352). The phone samples the centre,
    /// (W−192, 192), from each decoded picture (`StreamFlashReader` in the iOS client).
    static let virtualSide: CGFloat = 160
    /// On the Mac's own panel: bigger, so the phone's rear camera finds it easily from 20–40 cm.
    static let localSide: CGFloat = 260
    private var windows: [NSWindow] = []
    private var task: Task<Void, Never>?
    private var keepAwake: RefreshKeeper?

    init?(virtualDisplayID: CGDirectDisplayID) {
        let screens = NSScreen.screens
        guard let virtual = screens.first(where: { Self.id(of: $0) == virtualDisplayID }),
              let local = screens.first(where: { Self.id(of: $0) != virtualDisplayID && $0.frame.origin == .zero })
                ?? screens.first(where: { Self.id(of: $0) != virtualDisplayID }) else { return nil }
        windows = [Self.makeWindow(on: virtual, side: Self.virtualSide, area: virtual.frame),
                   Self.makeWindow(on: local, side: Self.localSide, area: local.visibleFrame)]
        if let view = windows.last?.contentView { keepAwake = RefreshKeeper(view: view) }
        task = Task { @MainActor [weak self] in
            var white = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 400...500)))
                white.toggle()
                self?.set(white)
            }
        }
    }

    func close() {
        keepAwake?.stop()
        keepAwake = nil
        task?.cancel()
        task = nil
        windows.forEach { $0.close() }
        windows = []
    }

    private func set(_ white: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for w in windows { w.contentView?.layer?.backgroundColor = (white ? NSColor.white : NSColor.black).cgColor }
        CATransaction.commit()
        CATransaction.flush()
    }

    private static func id(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Top-right corner of `area`, clear of the harness A patch (top-left).
    private static func makeWindow(on screen: NSScreen, side: CGFloat, area f: NSRect) -> NSWindow {
        let frame = NSRect(x: f.maxX - side - 16, y: f.maxY - side - 16, width: side, height: side)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hasShadow = false
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = view
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return window
    }
}

/// Changes a 2 pt dot every refresh so ProMotion keeps the panel at its full rate (see `FlashOverlay`).
@MainActor
private final class RefreshKeeper: NSObject {
    private let dot = CALayer()
    private var link: CADisplayLink?
    private var odd = false

    init(view: NSView) {
        super.init()
        dot.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        view.layer?.addSublayer(dot)
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func tick(_ link: CADisplayLink) {
        odd.toggle()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = CGColor(gray: odd ? 0.45 : 0.55, alpha: 1)
        CATransaction.commit()
    }
}
