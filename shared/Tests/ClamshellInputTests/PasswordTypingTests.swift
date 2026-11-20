import ClamshellWire
import Testing
@testable import ClamshellInput

@Suite("Password typing")
struct PasswordTypingTests {
    @Test func usFallback() {
        let r = PasswordTyping.presses(for: "aZ1!_ ?", layout: nil)
        #expect(r.unmapped == nil)
        #expect(r.presses == [
            .init(usage: 0x04, shift: false), .init(usage: 0x1D, shift: true), .init(usage: 0x1E, shift: false),
            .init(usage: 0x1E, shift: true), .init(usage: 0x2D, shift: true), .init(usage: 0x2C, shift: false),
            .init(usage: 0x38, shift: true),
        ])
        #expect(PasswordTyping.presses(for: "0)", layout: nil).presses == [.init(usage: 0x27, shift: false), .init(usage: 0x27, shift: true)])
    }

    @Test func usesTheMacLayout() {
        // A French AZERTY slice: the A position (0x04) types "q", and "1" needs Shift on the top row.
        let layout = KeyboardLayout(id: "com.apple.keylayout.French", name: "French", language: "fr", keys: [
            .init(usage: 0x04, base: "q", shifted: "Q"), .init(usage: 0x14, base: "a", shifted: "A"),
            .init(usage: 0x1E, base: "&", shifted: "1"),
        ])
        let r = PasswordTyping.presses(for: "aQ1 ", layout: layout)
        #expect(r.presses == [.init(usage: 0x14, shift: false), .init(usage: 0x04, shift: true), .init(usage: 0x1E, shift: true), .init(usage: 0x2C, shift: false)])
    }

    @Test func reportsWhatCantBeTyped() {
        let r = PasswordTyping.presses(for: "abé", layout: nil)
        #expect(r.presses == nil)
        #expect(r.unmapped == "é")
    }
}
