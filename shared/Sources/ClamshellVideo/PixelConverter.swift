import CoreVideo
import Foundation
import VideoToolbox

/// GPU pixel-format conversion (e.g. BGRA → 4:4:4 YCbCr for HEVC_Main444, which silently encodes 4:2:0
/// when fed BGRA). Converted buffers come from a pool sized to the input. Not thread-safe: one owner.
public final class PixelConverter {
    private let session: VTPixelTransferSession
    private var pool: (CVPixelBufferPool, OSType, Int, Int)?

    public init() throws {
        var s: VTPixelTransferSession?
        try check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s), "VTPixelTransferSessionCreate")
        guard let s else { throw VideoError.status("VTPixelTransferSessionCreate", -1) }
        session = s
    }

    deinit { VTPixelTransferSessionInvalidate(session) }

    public func convert(_ src: CVPixelBuffer, to format: OSType) throws -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        if pool.map({ $0.1 != format || $0.2 != w || $0.3 != h }) ?? true {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: format, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
            var p: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p) == kCVReturnSuccess, let p else {
                throw VideoError.status("CVPixelBufferPoolCreate", -1)
            }
            pool = (p, format, w, h)
        }
        guard let pool else { throw VideoError.status("CVPixelBufferPoolCreate", -1) }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool.0, &dst) == kCVReturnSuccess, let dst else {
            throw VideoError.status("CVPixelBufferPoolCreatePixelBuffer", -1)
        }
        try check(VTPixelTransferSessionTransferImage(session, from: src, to: dst), "VTPixelTransferSessionTransferImage")
        return dst
    }
}
