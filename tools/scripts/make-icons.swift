// Draws Clamshell's app icons (vector, CoreGraphics) and writes the asset catalogs both apps build from:
//   ios-client/Resources/Assets.xcassets/AppIcon.appiconset   (one full-bleed 1024 px square; iOS masks it)
//   mac-host/Resources/Assets.xcassets/AppIcon.appiconset     (16–1024 px, macOS rounded body with margin)
//   docs/images/icon.png                                      (for the README)
// Run from the repo root:  swift tools/scripts/make-icons.swift
// The art: a half-open device in laptop posture, a warm picture on its screen with a window and a pointer,
// an ember hinge, and keys and a trackpad below. Colours are the deck's "Shell & Ember" palette.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil) {
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.restoreGState()
}

/// The art in a 1024 × 1024 space, y pointing down. `background` is the tile behind the device.
func drawArt(_ ctx: CGContext, background: CGPath) {
    // Tile.
    fillGradient(ctx, background, [color(0x26282E), color(0x0D0E11)], from: CGPoint(x: 512, y: 0), to: CGPoint(x: 512, y: 1024))
    ctx.saveGState()
    ctx.addPath(background)
    ctx.clip()
    if let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                             colors: [color(0xFF7A33, 0.22), color(0xFF7A33, 0)] as CFArray, locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 530), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 530), endRadius: 470, options: [])
    }
    ctx.restoreGState()

    // The device, a little larger than its drawn coordinates so it fills the tile.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 1.16, y: 1.16)
    ctx.translateBy(x: -512, y: -512)
    defer { ctx.restoreGState() }

    // Upper half: the Mac's screen.
    let upper = CGRect(x: 232, y: 196, width: 560, height: 324)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: color(0x000000, 0.55))
    ctx.addPath(rounded(upper, 44)); ctx.setFillColor(color(0x35373E)); ctx.fillPath()
    ctx.restoreGState()
    let screen = upper.insetBy(dx: 18, dy: 18)
    fillGradient(ctx, rounded(screen, 28), [color(0xFF9A4A), color(0xF0603A), color(0xA8336E)],
                 from: CGPoint(x: screen.minX, y: screen.minY), to: CGPoint(x: screen.maxX, y: screen.maxY))
    // A window on the screen.
    let window = CGRect(x: 292, y: 252, width: 300, height: 196)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: color(0x3A0E1E, 0.45))
    ctx.addPath(rounded(window, 16)); ctx.setFillColor(color(0xFFF6EE, 0.95)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(rounded(window, 16)); ctx.clip()
    ctx.setFillColor(color(0xF1E2D6)); ctx.fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: 36))
    ctx.restoreGState()
    for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        ctx.setFillColor(color(UInt32(c))); ctx.fillEllipse(in: CGRect(x: window.minX + 18 + CGFloat(i) * 24, y: window.minY + 11, width: 14, height: 14))
    }
    for (i, w) in [220.0, 180, 236, 150].enumerated() {
        ctx.addPath(rounded(CGRect(x: window.minX + 24, y: window.minY + 60 + CGFloat(i) * 30, width: w, height: 12), 6))
        ctx.setFillColor(color(0xC9B4A6, 0.9)); ctx.fillPath()
    }
    // The pointer.
    let tip = CGPoint(x: 640, y: 372)
    let arrow = CGMutablePath()
    for (k, p) in [(0.0, 0.0), (0, 92), (24, 70), (40, 106), (58, 98), (42, 63), (74, 63)].enumerated() {
        let pt = CGPoint(x: tip.x + p.0, y: tip.y + p.1)
        if k == 0 { arrow.move(to: pt) } else { arrow.addLine(to: pt) }
    }
    arrow.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 12, color: color(0x000000, 0.35))
    ctx.addPath(arrow); ctx.setFillColor(color(0x111215)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(arrow); ctx.setStrokeColor(color(0xFFFFFF)); ctx.setLineWidth(9); ctx.setLineJoin(.round); ctx.strokePath()

    // The hinge, glowing.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26, color: color(0xFF7A33, 1))
    ctx.addPath(rounded(CGRect(x: 252, y: 524, width: 520, height: 12), 6)); ctx.setFillColor(color(0xFF8A45)); ctx.fillPath()
    ctx.addPath(rounded(CGRect(x: 252, y: 524, width: 520, height: 12), 6)); ctx.fillPath()
    ctx.restoreGState()

    // Lower half: keys and trackpad.
    let lower = CGRect(x: 232, y: 540, width: 560, height: 288)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 44, color: color(0x000000, 0.6))
    ctx.addPath(rounded(lower, 44)); ctx.setFillColor(color(0x2B2D33)); ctx.fillPath()
    ctx.restoreGState()
    fillGradient(ctx, rounded(lower, 44), [color(0x484B54), color(0x34363D)], from: CGPoint(x: 512, y: lower.minY), to: CGPoint(x: 512, y: lower.maxY))
    let pitch: CGFloat = 500 / 11, rowPitch: CGFloat = 31, keyH: CGFloat = 23
    for row in 0..<4 {
        let y = 566 + CGFloat(row) * rowPitch
        var cols: [(start: CGFloat, span: CGFloat)] = (0..<11).map { (CGFloat($0), 1) }
        if row == 3 { cols = [(0, 1), (1, 1), (2, 1), (3, 5), (8, 1), (9, 1), (10, 1)] }
        for c in cols {
            let r = CGRect(x: 262 + c.start * pitch + 4, y: y, width: c.span * pitch - 8, height: keyH)
            ctx.addPath(rounded(r, 6)); ctx.setFillColor(color(0x6A6E79)); ctx.fillPath()
        }
    }
    let pad = CGRect(x: 402, y: 708, width: 220, height: 96)
    ctx.addPath(rounded(pad, 16)); ctx.setFillColor(color(0x575B65)); ctx.fillPath()
    ctx.addPath(rounded(pad, 16)); ctx.setStrokeColor(color(0xFFFFFF, 0.14)); ctx.setLineWidth(2); ctx.strokePath()
}

enum Style { case ios, mac }

func render(_ px: Int, _ style: Style) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: style == .ios ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let s = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)                     // 1024-point space, y down
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    switch style {
    case .ios:
        drawArt(ctx, background: CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), transform: nil))
    case .mac:
        // macOS icon grid: an 824-point rounded body centred on the 1024 canvas, with a soft shadow.
        let body = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
        ctx.addPath(body); ctx.setFillColor(color(0x15161A)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 512)
        ctx.scaleBy(x: 824 / 1024, y: 824 / 1024)
        ctx.translateBy(x: -512, y: -512)
        drawArt(ctx, background: rounded(CGRect(x: 0, y: 0, width: 1024, height: 1024), 230))
        ctx.restoreGState()
    }
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

func writeJSON(_ object: Any, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

let info = ["author": "xcode", "version": 1] as [String: Any]
do {
    // iPhone: one universal 1024 px square.
    let ios = root.appendingPathComponent("ios-client/Resources/Assets.xcassets")
    try writeJSON(["info": info], ios.appendingPathComponent("Contents.json"))
    if let img = render(1024, .ios) { try writePNG(img, ios.appendingPathComponent("AppIcon.appiconset/icon-1024.png")) }
    try writeJSON(["images": [["filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]], "info": info],
                  ios.appendingPathComponent("AppIcon.appiconset/Contents.json"))

    // Mac: every size macOS asks for.
    let mac = root.appendingPathComponent("mac-host/Resources/Assets.xcassets")
    try writeJSON(["info": info], mac.appendingPathComponent("Contents.json"))
    var images: [[String: String]] = []
    for pt in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon-\(pt)@\(scale)x.png"
            if let img = render(pt * scale, .mac) { try writePNG(img, mac.appendingPathComponent("AppIcon.appiconset/\(name)")) }
            images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
        }
    }
    try writeJSON(["images": images, "info": info], mac.appendingPathComponent("AppIcon.appiconset/Contents.json"))

    // README.
    if let img = render(256, .mac) { try writePNG(img, root.appendingPathComponent("docs/images/icon.png")) }
    print("icons written: ios-client/Resources/Assets.xcassets, mac-host/Resources/Assets.xcassets, docs/images/icon.png")
} catch {
    print("make-icons failed: \(error)")
    exit(1)
}
