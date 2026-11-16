#if os(macOS)
import CoreGraphics
import CVirtualDisplay
import Foundation

/// A virtual monitor sized to the phone (ADR-0006). The Mac sees a real display at the phone's
/// resolution and refresh rate, so text renders 1:1 for the phone panel; the built-in screen is
/// untouched. The display exists only while this object lives.
public final class VirtualDisplay: @unchecked Sendable {
    /// "CL": tells our display apart from real ones.
    public static let vendorID: UInt32 = 0x434C

    public enum DisplayError: Error, Equatable, Sendable {
        case unavailable          // private classes missing on this macOS
        case creationFailed
        case settingsRejected
        case didNotAppear
    }

    public static var isAvailable: Bool { CVDAvailable() }

    // Kept alive deliberately: releasing it removes the display. Only touched in init/deinit.
    private let display: CGVirtualDisplay
    public let displayID: CGDirectDisplayID
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshHz: Double
    public let hiDPI: Bool

    /// - Parameters:
    ///   - pixelWidth/pixelHeight: backing pixels (e.g. 1878×1334 for the Duo's laptop posture).
    ///   - hiDPI: when true the Mac lays out at half the pixels in points (crisp 2× text).
    public init(name: String, pixelWidth: Int, pixelHeight: Int, refreshHz: Double, hiDPI: Bool = true,
                physicalWidthMM: Double = 150, queue: DispatchQueue = .main) throws {
        guard Self.isAvailable else { throw DisplayError.unavailable }
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = queue
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(pixelWidth)
        descriptor.maxPixelsHigh = UInt32(pixelHeight)
        let aspect = Double(pixelHeight) / Double(pixelWidth)
        descriptor.sizeInMillimeters = CGSize(width: physicalWidthMM, height: physicalWidthMM * aspect)
        descriptor.vendorID = Self.vendorID
        descriptor.productID = 0x4D31          // "M1"
        descriptor.serialNum = UInt32(pixelWidth << 16 | pixelHeight)
        descriptor.terminationHandler = { _, _ in }

        guard let d = CGVirtualDisplay(descriptor: descriptor) else { throw DisplayError.creationFailed }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        // With hiDPI set, each base mode W×H is also offered as W×H points backed by 2W×2H pixels, as long as
        // that fits in maxPixels. So the base mode is the point size, and `selectMode` picks its 2× variant
        // (the window server otherwise starts the display in a 1× mode). Measured on macOS 27.2 (probe log).
        let scale = hiDPI ? 2 : 1
        settings.modes = [CGVirtualDisplayMode(width: UInt32(pixelWidth / scale), height: UInt32(pixelHeight / scale), refreshRate: refreshHz)]
        guard d.apply(settings) else { throw DisplayError.settingsRejected }
        display = d
        displayID = d.displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshHz = refreshHz
        self.hiDPI = hiDPI
        guard displayID != 0 else { throw DisplayError.didNotAppear }
    }

    /// Waits until the window server lists the display (usually < 200 ms).
    public func waitUntilOnline(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Self.onlineDisplays().contains(displayID) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Every mode the window server offers for this display, HiDPI duplicates included.
    public func availableModes() -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
    }

    /// Switches to the mode with these backing pixels and, for HiDPI, half as many points. Session-scoped:
    /// it is not persisted and disappears with the display.
    @discardableResult
    public func selectMode() -> Bool {
        let scale = hiDPI ? 2 : 1
        guard let mode = availableModes().first(where: {
            $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight && $0.width * scale == pixelWidth
                && abs($0.refreshRate - refreshHz) < 0.5
        }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    /// The mode the window server actually applied.
    public var currentMode: (pointsWide: Int, pointsHigh: Int, pixelsWide: Int, pixelsHigh: Int, refresh: Double)? {
        guard let m = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return (m.width, m.height, m.pixelWidth, m.pixelHeight, m.refreshRate)
    }

    public static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
#endif
