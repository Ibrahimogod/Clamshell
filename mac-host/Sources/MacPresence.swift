import AppKit
import ClamshellWire
import CoreGraphics
import IOKit.ps
import IOKit.pwr_mgt

/// What the Mac's own session is doing, and keeping it awake while a phone watches.
///
/// Why: a Mac left alone starts the screen saver after its idle time (on the test Mac: Aerial, which renders
/// at 30 fps, so capture dropped to 30 frames/s), and then locks. A remote viewer would see the saver, then
/// the lock screen, with no way to tell why. So while streaming:
/// - a `PreventUserIdleDisplaySleep` assertion holds off display sleep, and with it the screen saver and the
///   lock that follows it (the same assertion a video player takes). No permission needed;
/// - if the host may post events (Accessibility, granted for input in M2), a zero-distance mouse move every
///   25 s also resets the HID idle timer, for policies that lock on idle time alone;
/// - lock and screen-saver changes are reported (`HostState`), so the phone can say "the Mac is locked".
///   Unlocking stays with the person at the Mac or, from M2, typing the password through the stream.
@MainActor
final class MacPresence {
    private(set) var screen: MacScreenState = .active
    private(set) var holdingAwake = false
    var onChange: ((MacScreenState) -> Void)?

    private var locked = false
    private var saverRunning = false
    private var observers: [NSObjectProtocol] = []
    private var assertion: IOPMAssertionID = 0
    private var nudge: Timer?
    private var systemAssertion: IOPMAssertionID = 0
    private var holdingSystem = false
    private var powerTimer: Timer?

    /// M5: keep the Mac from idle *system* sleep while it is on AC power, so the phone can always reach it.
    /// The display may still sleep; a connecting phone wakes it (`wakeDisplay`). Off on battery.
    var keepAwakeOnAC = false {
        didSet {
            powerTimer?.invalidate()
            powerTimer = nil
            if keepAwakeOnAC {
                powerTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { self.updateSystemAssertion() } }
            }
            updateSystemAssertion()
        }
    }

    static func onACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    private func updateSystemAssertion() {
        let want = keepAwakeOnAC && Self.onACPower()
        if want, !holdingSystem {
            holdingSystem = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                        "Clamshell keeps this Mac reachable from your phone while it is plugged in" as CFString,
                                                        &systemAssertion) == kIOReturnSuccess
        } else if !want, holdingSystem {
            IOPMAssertionRelease(systemAssertion)
            holdingSystem = false
        }
    }

    /// Wakes a sleeping display (a phone just connected), as a key press would.
    func wakeDisplay() {
        var id: IOPMAssertionID = 0
        if IOPMAssertionDeclareUserActivity("Clamshell: a paired phone connected" as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess {
            // The declared activity times out by itself; releasing early would let the display sleep again at once.
            Task { try? await Task.sleep(for: .seconds(5)); IOPMAssertionRelease(id) }
        }
    }

    init() {
        locked = Self.sessionIsLocked()
        screen = Self.state(locked: locked, saver: false)
        let center = DistributedNotificationCenter.default()
        let names = ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "com.apple.screensaver.didstart", "com.apple.screensaver.didstop"]
        for name in names {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let name = note.name.rawValue
                MainActor.assumeIsolated { self?.received(name) }
            })
        }
    }

    private func received(_ name: String) {
        switch name {
        case "com.apple.screenIsLocked": locked = true
        case "com.apple.screenIsUnlocked": locked = false
        case "com.apple.screensaver.didstart": saverRunning = true
        case "com.apple.screensaver.didstop": saverRunning = false
        default: return
        }
        update()
    }

    /// Whether the host can also reset the idle timer (post-event access).
    var canNudge: Bool { CGPreflightPostEventAccess() }

    func holdAwake(reason: String) {
        guard !holdingAwake else { return }
        let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion)
        holdingAwake = ok == kIOReturnSuccess
        nudge = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { _ in
            MainActor.assumeIsolated { Self.nudgeIdleTimer() }
        }
    }

    func release() {
        nudge?.invalidate()
        nudge = nil
        if holdingAwake { IOPMAssertionRelease(assertion); holdingAwake = false }
    }

    func stop() {
        release()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
    }

    private func update() {
        // The notifications can race the session state; the session dictionary is the truth for "locked".
        locked = Self.sessionIsLocked() || locked && !Self.sessionKnown()
        let s = Self.state(locked: locked, saver: saverRunning)
        guard s != screen else { return }
        screen = s
        onChange?(s)
    }

    private static func state(locked: Bool, saver: Bool) -> MacScreenState {
        locked ? .locked : saver ? .screenSaver : .active
    }

    private static func sessionDictionary() -> [String: Any]? {
        CGSessionCopyCurrentDictionary() as? [String: Any]
    }

    private static func sessionKnown() -> Bool { sessionDictionary() != nil }

    static func sessionIsLocked() -> Bool {
        (sessionDictionary()?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// A mouse move to where the pointer already is: no visible effect, but it counts as user activity.
    private static func nudgeIdleTimer() {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = InputInjector.tag                // ours: LocalUserGuard must not take it for a person
        guard CGPreflightPostEventAccess(), let here = CGEvent(source: nil)?.location,
              let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                              mouseCursorPosition: here, mouseButton: .left) else { return }
        e.post(tap: .cghidEventTap)
    }
}
