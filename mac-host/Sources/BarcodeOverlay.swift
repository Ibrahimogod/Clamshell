import AppKit
import ClamshellBench
import QuartzCore

/// Harness A (docs/video.md §2): an 8×8 cell patch in the top-left corner of the virtual display,
/// redrawn every display refresh with a frame counter and the Mac's monotonic time. The phone reads it
/// back from each decoded picture. Cells are 4 pt (8 px on the 2× display), so 4:2:0 chroma and
/// compression can't flip a cell.
@MainActor
final class BarcodeOverlay {
    static let cellPoints: CGFloat = 4
    private let window: NSWindow
    private let view: BarcodeView

    init?(displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return nil }
        let side = Self.cellPoints * CGFloat(BarcodePatch.cells)
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - side, width: side, height: side)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hasShadow = false
        view = BarcodeView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        view.start()
    }

    func close() {
        view.stop()
        window.close()
    }
}

@MainActor
final class BarcodeView: NSView {
    private var link: CADisplayLink?
    private var sequence: UInt32 = 0
    private var cells: [Bool] = Array(repeating: false, count: BarcodePatch.bitCount)

    func start() {
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() { link?.invalidate(); link = nil }

    private var ticksSinceReport = 0
    private var lastReport = ContinuousClock.now

    @objc private func tick(_ link: CADisplayLink) {
        ticksSinceReport += 1
        if ProcessInfo.processInfo.environment["CLAMSHELL_CAPTURE_STATS"] == "1", ContinuousClock.now - lastReport > .seconds(2) {
            print("barcode/2s: \(ticksSinceReport) ticks · link duration \(String(format: "%.2f", link.duration * 1000)) ms")
            ticksSinceReport = 0
            lastReport = .now
        }
        sequence &+= 1
        let micros = UInt32(truncatingIfNeeded: HostClock.nowNs() / 1000)
        cells = BarcodePatch.encode(.init(sequence: sequence, timeMicros: micros))
        // Draw and commit in this tick rather than waiting for AppKit's next display pass, so the patch
        // changes on the frame the time in it was read. (Not the cause of the ~30 frames/s unattended capture.)
        display()
        CATransaction.flush()
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = BarcodeOverlay.cellPoints, n = BarcodePatch.cells
        for (i, white) in cells.enumerated() {
            (white ? NSColor.white : NSColor.black).setFill()
            // Row-major from the top-left (AppKit's origin is bottom-left).
            NSRect(x: CGFloat(i % n) * c, y: bounds.height - CGFloat(i / n + 1) * c, width: c, height: c).fill()
        }
    }
}
