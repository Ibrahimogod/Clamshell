import AppKit
import UserNotifications

/// Someone at the Mac during a session (docs/security.md T9). Watches *local* keyboard and mouse input
/// (events Clamshell posts carry `InputInjector.tag` and are ignored):
/// - any local key, click, scroll or real mouse move pauses the phone's input until the Mac has been
///   quiet for 3 s, and the phone shows a banner;
/// - Esc pressed three times within 1.5 s ends every session at once.
/// Global monitors need Accessibility, which input injection already requires.
@MainActor
final class LocalUserGuard {
    static let quietSeconds = 3.0
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
            let tagged = e.cgEvent?.getIntegerValueField(.eventSourceUserData) == InputInjector.tag
            let keyCode = e.type == .keyDown ? e.keyCode : nil
            let small = e.type == .mouseMoved && abs(e.deltaX) + abs(e.deltaY) < 3
            MainActor.assumeIsolated { self?.saw(tagged: tagged, escape: keyCode == 53, ignorable: small) }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        quietTimer?.invalidate()
        quietTimer = nil
        escapes.removeAll()
        if active { active = false; onChange(false) }
    }

    private func saw(tagged: Bool, escape: Bool, ignorable: Bool) {
        guard !tagged, !ignorable else { return }
        if escape {
            let now = Date()
            escapes = escapes.filter { now.timeIntervalSince($0) < 1.5 } + [now]
            if escapes.count >= 3 { escapes.removeAll(); onPanic(); return }
        }
        if !active { active = true; onChange(true) }
        quietTimer?.invalidate()
        quietTimer = Timer.scheduledTimer(withTimeInterval: Self.quietSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                self.active = false
                self.onChange(false)
            }
        }
    }

    /// "Your iPhone is viewing this Mac": a notification on every session start (T9). Asks once.
    static func notifySessionStarted(phone: String) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(phone) is connected"
            content.body = "Clamshell is showing this Mac's screen to it. Press Esc three times to disconnect."
            c.add(UNNotificationRequest(identifier: "clamshell.session", content: content, trigger: nil))
        }
    }
}
