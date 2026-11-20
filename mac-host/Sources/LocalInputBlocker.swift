import AppKit
import CoreGraphics

/// Turns this Mac's own keyboard, trackpad and mouse off while a phone uses it (1.9, optional; the idea comes
/// from RustDesk's "block user input", the code doesn't). An event tap at the head of the login session drops
/// every local key, click, move and scroll; events Clamshell posts for the phone carry `InputInjector.tag`
/// and pass.
///
/// Ways out, always: Esc pressed three times within 1.5 s ends the session (counted here, before the event
/// is dropped); the session ending for any reason removes the tap; the tap dies with the process; and the
/// power button, which no event tap sees. Needs Accessibility, which input from the phone already requires.
@MainActor
final class LocalInputBlocker {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var escapes: [Date] = []
    private var lastAttempt = Date.distantPast
    var onPanic: () -> Void = {}
    /// Someone at the Mac tried to use it (at most once a second).
    var onAttempt: () -> Void = {}

    var active: Bool { tap != nil }

    /// Returns false when the tap couldn't be made (no Accessibility).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                    .otherMouseDragged, .scrollWheel]
        var mask: CGEventMask = 0
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
        // Media, brightness, volume and power keys (NX_SYSDEFINED) stay on: the power key must always work.
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: Self.callback, userInfo: me) else {
            print("local input: couldn't turn the Mac's keyboard and trackpad off (no Accessibility?)")
            return false
        }
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
        print("local input: the Mac's keyboard and trackpad are off for the session (Esc ×3 ends it)")
        return true
    }

    func stop() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        CFMachPortInvalidate(port)
        tap = nil
        source = nil
        escapes.removeAll()
        print("local input: the Mac's keyboard and trackpad are on again")
    }

    /// Whether to let the event through.
    /// What the tap needs from an event, read before leaving the callback's own context.
    fileprivate struct Seen: Sendable {
        var type: CGEventType
        var ours: Bool
        var escape: Bool
        var small: Bool

        init(_ type: CGEventType, _ event: CGEvent) {
            self.type = type
            ours = event.getIntegerValueField(.eventSourceUserData) == InputInjector.tag
                || event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
            escape = type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53
                && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
            small = type == .mouseMoved
                && abs(event.getDoubleValueField(.mouseEventDeltaX)) + abs(event.getDoubleValueField(.mouseEventDeltaY)) < 3
        }
    }

    fileprivate func handle(_ e: Seen) -> Bool {
        if e.type == .tapDisabledByTimeout || e.type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        if e.ours { return true }
        if e.escape {
            let now = Date()
            escapes = escapes.filter { now.timeIntervalSince($0) < 1.5 } + [now]
            if escapes.count >= 3 {
                escapes.removeAll()
                // Not from inside the tap's callback: stopping the tap there would pull the run loop source mid-call.
                DispatchQueue.main.async { [weak self] in self?.onPanic() }
                return false
            }
        }
        if !e.small, Date().timeIntervalSince(lastAttempt) > 1 {
            lastAttempt = Date()
            DispatchQueue.main.async { [weak self] in self?.onAttempt() }
        }
        return false
    }

    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let blocker = Unmanaged<LocalInputBlocker>.fromOpaque(info).takeUnretainedValue()
        // The tap's run loop source is on the main run loop, so this runs on the main thread.
        let seen = Seen(type, event)
        let pass = MainActor.assumeIsolated { blocker.handle(seen) }
        return pass ? Unmanaged.passUnretained(event) : nil
    }
}
