import AVFoundation
import ClamshellBench
import CoreMedia
import CoreVideo
import Foundation

/// Harness B on one device (docs/video.md §2). The Mac flips a square black ↔ white on its own panel and on
/// the streamed display at the same moment (Clamshell Host › Flash square). This phone's **rear camera**
/// watches the Mac's panel at its fastest frame rate while its screen presents the stream. Both become flip
/// times on the phone clock (`CLOCK_UPTIME_RAW`), and the lag between matching flips is glass-to-glass latency.
///
/// Known biases, all small next to the result: the camera edge lands half an exposure late (≤ 2 ms at 240 fps)
/// plus rolling-shutter readout to the square's row; the phone side uses the display link's target time, not
/// the panel's pixel response; the Mac panel and the virtual display flip on their own vsyncs (≤ 8.3 ms skew).
final class CameraFlashProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    // Everything below is touched only on `queue` (AVCapture calls the delegate there), hence @unchecked.
    static let columns = 32, rows = 18
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.clamshell.flash-camera", qos: .userInteractive)
    private let onEdge: @Sendable (FlashEdge) -> Void
    private let onStatus: @Sendable (_ status: String, _ fps: Double) -> Void
    private var finder = FlashSpotFinder(cellCount: CameraFlashProbe.columns * CameraFlashProbe.rows)
    private var cell: Int?
    private var detector = FlashEdgeDetector(confirmSamples: 2)
    private var lastEdgeNs: UInt64 = 0
    private var frameTimes: [UInt64] = []
    private var lastStatusNs: UInt64 = 0
    private var status = "starting the camera"

    init(onEdge: @escaping @Sendable (FlashEdge) -> Void, onStatus: @escaping @Sendable (_ status: String, _ fps: Double) -> Void) {
        self.onEdge = onEdge
        self.onStatus = onStatus
        super.init()
    }

    func start() {
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            queue.async { [self] in
                if allowed { configureAndRun() } else { report("camera access denied (Settings › Clamshell › Camera)") }
            }
        }
    }

    func stop() {
        queue.async { [self] in session.stopRunning() }
    }

    private func report(_ s: String, fps: Double = 0) {
        status = s
        onStatus(s, fps)
    }

    private func configureAndRun() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            report("no rear camera"); return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input) else { report("camera input refused"); return }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { report("camera output refused"); return }
            session.addOutput(output)

            // The fastest format, then the smallest picture at that rate (less to scan per frame).
            func maxRate(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
            func width(_ f: AVCaptureDevice.Format) -> Int32 { CMVideoFormatDescriptionGetDimensions(f.formatDescription).width }
            let formats = device.formats.filter { width($0) >= 640 && width($0) <= 1920 }
            guard let best = formats.max(by: { (maxRate($0), -width($0)) < (maxRate($1), -width($1)) }) else {
                report("no usable camera format"); return
            }
            try device.lockForConfiguration()
            device.activeFormat = best
            let fps = Int32(min(maxRate(best), 240))
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
            device.unlockForConfiguration()
        } catch {
            report("camera setup failed: \(error.localizedDescription)"); return
        }
        session.startRunning()
        report("looking for the flash square: point the rear camera at the Mac")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Capture timestamps are on the host-time clock (mach_absolute_time), the phone clock's base.
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: session.synchronizationClock ?? CMClockGetHostTimeClock(),
                                    to: CMClockGetHostTimeClock())
        guard pts.isNumeric else { return }
        let t = PhoneClock.ns(fromMediaTime: pts.seconds)
        frameTimes.append(t)
        if frameTimes.count > 240 { frameTimes.removeFirst(frameTimes.count - 240) }

        if let cell {
            guard let level = Self.cellMeans(buffer, only: cell)?.first else { return }
            if let e = detector.add(timeNs: t, level: level) {
                lastEdgeNs = t
                onEdge(e)
            } else if t > lastEdgeNs + 2_000_000_000 {          // lost it (phone moved, square covered): search again
                self.cell = nil
                finder.reset()
                report("lost the flash square; looking again")
            }
        } else if let levels = Self.cellMeans(buffer, only: nil) {
            finder.add(levels)
            if finder.frames >= 600 {                             // ~2.5 s at 240 fps: at least 4 flips
                if let found = finder.best() {
                    cell = found
                    detector = FlashEdgeDetector(confirmSamples: 2)
                    lastEdgeNs = t
                    report("locked on the flash square (cell \(found % Self.columns),\(found / Self.columns))")
                }
                finder.reset()
            }
        }
        if t > lastStatusNs + 1_000_000_000 {
            lastStatusNs = t
            onStatus(status, fps)
        }
    }

    private var fps: Double {
        guard let first = frameTimes.first, let last = frameTimes.last, last > first else { return 0 }
        return Double(frameTimes.count - 1) / (Double(last - first) / 1e9)
    }

    /// Mean luma of every grid cell (row-major), or just of `only`, from a sparse 4×4 (search) or 8×8 (locked)
    /// sample per cell. Plane 0 of 420f is full-range luma.
    private static func cellMeans(_ buffer: CVPixelBuffer, only: Int?) -> [Double]? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let cw = w / columns, ch = h / rows
        guard cw >= 8, ch >= 8 else { return nil }
        func mean(_ c: Int, _ n: Int) -> Double {
            let x0 = (c % columns) * cw, y0 = (c / columns) * ch
            var sum = 0
            for j in 0..<n {
                let row = (y0 + (2 * j + 1) * ch / (2 * n)) * stride
                for i in 0..<n { sum += Int(bytes[row + x0 + (2 * i + 1) * cw / (2 * n)]) }
            }
            return Double(sum) / Double(n * n)
        }
        if let only { return only < columns * rows ? [mean(only, 8)] : nil }
        return (0..<(columns * rows)).map { mean($0, 4) }
    }
}

/// The phone side: the streamed copy of the square sits at fixed pixels on the 2× virtual display,
/// (W−352…W−32, 32…352) (`FlashOverlay` on the Mac). This reads the mean luma of its centre 16×16.
enum StreamFlashReader {
    static let insetFromRight = 192, fromTop = 192, half = 8

    static func level(_ buffer: CVPixelBuffer) -> Double? {
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let cx = w - insetFromRight, cy = fromTop
        guard cx - half >= 0, cy + half <= h, CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        for y in (cy - half)..<(cy + half) {
            for x in (cx - half)..<(cx + half) { sum += Int(bytes[y * stride + x]) }
        }
        return Double(sum) / Double(4 * half * half)
    }
}
