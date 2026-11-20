import AppKit
import UserNotifications

/// Someone at the Mac during a session (docs/security.md T9). Watches *local* keyboard and mouse input
/// (events Clamshell posts carry `InputInjector.tag`, or end where it just moved the pointer, and are ignored):
/// - any local key, click or scroll, or a deliberate pointer move (`moveDistance` points within
///   `moveWindow` seconds), pauses the phone's input until the Mac has been quiet for 3 s, and the phone
///   shows a banner. A hand brushing the trackpad while someone holds the phone next to the Mac doesn't;
/// - Esc pressed three times within 1.5 s ends every session at once.
/// Global monitors need Accessibility, which input injection already requires.
@MainActor
final class LocalUserGuard {
    static let quietSeconds = 3.0
    /// How far the Mac's own pointer must travel, within `moveWindow`, to count as someone using it.
    static let moveDistance = 40.0
    static let moveWindow = 1.0
    private var moves: [(at: Date, distance: Double)] = []
    private var monitor: Any?
    private var escapes: [Date] = []
    private var quietTimer: Timer?
    private(set) var active = false
    private let onChange: (Bool) -> Void
    private let onPanic: () -> Void

    init(onChange: @escaping (Bool) -> Void, onPanic: @escaping () -> Void) {
        self.onChange = onChange
        self.onPanic = onPanic
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved]) { [weak self] e in
            // Ours: the tag, or (in case a coalesced event lost it) posted by this very process.
            let pid = e.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0
            let moved: Double? = e.type == .mouseMoved ? Double(hypot(e.deltaX, e.deltaY)) : nil
            // A merged move can lose both; one landing where Clamshell just put the pointer is ours too.
            let tagged = e.cgEvent?.getIntegerValueField(.eventSourceUserData) == InputInjector.tag || pid == Int64(getpid())
                || (moved != nil && e.cgEvent.map { InputInjector.postedMove(near: $0.location) } == true)
            let keyCode = e.type == .keyDown ? e.keyCode : nil
            let what = "\(Self.name(e.type)) from pid \(pid)\(pid > 0 ? " (\(Self.processName(pid)))" : "")"
            MainActor.assumeIsolated { self?.saw(tagged: tagged, escape: keyCode == 53, moved: moved, what: what) }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        quietTimer?.invalidate()
        quietTimer = nil
        escapes.removeAll()
        moves.removeAll()
        if active { active = false; onChange(false) }
    }

    private func saw(tagged: Bool, escape: Bool, moved: Double?, what: String) {
        guard !tagged else { return }
        if let moved, active {
            guard moved >= 3 else { return }           // a twitch doesn't keep the pause going
        } else if let moved {
            // Only a deliberate move counts: brushes and twitches add up to a few points and then stop.
            let now = Date()
            moves = moves.filter { now.timeIntervalSince($0.at) < Self.moveWindow } + [(now, moved)]
            let total = moves.reduce(0) { $0 + $1.distance }
            guard total >= Self.moveDistance else { return }
            moves.removeAll()
        }
        if escape {
            let now = Date()
            escapes = escapes.filter { now.timeIntervalSince($0) < 1.5 } + [now]
            if escapes.count >= 3 { escapes.removeAll(); onPanic(); return }
        }
        if !active { active = true; print("local input: \(what)"); onChange(true) }
        quietTimer?.invalidate()
        quietTimer = Timer.scheduledTimer(withTimeInterval: Self.quietSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                self.active = false
                self.onChange(false)
            }
        }
    }

    private static func name(_ t: NSEvent.EventType) -> String {
        switch t {
        case .keyDown: "key"
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: "click"
        case .scrollWheel: "scroll"
        case .mouseMoved: "mouse move"
        default: "event \(t.rawValue)"
        }
    }

    private static func processName(_ pid: Int64) -> String {
        NSRunningApplication(processIdentifier: pid_t(truncatingIfNeeded: pid))?.localizedName ?? "not an app: real hardware or a system service"
    }

    /// "Your iPhone is viewing this Mac": a notification on every session start (T9). Asks once.
    static func notifySessionStarted(phone: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(phone) is connected"
            content.body = "Clamshell is showing this Mac's screen to it. Press Esc three times to disconnect."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "clamshell.session", content: content, trigger: nil))
        }
    }
}
