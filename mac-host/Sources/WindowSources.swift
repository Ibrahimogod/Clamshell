import AppKit
import ApplicationServices
import ClamshellWire
import CoreGraphics
import ScreenCaptureKit

/// The Mac's windows the phone can stream on their own (1.1, protocol 1.8): ordinary app windows on screen,
/// front to back, not this app's.
enum WindowSources {
    /// For `WindowList`: front to back (the window server's order), at most `WindowList.maxWindows`.
    static func list() async -> [StreamableWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        let own = Bundle.main.bundleIdentifier
        var byID: [CGWindowID: SCWindow] = [:]
        for w in content.windows where w.windowLayer == 0 && w.frame.width >= 120 && w.frame.height >= 80
            && w.owningApplication?.bundleIdentifier != own && w.owningApplication != nil {
            byID[w.windowID] = w
        }
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        var out: [StreamableWindow] = []
        for id in order {
            guard let w = byID.removeValue(forKey: id) else { continue }
            out.append(StreamableWindow(id: w.windowID, app: w.owningApplication?.applicationName ?? "",
                                        title: w.title ?? "", width: UInt32(clamping: Int(w.frame.width)), height: UInt32(clamping: Int(w.frame.height))))
        }
        return Array(out.prefix(WindowList.maxWindows))
    }

    struct Info: Sendable, Equatable {
        var frame: CGRect          // global display points, top-left origin (the CGEvent space)
        var title: String
        var app: String
        var pid: pid_t
    }

    /// The window's current frame and names, or nil once it's closed or off screen.
    static func info(_ id: CGWindowID) -> Info? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let d = list.first, (d[kCGWindowIsOnscreen as String] as? Bool) ?? true,
              let b = d[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        return Info(frame: frame, title: d[kCGWindowName as String] as? String ?? "",
                    app: d[kCGWindowOwnerName as String] as? String ?? "",
                    pid: (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
    }

    /// The display a frame is (mostly) on: the one holding its centre.
    static func display(for frame: CGRect) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var n: UInt32 = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &id, &n) == .success, n > 0 else { return nil }
        return id
    }

    /// Resizes the window to `size` points (Accessibility), keeping it on its display under the menu bar.
    /// Returns whether it was resized; the app may refuse (fixed-size windows) or keep a minimum.
    @discardableResult
    static func resize(_ id: CGWindowID, to size: CGSize) -> Bool {
        guard let info = info(id), let w = axWindow(info) else { return false }
        let screen = visibleFrame(around: info.frame)
        var origin = info.frame.origin
        if origin.x + size.width > screen.maxX { origin.x = max(screen.minX, screen.maxX - size.width) }
        if origin.y + size.height > screen.maxY { origin.y = max(screen.minY, screen.maxY - size.height) }
        var s = size, o = origin
        if let pos = AXValueCreate(.cgPoint, &o) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos) }
        guard let sz = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sz) == .success
    }

    /// The window's Accessibility element. Accessibility has no window number, so it's matched by frame.
    private static func axWindow(_ info: Info) -> AXUIElement? {
        guard InputInjector.allowed || AXIsProcessTrusted(), info.pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(info.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { w in
            guard let f = frame(of: w) else { return false }
            return abs(f.minX - info.frame.minX) < 2 && abs(f.minY - info.frame.minY) < 2
                && abs(f.width - info.frame.width) < 2 && abs(f.height - info.frame.height) < 2
        }
    }

    /// Brings the window and its app to the front. With `wait`, gives the window server a moment (up to
    /// 150 ms) to put it on top, so a click that follows lands on it.
    static func raise(_ id: CGWindowID, wait: Bool = false) {
        guard let info = info(id) else { return }
        if let w = axWindow(info) {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        let pid = info.pid
        DispatchQueue.main.async { NSRunningApplication(processIdentifier: pid)?.activate() }
        guard wait else { return }
        let point = CGPoint(x: info.frame.midX, y: info.frame.midY)
        for _ in 0..<15 {
            if isFrontmost(id, at: point) { return }
            usleep(10_000)
        }
    }

    /// Whether `id` is the topmost ordinary window at `point` (global points), so a click there reaches it.
    static func isFrontmost(_ id: CGWindowID, at point: CGPoint) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for d in list {
            guard (d[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let f = CGRect(dictionaryRepresentation: b as CFDictionary), f.contains(point) else { continue }
            if (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue == 0 { continue }
            if (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() { continue }
            return (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
        }
        return false
    }

    /// The usable part of the window's screen (no menu bar or Dock) in top-left global points.
    static func visibleFrame(around frame: CGRect) -> CGRect {
        guard let id = display(for: frame) else { return frame }
        let bounds = CGDisplayBounds(id)
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
        guard let s = screen else { return bounds }
        // AppKit's frames start at the bottom left of the main screen; CG's at its top left.
        let mainHeight = NSScreen.screens.first?.frame.height ?? bounds.height
        let v = s.visibleFrame
        return CGRect(x: v.minX, y: mainHeight - v.maxY, width: v.width, height: v.height)
    }

    private static func frame(of w: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success,
              let pv = p, let sv = s, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        // Type IDs checked above, so these are AXValues.
        guard AXValueGetValue(unsafeDowncast(pv, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(sv, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
