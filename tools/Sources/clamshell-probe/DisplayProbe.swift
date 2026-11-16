import AppKit
import ClamshellVirtualDisplay
import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit
import Synchronization

/// Probe 2: private CGVirtualDisplay at the phone's resolution and 120 Hz, then ScreenCaptureKit
/// capture of that display with an animated window on it. Measures delivered fps, frame interval,
/// idle (damage-skip) frames and capture latency (display time → sample arrival).
@MainActor
enum DisplayProbe {
    static func run(_ args: Args) async throws {
        let w = args.int("width", 1878), h = args.int("height", 1334), hz = args.double("hz", 120)
        let seconds = args.double("seconds", 5)
        print("# clamshell-probe display — \(w)×\(h) px, HiDPI, \(Int(hz)) Hz")
        print("CGVirtualDisplay classes present: \(VirtualDisplay.isAvailable)")
        let before = Set(VirtualDisplay.onlineDisplays())
        let created = ContinuousClock.now
        let display = try VirtualDisplay(name: "Clamshell Probe", pixelWidth: w, pixelHeight: h, refreshHz: hz)
        let online = await display.waitUntilOnline()
        print("virtual display id \(display.displayID): online=\(online) after \(fmt(ms(ContinuousClock.now - created), 0)) ms (was listed before: \(before.contains(display.displayID)))")
        let modes = display.availableModes()
        print("offered modes (\(modes.count)): " + modes.map { "\($0.width)×\($0.height)pt/\($0.pixelWidth)×\($0.pixelHeight)px@\(Int($0.refreshRate))" }.joined(separator: ", "))
        print("select HiDPI mode: \(display.selectMode() ? "OK" : "FAILED")")
        try await Task.sleep(for: .milliseconds(300))
        if let m = display.currentMode {
            print("applied mode: \(m.pointsWide)×\(m.pointsHigh) pt, \(m.pixelsWide)×\(m.pixelsHigh) px, \(m.refresh) Hz")
            let ok = m.pixelsWide == w && m.pixelsHigh == h && abs(m.refresh - hz) < 0.5
            print("mode matches request: \(ok ? "YES" : "NO")")
        } else {
            print("applied mode: none reported")
        }
        try await Task.sleep(for: .milliseconds(300))      // let AppKit learn about the screen
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }) else {
            print("NSScreen for the virtual display: not found")
            return
        }
        print("NSScreen: \(screen.frame.size.width)×\(screen.frame.size.height) pt, backingScaleFactor \(screen.backingScaleFactor), maximumFramesPerSecond \(screen.maximumFramesPerSecond)")

        let window = AnimatedWindow(screen: screen)
        window.orderFrontRegardless()

        guard CGPreflightScreenCaptureAccess() else {
            print("Screen Recording permission: NOT GRANTED for this process (\(ProcessInfo.processInfo.processName)).")
            print("→ System Settings › Privacy & Security › Screen & System Audio Recording: enable the terminal app that runs the probe, then re-run.")
            if args.flag("request") { _ = CGRequestScreenCaptureAccess() }
            try await Task.sleep(for: .seconds(1))
            print("animation ticks on the virtual screen in 1 s (display link): \(window.view.ticks)")
            return
        }
        print("Screen Recording permission: granted")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else {
            print("ScreenCaptureKit does not list the virtual display")
            return
        }
        for (label, format) in [("420v", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), ("BGRA", kCVPixelFormatType_32BGRA)] {
            let r = try await capture(scDisplay, w: w, h: h, hz: hz, format: format, seconds: seconds, view: window.view)
            print("\n## SCK capture \(label), \(seconds) s")
            print(r)
        }
        // Idle check: stop the animation and count idle vs complete frames (damage skip).
        window.view.animating = false
        let idle = try await capture(scDisplay, w: w, h: h, hz: hz, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, seconds: 2, view: window.view)
        print("\n## SCK capture with a static screen, 2 s")
        print(idle)
        window.close()
    }

    static func capture(_ display: SCDisplay, w: Int, h: Int, hz: Double, format: OSType, seconds: Double, view: AnimatedView) async throws -> String {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(hz))
        cfg.pixelFormat = format
        cfg.queueDepth = 4
        cfg.showsCursor = true
        cfg.colorSpaceName = CGColorSpace.sRGB
        let sink = FrameSink()
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "probe.sck", qos: .userInteractive))
        let ticks0 = view.ticks
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        let ticks = view.ticks - ticks0
        return sink.report(seconds: seconds, appTicks: ticks, expect: (w, h))
    }
}

/// Counts SCK frames. Called on the capture queue; state behind a Mutex.
final class FrameSink: NSObject, SCStreamOutput, Sendable {
    struct State {
        var complete = 0, idle = 0, other = 0
        var lastArrival: UInt64?
        var intervals: [Double] = []
        var latencies: [Double] = []
        var dirtyFractions: [Double] = []
        var size: (Int, Int)?
    }
    let state = Mutex(State())
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        let now = mach_absolute_time()
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        let displayTime = info[.displayTime] as? UInt64
        let dirty = (info[.dirtyRects] as? [NSDictionary])?.compactMap { CGRect(dictionaryRepresentation: $0) } ?? []
        let image = CMSampleBufferGetImageBuffer(sample)
        state.withLock { s in
            switch status {
            case .complete:
                s.complete += 1
                if let last = s.lastArrival { s.intervals.append(Double(now - last) * Self.timebase / 1e6) }
                s.lastArrival = now
                if let d = displayTime, now > d { s.latencies.append(Double(now - d) * Self.timebase / 1e6) }
                if let image { s.size = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)) }
                if let image {
                    let area = dirty.reduce(0.0) { $0 + $1.width * $1.height }
                    s.dirtyFractions.append(area / Double(CVPixelBufferGetWidth(image) * CVPixelBufferGetHeight(image)))
                }
            case .idle: s.idle += 1
            default: s.other += 1
            }
        }
    }

    func report(seconds: Double, appTicks: Int, expect: (Int, Int)) -> String {
        state.withLock { s in
            let i = stats(s.intervals), l = stats(s.latencies), d = stats(s.dirtyFractions.map { $0 * 100 })
            return """
            delivered complete frames: \(s.complete) → \(fmt(Double(s.complete) / seconds, 1)) fps (app drew \(fmt(Double(appTicks) / seconds, 1)) fps); idle: \(s.idle), other: \(s.other)
            frame size: \(s.size.map { "\($0.0)×\($0.1)" } ?? "n/a") (requested \(expect.0)×\(expect.1))
            arrival interval ms: p50 \(fmt(i.p50)) · p95 \(fmt(i.p95)) · max \(fmt(i.max))
            capture latency (displayTime → handler) ms: p50 \(fmt(l.p50)) · p95 \(fmt(l.p95)) · max \(fmt(l.max))
            dirty area %: p50 \(fmt(d.p50, 1)) · p95 \(fmt(d.p95, 1))
            """
        }
    }
}

/// Borderless window filling the virtual screen; redraws every display-link tick (small moving block
/// plus a frame counter) so SCK has real damage at the screen's refresh rate.
@MainActor
final class AnimatedWindow: NSWindow {
    let view: AnimatedView

    init(screen: NSScreen) {
        view = AnimatedView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        contentView = view
        setFrame(screen.frame, display: true)
        view.start()
    }
}

@MainActor
final class AnimatedView: NSView {
    private(set) var ticks = 0
    var animating = true
    private var link: CADisplayLink?

    func start() {
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc func tick(_ link: CADisplayLink) {
        guard animating else { return }
        ticks += 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        bounds.fill()
        let x = CGFloat(ticks * 6 % Int(max(bounds.width - 80, 1)))
        NSColor.systemPink.setFill()
        NSRect(x: x, y: bounds.midY - 40, width: 80, height: 80).fill()
        let text = "frame \(ticks)" as NSString
        text.draw(at: NSPoint(x: 20, y: 20), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular),
                                                              .foregroundColor: NSColor.white])
    }
}
