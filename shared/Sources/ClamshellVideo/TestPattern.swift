import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// Synthetic "code editor" frames for probes and tests: small anti-aliased text, coloured syntax,
/// 1-px lines. These are the worst case for 4:2:0 chroma (coloured text on dark background).
public enum TestPattern {
    public static let lines = [
        "func handle(_ packet: [UInt8]) throws -> Session {   // ⌘B builds, ⌘R runs",
        "    guard let header = Header(packet), header.version == 1 else { throw .malformed }",
        "    let counter = try reader.u64()  /* replay window: 2048 */",
        "    return try session.open(packet, now: .now)   // 0x04 | idx | ctr | AEAD",
        "struct Pixel { var r, g, b: UInt8 }  let red = 0xFF3B30, blue = 0x0A84FF, green = 0x30D158",
        "il1| O0o 8B rn m cl d ,.;: ''\"\" ~-_=+ {}[]() <> @#$%^&* — the quick brown fox jumps",
    ]

    /// Renders the pattern into a new BGRA pixel buffer. `phase` scrolls the text (simulates motion);
    /// `cursorOn` toggles a caret (simulates a tiny damaged region).
    public static func pixelBuffer(width: Int, height: Int, phase: Int = 0, cursorOn: Bool = true, pointSize: CGFloat = 22) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        draw(in: ctx, width: width, height: height, phase: phase, cursorOn: cursorOn, pointSize: pointSize)
        return pb
    }

    public static func draw(in ctx: CGContext, width: Int, height: Int, phase: Int, cursorOn: Bool, pointSize: CGFloat) {
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, pointSize, nil)
        let colors = [CGColor(srgbRed: 0.99, green: 0.37, blue: 0.53, alpha: 1), CGColor(srgbRed: 0.40, green: 0.85, blue: 0.94, alpha: 1),
                      CGColor(srgbRed: 0.65, green: 0.89, blue: 0.18, alpha: 1), CGColor(srgbRed: 0.90, green: 0.86, blue: 0.45, alpha: 1),
                      CGColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1)]
        let lineHeight = pointSize * 1.45
        let rows = Int(CGFloat(height) / lineHeight)
        for row in 0..<rows {
            let text = lines[(row + phase) % lines.count]
            let attr = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): colors[(row + phase) % colors.count],
            ])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 24, y: CGFloat(height) - CGFloat(row + 1) * lineHeight)
            CTLineDraw(line, ctx)
        }
        // 1-px grid lines (sharp-edge test).
        ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.35, blue: 0.40, alpha: 1))
        for x in stride(from: 0, to: width, by: 200) { ctx.fill(CGRect(x: x, y: 0, width: 1, height: height)) }
        if cursorOn {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 24 + 40 * 13, y: Int(CGFloat(height) - lineHeight * 3), width: 2, height: Int(pointSize)))
        }
    }
}

/// Image quality helpers for probes and tests.
public enum PixelCompare {
    /// PSNR of the luma (BT.709) of two BGRA buffers of equal size.
    public static func lumaPSNR(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(a) == kCVPixelFormatType_32BGRA, CVPixelBufferGetPixelFormatType(b) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b) else { return nil }
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        guard let pa = CVPixelBufferGetBaseAddress(a), let pbase = CVPixelBufferGetBaseAddress(b) else { return nil }
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
        var sse = 0.0
        for y in 0..<h {
            let rowA = pa.advanced(by: y * ra).assumingMemoryBound(to: UInt8.self)
            let rowB = pbase.advanced(by: y * rb).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let i = x * 4
                let ya = 0.0722 * Double(rowA[i]) + 0.7152 * Double(rowA[i + 1]) + 0.2126 * Double(rowA[i + 2])
                let yb = 0.0722 * Double(rowB[i]) + 0.7152 * Double(rowB[i + 1]) + 0.2126 * Double(rowB[i + 2])
                sse += (ya - yb) * (ya - yb)
            }
        }
        let mse = sse / Double(w * h)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// Mean absolute chroma error proxy: average |ΔR−ΔG| + |ΔB−ΔG| (colour fringing on text).
    public static func colorFringe(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b) else { return nil }
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        guard let pa = CVPixelBufferGetBaseAddress(a), let pbase = CVPixelBufferGetBaseAddress(b) else { return nil }
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
        var total = 0.0
        for y in 0..<h {
            let rowA = pa.advanced(by: y * ra).assumingMemoryBound(to: UInt8.self)
            let rowB = pbase.advanced(by: y * rb).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let i = x * 4
                let dB = Double(rowA[i]) - Double(rowB[i]), dG = Double(rowA[i + 1]) - Double(rowB[i + 1]), dR = Double(rowA[i + 2]) - Double(rowB[i + 2])
                total += abs(dR - dG) + abs(dB - dG)
            }
        }
        return total / Double(w * h)
    }
}
