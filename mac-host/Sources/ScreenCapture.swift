import ClamshellStream
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit capture of one display (the virtual one) at its refresh rate (ADR-0006).
/// Only `.complete` frames carry pixels; `damaged` is false when SCK reports no dirty rects. Idle
/// samples are not forwarded: the pipeline's own tick drives refinement on a still screen.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias Handler = @Sendable (_ frame: SharedPixelBuffer, _ captureNs: UInt64, _ damaged: Bool) -> Void

    private let queue = DispatchQueue(label: "clamshell.capture", qos: .userInteractive)
    private let handler: Handler
    /// Diagnostics (queue-only): samples per SCFrameStatus raw value, and complete frames with dirty rects.
    private var statusCounts: [Int: Int] = [:]
    private var damagedCount = 0
    private var lastReport = ContinuousClock.now
    private var stream: SCStream?
    private(set) var lastError: String?

    init(handler: @escaping Handler) { self.handler = handler }

    /// Waits (up to `timeout`) for SCK to list the display, then starts capturing.
    /// With `windowID` (1.8), only that window, wherever it is (`desktopIndependentWindow`).
    func start(displayID: CGDirectDisplayID, windowID: CGWindowID? = nil, width: Int, height: Int, fps: Int, showsCursor: Bool = true,
               pixelFormat: OSType, timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now + timeout
        var filter: SCContentFilter?
        while filter == nil {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let windowID {
                guard let w = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.windowNotListed }
                filter = SCContentFilter(desktopIndependentWindow: w)
            } else if let display = content.displays.first(where: { $0.displayID == displayID }) {
                filter = SCContentFilter(display: display, excludingWindows: [])
            } else {
                guard ContinuousClock.now < deadline else { throw CaptureError.displayNotListed }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let filter else { throw CaptureError.displayNotListed }
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = pixelFormat
        cfg.queueDepth = 6                       // the pipeline holds up to 2 (last + pending); never builds a backlog
        cfg.showsCursor = showsCursor            // false when the phone draws the cursor itself (ADR-0009)
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let raw = info[.status] as? Int else { return }
        statusCounts[raw, default: 0] += 1
        if ProcessInfo.processInfo.environment["CLAMSHELL_CAPTURE_STATS"] == "1", ContinuousClock.now - lastReport > .seconds(2) {
            print("\(Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())) capture/2s: status \(statusCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) · damaged \(damagedCount)")
            statusCounts = [:]
            damagedCount = 0
            lastReport = .now
        }
        guard SCFrameStatus(rawValue: raw) == .complete, let image = CMSampleBufferGetImageBuffer(sample) else { return }
        let dirty = info[.dirtyRects] as? [NSDictionary]
        let damaged = dirty.map { !$0.isEmpty } ?? true
        if damaged { damagedCount += 1 }
        let captureNs = (info[.displayTime] as? UInt64).map(HostClock.ns(fromMachTime:)) ?? HostClock.nowNs()
        handler(SharedPixelBuffer(image), captureNs, damaged)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lastError = "\(error.localizedDescription)"
    }

    enum CaptureError: Error, CustomStringConvertible {
        case displayNotListed, windowNotListed
        var description: String {
            switch self {
            case .displayNotListed: "ScreenCaptureKit does not list the virtual display"
            case .windowNotListed: "ScreenCaptureKit does not list the window (closed, or on another Space)"
            }
        }
    }
}
