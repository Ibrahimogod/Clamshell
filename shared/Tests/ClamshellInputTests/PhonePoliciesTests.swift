import Foundation
import Testing
@testable import ClamshellInput

@Suite("App expiry")
struct AppExpiryTests {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }()

    static func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s) ?? .distantPast }

    /// A provisioning profile as Xcode writes it: CMS bytes around a plain XML property list.
    static func profile(created: String, expires: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>AppIDName</key><string>Clamshell</string>
        <key>CreationDate</key><date>\(created)</date>
        <key>ExpirationDate</key><date>\(expires)</date>
        </dict></plist>
        """
        return Data([0x30, 0x82, 0x2F, 0x00, 0x06, 0x09]) + Data(xml.utf8) + Data([0xA0, 0x82, 0x0D, 0xF0, 0x00])
    }

    @Test func readsFreeAccountProfile() throws {
        let d = try #require(AppExpiry.dates(profile: Self.profile(created: "2026-11-18T10:00:00Z", expires: "2026-11-25T10:00:00Z")))
        #expect(d.expires == Self.date("2026-11-25T10:00:00Z"))
        #expect(d.created == Self.date("2026-11-18T10:00:00Z"))
        #expect(d.shortLived)
    }

    @Test func paidProfileIsNotShortLived() throws {
        let d = try #require(AppExpiry.dates(profile: Self.profile(created: "2026-11-18T10:00:00Z", expires: "2027-11-18T10:00:00Z")))
        #expect(!d.shortLived)
    }

    @Test func notAProfile() {
        #expect(AppExpiry.dates(profile: Data()) == nil)
        #expect(AppExpiry.dates(profile: Data("<?xml no end".utf8)) == nil)
        #expect(AppExpiry.dates(profile: Data("<?xml version=\"1.0\"?><plist><dict></dict></plist>".utf8)) == nil)
    }

    @Test func warningCountsCalendarDays() {
        let expires = Self.date("2026-11-25T10:00:00Z")
        #expect(AppExpiry.warning(expires: expires, now: Self.date("2026-11-18T12:00:00Z"), calendar: Self.utc) == .none)
        #expect(AppExpiry.warning(expires: expires, now: Self.date("2026-11-22T00:00:00Z"), calendar: Self.utc) == .soon(days: 3))
        #expect(AppExpiry.warning(expires: expires, now: Self.date("2026-11-24T23:59:00Z"), calendar: Self.utc) == .soon(days: 1))
        #expect(AppExpiry.warning(expires: expires, now: Self.date("2026-11-25T08:00:00Z"), calendar: Self.utc) == .today)
        #expect(AppExpiry.warning(expires: expires, now: Self.date("2026-11-25T10:00:00Z"), calendar: Self.utc) == .expired)
    }

    @Test func reminderIsTheDayBeforeAtNine() {
        let expires = Self.date("2026-11-25T10:00:00Z")
        #expect(AppExpiry.reminderDate(expires: expires, now: Self.date("2026-11-18T12:00:00Z"), calendar: Self.utc) == Self.date("2026-11-24T09:00:00Z"))
        // Past nine the day before: an hour from now.
        let late = Self.date("2026-11-24T20:00:00Z")
        #expect(AppExpiry.reminderDate(expires: expires, now: late, calendar: Self.utc) == late.addingTimeInterval(3600))
        // Less than an hour left, or gone: none.
        #expect(AppExpiry.reminderDate(expires: expires, now: Self.date("2026-11-25T09:30:00Z"), calendar: Self.utc) == nil)
        #expect(AppExpiry.reminderDate(expires: expires, now: Self.date("2026-11-26T00:00:00Z"), calendar: Self.utc) == nil)
    }
}

@Suite("Battery and heat saver")
struct PowerSaverTests {
    @Test func offNeverCaps() {
        #expect(PowerConditions(unplugged: true, lowPowerMode: true, thermal: 3).cap(.off) == 0)
    }

    @Test func autoFollowsPowerAndHeat() {
        #expect(PowerConditions(unplugged: false, lowPowerMode: false, thermal: 0).cap(.auto) == 0)
        #expect(PowerConditions(unplugged: true, lowPowerMode: false, thermal: 0).cap(.auto) == 60)
        #expect(PowerConditions(unplugged: false, lowPowerMode: false, thermal: 2).cap(.auto) == 60)
        #expect(PowerConditions(unplugged: false, lowPowerMode: true, thermal: 0).cap(.auto) == 30)
        #expect(PowerConditions(unplugged: true, lowPowerMode: false, thermal: 3).cap(.auto) == 30)
    }

    @Test func alwaysIsSixtyOrThirty() {
        #expect(PowerConditions(unplugged: false, lowPowerMode: false, thermal: 0).cap(.always) == 60)
        #expect(PowerConditions(unplugged: false, lowPowerMode: true, thermal: 0).cap(.always) == 30)
        #expect(PowerConditions(unplugged: false, lowPowerMode: false, thermal: 3).cap(.always) == 30)
    }
}
