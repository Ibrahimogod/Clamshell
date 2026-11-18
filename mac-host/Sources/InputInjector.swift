import AppKit
import ClamshellInput
import ClamshellWire
import CoreGraphics
import Foundation
import os

/// Posts the phone's keyboard, pointer, scroll and gestures as real macOS events (ADR-0013).
///
/// - Needs Accessibility ("post events") permission: `CGPreflightPostEventAccess`. Without it, input is
///   dropped and the phone is told (`HostState.inputAllowed`).
/// - Events come from a private event source tagged `userData = 'CLAM'`, so local input can be told apart.
/// - The pointer stays on the streamed display (the Mac's own when mirroring): it is the only one the phone sees.
/// - `InputReceiver` does the protocol work (dedupe, modifiers, Mac-side key repeat, momentum, watchdog);
///   this class only turns its actions into `CGEvent`s, on its own queue, with an 8 ms tick.
final class InputInjector: @unchecked Sendable {
    static let tag: Int64 = 0x434C_414D               // 'CLAM'

    private let queue = DispatchQueue(label: "clamshell.input", qos: .userInteractive)
    private let displayID: CGDirectDisplayID
    /// Cursor reports are in the stream picture's points (picture pixels / scale), which is what the phone
    /// lays out; equal to the display's points for a separate display, smaller when mirroring a big screen.
    private let reportSize: CGSize
    private let reportCursor: @Sendable (CursorPosition) -> Void
    private var receiver: InputReceiver
    private var timer: DispatchSourceTimer?
    private let source: CGEventSource?
    private var position: CGPoint?
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var hotkeys: SymbolicHotkeys
    private var lastCursorReportNs: UInt64 = 0
    private var cursorDirty = false
    private(set) var shapeId: UInt64 = 0
    /// A streamed window's frame (1.8), in global points: the pointer stays in it and cursor reports are
    /// relative to it. Nil: the whole display.
    private let area = OSAllocatedUnfairLock<CGRect?>(initialState: nil)
    func setArea(_ rect: CGRect?) {
        area.withLock { $0 = rect }
        queue.async { [self] in cursorDirty = true }
    }

    /// The streamed rectangle: the window, or the display.
    private var bounds: CGRect { area.withLock { $0 } ?? CGDisplayBounds(displayID) }

    /// While one window is streamed: called on the input queue before a button goes down, with the point
    /// (global display points), so the host can bring the window to the front first.
    var beforeClick: (@Sendable (CGPoint) -> Void)? {
        get { clickHook.withLock { $0 } }
        set { clickHook.withLock { $0 = newValue } }
    }
    private let clickHook = OSAllocatedUnfairLock<(@Sendable (CGPoint) -> Void)?>(initialState: nil)

    /// Picture points (what the phone uses) ↔ the display's points.
    var pointerSpace: PointerSpace {
        let b = bounds
        return PointerSpace(pictureWidth: reportSize.width, pictureHeight: reportSize.height, displayWidth: b.width, displayHeight: b.height)
    }

    init(displayID: CGDirectDisplayID, reportSize: CGSize, reportCursor: @escaping @Sendable (CursorPosition) -> Void) {
        self.displayID = displayID
        self.reportSize = reportSize
        self.reportCursor = reportCursor
        let d = UserDefaults.standard, g = d.persistentDomain(forName: UserDefaults.globalDomain)
        receiver = InputReceiver(config: InputConfig(
            initialKeyRepeatTicks: g?["InitialKeyRepeat"] as? Int,
            keyRepeatTicks: g?["KeyRepeat"] as? Int,
            doubleClickSeconds: NSEvent.doubleClickInterval,
            naturalScroll: g?["com.apple.swipescrolldirection"] as? Bool ?? d.object(forKey: "naturalScroll") as? Bool))
        source = CGEventSource(stateID: .privateState)
        source?.userData = Self.tag
        hotkeys = SymbolicHotkeys.load()
    }

    static var allowed: Bool { CGPreflightPostEventAccess() }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        queue.async { [self] in
            // Keep the cursor where it is if it's on the streamed display (mirroring); otherwise bring it to
            // the middle of the Clamshell display.
            let b = bounds
            if let here = CGEvent(source: nil)?.location, b.contains(here) {
                position = here
            } else {
                position = CGPoint(x: b.midX, y: b.midY)
                if Self.allowed { CGWarpMouseCursorPosition(CGPoint(x: b.midX, y: b.midY)) }
            }
            cursorDirty = true
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { for a in receiver.releaseAll() { post(a) } }
    }

    /// Lets go of every key and button the phone holds (local user took over, T9).
    func releaseAllHeld() {
        queue.async { [self] in for a in receiver.releaseAll() { post(a) } }
    }

    func handle(_ messages: [InnerMessage]) {
        let now = HostClock.nowNs()
        queue.async { [self] in
            let actions = receiver.receive(messages, nowNs: now)
            let allowed = Self.allowed
            counts.withLock { $0.messages += messages.count; $0.actions += allowed ? actions.count : 0; $0.refused += allowed ? 0 : actions.count }
            guard allowed else { return }
            for a in actions { post(a) }
        }
    }

    /// For the host log: input messages from the phone, actions posted, actions refused (no Accessibility).
    private let counts = OSAllocatedUnfairLock(initialState: (messages: 0, actions: 0, refused: 0))
    func takeCounts() -> (messages: Int, actions: Int, refused: Int) {
        counts.withLock { c in defer { c = (0, 0, 0) }; return c }
    }

    func setShape(_ id: UInt64) { queue.async { [self] in shapeId = id; cursorDirty = true } }

    // MARK: queue

    private func tick() {
        let now = HostClock.nowNs()
        let actions = receiver.tick(nowNs: now)
        if Self.allowed { for a in actions { post(a) } }
        // The Mac's cursor position for the phone's local cursor: ≤ 60 Hz while it moves, and every 250 ms
        // anyway (an app may warp it, a window may snap it).
        if now >= lastCursorReportNs + (cursorDirty ? 16_000_000 : 250_000_000) {
            lastCursorReportNs = now
            cursorDirty = false
            let b = bounds
            let here = CGEvent(source: nil)?.location ?? position ?? .zero
            let onDisplay = b.contains(here)
            let p = onDisplay ? here : (position ?? CGPoint(x: b.midX, y: b.midY))
            reportCursor(CursorPosition(appliedSeq: receiver.appliedPointerSeq, x: Int32((p.x - b.minX) / max(b.width, 1) * reportSize.width * 16),
                                        y: Int32((p.y - b.minY) / max(b.height, 1) * reportSize.height * 16),
                                        visible: onDisplay, shapeId: shapeId))
        }
    }

    private func post(_ a: InputAction) {
        switch a {
        case .key(let code, let down, let flags, let isRepeat):
            key(code, down: down, flags: flags, isRepeat: isRepeat)
        case .media(let k, let down):
            media(k, down: down)
        case .move(let dx, let dy, let buttons):
            // The phone moves its cursor in picture points; a shrunk picture (away, or a small posture) has
            // fewer of them than the display, so scale the move up to the display's points.
            let d = pointerSpace.displayDelta(dx: dx, dy: dy)
            move(to: current().applying(.init(translationX: d.dx, y: d.dy)), dx: d.dx, dy: d.dy, buttons: buttons)
        case .moveTo(let x, let y, let buttons):
            let b = bounds
            let p = CGPoint(x: b.minX + x * b.width, y: b.minY + y * b.height)
            let c = current()
            move(to: p, dx: p.x - c.x, dy: p.y - c.y, buttons: buttons)
        case .button(let b, let down, let count, let flags):
            button(b, down: down, clickCount: count, flags: flags)
        case .scroll(let dx, let dy, let phase, let momentum, let flags):
            scroll(dx: dx, dy: dy, phase: phase, momentum: momentum, flags: flags)
        case .gesture(let g):
            gesture(g)
        case .nextInputSource:
            DispatchQueue.main.async { MainActor.assumeIsolated { KeyboardLayouts.selectNext() } }
        }
    }

    private func current() -> CGPoint {
        let b = bounds
        // Follow the real cursor when it is on our display (an app warped it, or someone at the Mac moved
        // it); otherwise bring it back to where the phone left it.
        if let here = CGEvent(source: nil)?.location, b.contains(here) { position = here; return here }
        return position ?? CGPoint(x: b.midX, y: b.midY)
    }

    private func move(to target: CGPoint, dx: Double, dy: Double, buttons: MouseButtons) {
        let b = bounds
        let p = CGPoint(x: min(max(target.x, b.minX), b.maxX - 1), y: min(max(target.y, b.minY), b.maxY - 1))
        position = p
        cursorDirty = true
        let (type, button): (CGEventType, CGMouseButton) =
            buttons.contains(.left) ? (.leftMouseDragged, .left) :
            buttons.contains(.right) ? (.rightMouseDragged, .right) :
            buttons.contains(.middle) ? (.otherMouseDragged, .center) : (.mouseMoved, .left)
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e.flags = Self.cgFlags(receiver.modifiers)
        e.post(tap: .cghidEventTap)
    }

    private func button(_ b: PointerButton, down: Bool, clickCount: Int, flags: KeyModifiers) {
        let (type, cg): (CGEventType, CGMouseButton) = switch b {
        case .left: (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: (down ? .rightMouseDown : .rightMouseUp, .right)
        case .middle: (down ? .otherMouseDown : .otherMouseUp, .center)
        }
        let at = current()
        if down, area.withLock({ $0 }) != nil, let hook = beforeClick { hook(at) }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: cg) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e.flags = Self.cgFlags(flags)
        e.post(tap: .cghidEventTap)
    }

    private func scroll(dx: Double, dy: Double, phase: ScrollPhase, momentum: MomentumPhase, flags: KeyModifiers) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let ix = scrollRemainder.x.rounded(.towardZero), iy = scrollRemainder.y.rounded(.towardZero)
        scrollRemainder.x -= ix
        scrollRemainder.y -= iy
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let p: Int64 = switch phase { case .began: 1; case .changed: 2; case .ended: 4; case .cancelled: 8; case .none: 0 }
        let m: Int64 = switch momentum { case .none: 0; case .begin: 1; case .continue: 2; case .end: 3 }
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: p)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: m)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: iy)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: ix)
        e.location = current()
        e.flags = Self.cgFlags(flags)
        e.post(tap: .cghidEventTap)
        if phase == .began || momentum == .end { scrollRemainder = (0, 0) }
    }

    private func key(_ code: UInt16, down: Bool, flags: KeyModifiers, isRepeat: Bool = false, extra: CGEventFlags = []) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        var f = Self.cgFlags(flags).union(extra)
        if KeyMap.modifierKeys.contains(where: { $0.1 == code }) {
            e.type = .flagsChanged
        } else {
            f.formUnion(Self.deviceFlags(for: code))
        }
        e.flags = f
        if isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        e.post(tap: .cghidEventTap)
    }

    /// A shortcut as a real keyboard would type it: modifiers down, key down/up, modifiers up.
    private func chord(_ code: UInt16, _ flags: CGEventFlags) {
        let held = Self.cgFlags(receiver.modifiers)
        let mods: [(CGEventFlags, UInt16)] = [(.maskControl, 0x3B), (.maskAlternate, 0x3A), (.maskShift, 0x38), (.maskCommand, 0x37)]
        var now = held
        for (m, c) in mods where flags.contains(m) && !held.contains(m) {
            now.insert(m)
            post(flagsChanged: c, now)
        }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = now.union(flags)
            e.post(tap: .cghidEventTap)
        }
        for (m, c) in mods.reversed() where flags.contains(m) && !held.contains(m) {
            now.remove(m)
            post(flagsChanged: c, now)
        }
    }

    private func post(flagsChanged code: UInt16, _ flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { return }
        e.type = .flagsChanged
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private var switcherHeld = false

    private func gesture(_ g: GestureKind) {
        switch g {
        case .spaceLeft: hotkeys.post(.spaceLeft, via: chord)
        case .spaceRight: hotkeys.post(.spaceRight, via: chord)
        case .missionControl: hotkeys.post(.missionControl, via: chord)
        case .appExpose: hotkeys.post(.appExpose, via: chord)
        case .showDesktop: hotkeys.post(.showDesktop, via: chord)
        case .launchpad: chord(0x83, [])
        case .lookUp: chord(0x02, [.maskControl, .maskCommand])                 // ⌃⌘D
        case .zoomIn: chord(0x18, .maskCommand)                                 // ⌘=
        case .zoomOut: chord(0x1B, .maskCommand)                                // ⌘-
        case .smartZoom: chord(0x1D, .maskCommand)                              // ⌘0
        case .appSwitcherBegin:
            switcherHeld = true
            post(flagsChanged: 0x37, Self.cgFlags(receiver.modifiers).union(.maskCommand))
            tab(back: false)
        case .appSwitcherNext: if switcherHeld { tab(back: false) }
        case .appSwitcherPrevious: if switcherHeld { tab(back: true) }
        case .appSwitcherEnd:
            guard switcherHeld else { return }
            switcherHeld = false
            post(flagsChanged: 0x37, Self.cgFlags(receiver.modifiers))
        }
    }

    private func tab(back: Bool) {
        var f = Self.cgFlags(receiver.modifiers).union(.maskCommand)
        if back { f.insert(.maskShift) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0x30, keyDown: down) else { continue }
            e.flags = f
            e.post(tap: .cghidEventTap)
        }
    }

    private func media(_ k: MediaKey, down: Bool) {
        let nx: Int32? = switch k {
        case .volumeUp: 0
        case .volumeDown: 1
        case .brightnessUp: 2
        case .brightnessDown: 3
        case .mute: 7
        case .play: 16
        case .next: 17
        case .previous: 18
        case .keyboardBrightnessUp: 21
        case .keyboardBrightnessDown: 22
        default: nil
        }
        if let nx {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((nx << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
            return
        }
        guard down else { return }
        switch k {
        case .missionControl: hotkeys.post(.missionControl, via: chord)
        case .spotlight: chord(0x31, .maskCommand)
        case .launchpad: chord(0x83, [])
        default: break
        }
    }

    static func cgFlags(_ m: KeyModifiers) -> CGEventFlags {
        var f: CGEventFlags = []
        if m.control { f.insert(.maskControl) }
        if m.shift { f.insert(.maskShift) }
        if m.option { f.insert(.maskAlternate) }
        if m.command { f.insert(.maskCommand) }
        if m.contains(.capsLock) { f.insert(.maskAlphaShift) }
        if m.contains(.function) { f.insert(.maskSecondaryFn) }
        // Device-dependent bits for left/right, as a real keyboard sets them (some apps read them).
        let device: [(KeyModifiers, UInt64)] = [(.leftControl, 0x1), (.leftShift, 0x2), (.rightShift, 0x4), (.leftCommand, 0x8),
                                                (.rightCommand, 0x10), (.leftOption, 0x20), (.rightOption, 0x40), (.rightControl, 0x2000)]
        for (bit, raw) in device where m.contains(bit) { f.insert(CGEventFlags(rawValue: raw)) }
        return f
    }

    /// Arrows carry fn + numeric pad, and the navigation and F keys fn, as they do from a Mac keyboard
    /// (the system's shortcut matching expects it).
    static func deviceFlags(for code: UInt16) -> CGEventFlags {
        switch code {
        case 0x7B...0x7E: [.maskSecondaryFn, .maskNumericPad]
        case 0x72, 0x73, 0x74, 0x75, 0x77, 0x79, 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F: .maskSecondaryFn
        default: []
        }
    }
}

/// The user's own bindings for Spaces and Mission Control (`com.apple.symbolichotkeys`), with the
/// macOS defaults when a binding is absent. Disabled bindings fall back to the default key.
struct SymbolicHotkeys: Sendable {
    enum Action: Int, Sendable { case missionControl = 32, appExpose = 33, showDesktop = 36, spaceLeft = 79, spaceRight = 81 }
    private var bindings: [Action: (code: UInt16, flags: CGEventFlags)] = [
        .missionControl: (0x7E, CGEventFlags(rawValue: 0x840000)),        // ⌃↑ (+fn, as arrows carry it)
        .appExpose: (0x7D, CGEventFlags(rawValue: 0x840000)),             // ⌃↓
        .showDesktop: (0x67, CGEventFlags(rawValue: 0x800000)),           // F11
        .spaceLeft: (0x7B, CGEventFlags(rawValue: 0x840000)),             // ⌃←
        .spaceRight: (0x7C, CGEventFlags(rawValue: 0x840000)),            // ⌃→
    ]

    static func load() -> SymbolicHotkeys {
        var s = SymbolicHotkeys()
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") else { return s }
        for a in [Action.missionControl, .appExpose, .showDesktop, .spaceLeft, .spaceRight] {
            guard let entry = all[String(a.rawValue)] as? [String: Any], (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1),
                  let value = entry["value"] as? [String: Any], let p = value["parameters"] as? [Int], p.count == 3,
                  p[1] >= 0, p[1] < 0xFFFF else { continue }
            s.bindings[a] = (UInt16(p[1]), CGEventFlags(rawValue: UInt64(p[2])))
        }
        return s
    }

    func post(_ a: Action, via chord: (UInt16, CGEventFlags) -> Void) {
        guard let b = bindings[a] else { return }
        chord(b.code, b.flags)
    }
}
