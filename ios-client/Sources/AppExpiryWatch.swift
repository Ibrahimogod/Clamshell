import ClamshellInput
import Foundation
import UserNotifications

/// When this build stops opening (1.1): from the app's provisioning profile. With a free Apple Account
/// that's 7 days after the build; the connect screen warns from 3 days before, and a notification
/// reminds the day before (it asks for permission the first time there's something to remind of).
@MainActor
enum AppExpiryWatch {
    static let dates: AppExpiry.Dates? = {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return AppExpiry.dates(profile: data)
        #endif
    }()

    /// For `Hello.appExpires`.
    static var unixSeconds: UInt64? { dates.map { UInt64(max(0, $0.expires.timeIntervalSince1970)) } }

    /// The connect screen's warning, nil when there's nothing to say yet.
    static func warningText(now: Date = .now) -> String? {
        guard let d = dates else { return nil }
        let when = d.expires.formatted(date: .abbreviated, time: .shortened)
        let rebuild = "Rebuild it on the Mac with tools/scripts/release.sh (phone connected) to get " + (d.shortLived ? "another 7 days." : "a new year.")
        switch AppExpiry.warning(expires: d.expires, now: now) {
        case .none: return nil
        case .soon(let days): return "This app stops opening in \(days) day\(days == 1 ? "" : "s") (\(when)). " + rebuild
        case .today: return "This app stops opening today at \(d.expires.formatted(date: .omitted, time: .shortened)). " + rebuild
        case .expired: return "This build has expired. " + rebuild
        }
    }

    /// The footer line under "This phone": when the build runs out, always shown.
    static var summary: String? {
        guard let d = dates else { return nil }
        return "Build runs until " + d.expires.formatted(date: .abbreviated, time: .shortened) + (d.shortLived ? " (free Apple Account: 7 days)" : "")
    }

    /// Schedules (or moves) the day-before reminder. Asks for notification permission only once it's within
    /// 3 days, so a year-long build never prompts.
    static func scheduleReminder(now: Date = .now) async {
        guard let d = dates, let at = AppExpiry.reminderDate(expires: d.expires, now: now) else { return }
        guard AppExpiry.warning(expires: d.expires, now: now) != .none else { return }
        let center = UNUserNotificationCenter.current()
        let id = "app-expiry"
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let content = UNMutableNotificationContent()
        content.title = "Clamshell stops opening soon"
        content.body = "This build runs out " + d.expires.formatted(date: .abbreviated, time: .shortened)
            + ". Connect the phone to the Mac and run tools/scripts/release.sh to rebuild it."
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        try? await center.add(request)
    }
}
