import AppKit
import ClamshellInput
import Foundation
import UserNotifications

/// Finder › Services › "Send to iPhone with Clamshell" (1.1): files selected in Finder go to the connected
/// phone, which saves them in Files › On My iPhone › Clamshell › From Mac. Declared in Info.plist (NSServices).
@MainActor
final class SendToPhoneService: NSObject {
    private let send: ([URL]) -> String

    init(send: @escaping ([URL]) -> String) { self.send = send }

    @objc func sendToPhone(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { error.pointee = "No files to send." as NSString; return }
        let note = send(urls)
        if !note.isEmpty { error.pointee = note as NSString }
    }
}

/// When each paired phone's app stops opening (1.1): the phone sends it in `Hello.appExpires`. Kept per
/// phone (by public key) so the menu can show it and the Mac can remind the day before.
struct PhoneAppExpiry {
    private static let key = "phoneAppExpires"

    static func record(_ seconds: UInt64?, for publicKey: [UInt8]) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        let id = hex(publicKey)
        if let seconds, seconds > 0 { all[id] = Double(seconds) } else { all.removeValue(forKey: id) }
        UserDefaults.standard.set(all, forKey: key)
    }

    static func expires(_ publicKey: [UInt8]) -> Date? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[hex(publicKey)].map { Date(timeIntervalSince1970: $0) }
    }

    /// For the menu, under the phone's name.
    static func text(_ publicKey: [UInt8], now: Date = .now) -> String? {
        guard let d = expires(publicKey) else { return nil }
        let when = d.formatted(date: .abbreviated, time: .shortened)
        switch AppExpiry.warning(expires: d, now: now) {
        case .none: return "app runs until \(when)"
        case .soon(let days): return "app stops opening in \(days) day\(days == 1 ? "" : "s"): run release.sh with the phone plugged in"
        case .today: return "app stops opening today at \(d.formatted(date: .omitted, time: .shortened))"
        case .expired: return "app has expired: run release.sh with the phone plugged in"
        }
    }

    static func isUrgent(_ publicKey: [UInt8], now: Date = .now) -> Bool {
        guard let d = expires(publicKey) else { return false }
        return AppExpiry.warning(expires: d, now: now) != .none
    }

    /// A Mac notification the day before the phone's app runs out (asks permission only when it's close).
    static func scheduleReminder(_ publicKey: [UInt8], phone: String, now: Date = .now) async {
        guard let d = expires(publicKey), AppExpiry.warning(expires: d, now: now) != .none,
              let at = AppExpiry.reminderDate(expires: d, now: now) else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let id = "phone-app-expiry-" + hex(publicKey).prefix(16)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let content = UNMutableNotificationContent()
        content.title = "Clamshell on \(phone) stops opening soon"
        content.body = "It runs out \(d.formatted(date: .abbreviated, time: .shortened)). Plug the phone in and run tools/scripts/release.sh to rebuild it."
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        try? await center.add(UNNotificationRequest(identifier: id, content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }

    private static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
}
