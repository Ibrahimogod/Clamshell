import Carbon
import ClamshellInput
import ClamshellWire
import Foundation

/// The Mac's keyboard input sources (Text Input Sources): which one is selected, what its keys type, and
/// switching to the next one for 🌐 on the phone. Keys always go out as positions (ADR-0013), so typing in
/// Arabic or English is the Mac's own layout; this only tells the phone what to draw on its keys.
@MainActor
enum KeyboardLayouts {
    /// The keys the phone labels from the layout: letters, digits, punctuation and the ISO § key.
    static let labelledUsages: [UInt16] = Array(0x04...0x27) + Array(0x2D...0x38) + [0x64]

    /// The selected input source, with labels from the keyboard layout under it (an input method such as
    /// Pinyin types through an ASCII layout, so its labels are that layout's).
    static func current() -> KeyboardLayout? {
        guard let selected = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() ?? selected
        var keys: [KeyboardLayout.Key] = []
        if let ptr = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
            data.withUnsafeBytes { raw in
                guard let uc = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
                for usage in labelledUsages {
                    guard let code = KeyMap.virtualKey(usage: usage) else { continue }
                    let base = translate(uc, code, shift: false), shifted = translate(uc, code, shift: true)
                    if !base.isEmpty || !shifted.isEmpty { keys.append(.init(usage: usage, base: base, shifted: shifted)) }
                }
            }
        }
        let languages = array(selected, kTISPropertyInputSourceLanguages) ?? array(layout, kTISPropertyInputSourceLanguages) ?? []
        return KeyboardLayout(id: string(selected, kTISPropertyInputSourceID) ?? "",
                              name: string(selected, kTISPropertyLocalizedName) ?? "",
                              language: languages.first ?? "", keys: keys)
    }

    /// Selects the next enabled keyboard layout or input mode, in the order of the Mac's input menu,
    /// wrapping around (English → Arabic → English with two).
    static func selectNext() {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let all = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        let types: Set<String> = [kTISTypeKeyboardLayout as String, kTISTypeKeyboardInputMode as String]
        let list = all.filter { string($0, kTISPropertyInputSourceType).map(types.contains) ?? false }
        guard list.count > 1 else { print("keyboard: only one input source is enabled; add Arabic in System Settings › Keyboard › Text Input"); return }
        let currentID = TISCopyCurrentKeyboardInputSource().flatMap { string($0.takeRetainedValue(), kTISPropertyInputSourceID) }
        let i = list.firstIndex { string($0, kTISPropertyInputSourceID) == currentID } ?? -1
        let next = list[(i + 1) % list.count]
        let status = TISSelectInputSource(next)
        print("keyboard: switched to \(string(next, kTISPropertyLocalizedName) ?? "?") (\(status == noErr ? "ok" : "error \(status)"))")
    }

    /// Calls `onChange` on the main queue whenever the selected input source changes, from anywhere.
    static func observe(_ onChange: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { onChange() } }
    }

    // MARK: -

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, _ code: UInt16, shift: Bool) -> String {
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), modifiers, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return "" }
        let s = String(utf16CodeUnits: chars, count: length)
        // Control characters (a layout's Return, Delete…) and invisible marks (Arabic's LRM/RLM) are not labels.
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return "" }
        if s.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .format || $0.properties.isWhitespace }) { return "" }
        return s
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    private static func array(_ source: TISInputSource, _ key: CFString) -> [String]? {
        guard let p = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String]
    }
}
