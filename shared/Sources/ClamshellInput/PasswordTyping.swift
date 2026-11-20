import ClamshellWire

/// Turns text (a password typed into the phone's unlock sheet) into key presses on the Mac: each character
/// becomes the key position that types it in the Mac's current layout, with Shift when needed (ADR-0013 keys
/// go out as positions, so the Mac's layout decides what a position types).
///
/// The Mac's `KeyboardLayout` labels are used first; a US layout is the fallback when the Mac hasn't sent
/// one. Pure logic: nothing here stores or logs the text.
public enum PasswordTyping {
    public struct Press: Equatable, Sendable {
        public var usage: UInt16
        public var shift: Bool
        public init(usage: UInt16, shift: Bool) { self.usage = usage; self.shift = shift }
    }

    /// HID usage of Left Shift and Return.
    public static let leftShift: UInt16 = 0xE1
    public static let returnKey: UInt16 = 0x28

    /// One press per character, or nil and the first character that no key types (so the sheet can say
    /// "type ‘é’ at the Mac's keyboard").
    public static func presses(for text: String, layout: KeyboardLayout?) -> (presses: [Press]?, unmapped: Character?) {
        var out: [Press] = []
        for ch in text {
            guard let p = press(for: ch, layout: layout) else { return (nil, ch) }
            out.append(p)
        }
        return (out, nil)
    }

    public static func press(for ch: Character, layout: KeyboardLayout?) -> Press? {
        let s = String(ch)
        if let layout, !layout.keys.isEmpty {
            // Prefer a key that types it without Shift; letters' labels may be either case.
            if let k = layout.keys.first(where: { $0.base == s }) { return Press(usage: k.usage, shift: false) }
            if let k = layout.keys.first(where: { $0.shifted == s }) { return Press(usage: k.usage, shift: true) }
            if ch == " " { return Press(usage: 0x2C, shift: false) }
            return nil
        }
        return us[s]
    }

    /// US ANSI: a–z, 0–9, space and the punctuation keys, with their shifted symbols.
    static let us: [String: Press] = {
        var m: [String: Press] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            m[String(c)] = Press(usage: 0x04 + UInt16(i), shift: false)
            m[String(c).uppercased()] = Press(usage: 0x04 + UInt16(i), shift: true)
        }
        let digits = Array("1234567890"), shiftedDigits = Array("!@#$%^&*()")
        for i in 0..<10 {
            m[String(digits[i])] = Press(usage: 0x1E + UInt16(i), shift: false)
            m[String(shiftedDigits[i])] = Press(usage: 0x1E + UInt16(i), shift: true)
        }
        let punct: [(UInt16, Character, Character)] = [
            (0x2D, "-", "_"), (0x2E, "=", "+"), (0x2F, "[", "{"), (0x30, "]", "}"), (0x31, "\\", "|"),
            (0x33, ";", ":"), (0x34, "'", "\""), (0x35, "`", "~"), (0x36, ",", "<"), (0x37, ".", ">"), (0x38, "/", "?"),
        ]
        for (u, base, shifted) in punct {
            m[String(base)] = Press(usage: u, shift: false)
            m[String(shifted)] = Press(usage: u, shift: true)
        }
        m[" "] = Press(usage: 0x2C, shift: false)
        return m
    }()
}
