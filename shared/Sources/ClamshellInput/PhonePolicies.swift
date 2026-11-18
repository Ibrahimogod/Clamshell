import Foundation

/// When the phone app stops opening (1.1). A build signed with a free Apple Account runs for 7 days, a paid
/// membership's for a year; after that iOS refuses to launch it until it's rebuilt. The date is in the app's
/// `embedded.mobileprovision`: a CMS-signed property list whose XML sits in it as plain text.
public enum AppExpiry {
    public struct Dates: Equatable, Sendable {
        public var created: Date?
        public var expires: Date
        /// A free Apple Account's profile: it lasts at most 7 days.
        public var shortLived: Bool { created.map { expires.timeIntervalSince($0) <= 8 * 86_400 } ?? false }
    }

    /// The profile's creation and expiration dates, or nil if `profile` isn't one (App Store and TestFlight
    /// builds have none).
    public static func dates(profile: Data) -> Dates? {
        let bytes = [UInt8](profile)
        guard let start = find(Array("<?xml".utf8), in: bytes, from: 0),
              let end = find(Array("</plist>".utf8), in: bytes, from: start) else { return nil }
        let xml = Data(bytes[start..<(end + 8)])
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else { return nil }
        guard let expires = plist["ExpirationDate"] as? Date else { return nil }
        return Dates(created: plist["CreationDate"] as? Date, expires: expires)
    }

    public enum Warning: Equatable, Sendable {
        case none
        /// Whole days left (1 or more), counted down by the calendar.
        case soon(days: Int)
        /// Runs out before midnight.
        case today
        case expired
    }

    /// No warning until 3 days before; then by calendar days in `calendar`'s time zone.
    public static func warning(expires: Date, now: Date, calendar: Calendar = .current) -> Warning {
        guard expires > now else { return .expired }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expires)).day ?? 0
        if days <= 0 { return .today }
        return days <= 3 ? .soon(days: days) : .none
    }

    /// The reminder's time: a day before it runs out, at 9:00, or in an hour if that's already past.
    public static func reminderDate(expires: Date, now: Date, calendar: Calendar = .current) -> Date? {
        guard expires > now else { return nil }
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: expires) ?? expires
        let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayBefore) ?? dayBefore
        if nine > now { return nine }
        let soon = now.addingTimeInterval(3600)
        return soon < expires ? soon : nil
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard needle.count <= hay.count else { return nil }
        var i = from
        while i <= hay.count - needle.count {
            if hay[i] == needle[0], Array(hay[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }
}

/// The battery and heat saver (1.1): how fast the phone asks the Mac to stream.
public enum PowerSaverMode: String, Codable, CaseIterable, Sendable {
    /// Full rate always (the display mode's, up to 120 fps).
    case off
    /// 60 fps when unplugged or warm, 30 in Low Power Mode or when hot; full rate on the charger.
    case auto
    /// 60 fps always, 30 in Low Power Mode or when hot.
    case always
}

public struct PowerConditions: Equatable, Sendable {
    public var unplugged: Bool
    public var lowPowerMode: Bool
    /// `ProcessInfo.ThermalState.rawValue`: 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermal: Int

    public init(unplugged: Bool, lowPowerMode: Bool, thermal: Int) {
        self.unplugged = unplugged; self.lowPowerMode = lowPowerMode; self.thermal = thermal
    }

    /// The frame-rate cap to ask for; 0 is none.
    public func cap(_ mode: PowerSaverMode) -> UInt16 {
        switch mode {
        case .off: return 0
        case .always: return lowPowerMode || thermal >= 3 ? 30 : 60
        case .auto:
            if lowPowerMode || thermal >= 3 { return 30 }
            if unplugged || thermal >= 2 { return 60 }
            return 0
        }
    }
}
