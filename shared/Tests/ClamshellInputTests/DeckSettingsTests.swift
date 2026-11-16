import Foundation
import Testing
@testable import ClamshellInput

@Suite("Deck settings")
struct DeckSettingsTests {
    @Test func defaultKeysAreBiggerThanBefore() {
        // 1.0.1 drew the keyboard at most 260 pt high: 42 pt rows.
        #expect(DeckSettings().keyboardHeight(limit: 1000) > 260)
        #expect(DeckSettings(keyRow: 36).keyboardHeight(limit: 1000) == 36 * 5.5 + 28)
    }

    @Test func sizesStayInRange() {
        #expect(DeckSettings(keyRow: 500).keyboardHeight(limit: 1000) == 64 * 5.5 + 28)
        #expect(DeckSettings(keyRow: 48).keyboardHeight(limit: 200) == 200)
        #expect(DeckSettings(trackpadSize: -3).trackpadWidthShare == 0.5)
        #expect(DeckSettings(trackpadSize: 9).trackpadWidthShare == 1)
        #expect(DeckSettings(trackpadSize: 1).trackpadStripHeight(limit: 150) == 150)
        #expect(DeckSettings(trackpadSize: 0).trackpadStripHeight(limit: 1000) == 80)
    }

    @Test func olderCopiesKeepTheirChoice() throws {
        #expect(DeckSettings(legacyDeckMode: "pad").showKeyboard == false)
        #expect(DeckSettings(legacyDeckMode: "keys").showTrackpad == false)
        #expect(DeckSettings(legacyDeckMode: "split").padBesideKeyboard)
        #expect(DeckSettings(legacyDeckMode: nil) == DeckSettings())
        let partial = try JSONDecoder().decode(DeckSettings.self, from: Data(#"{"keyRow":40}"#.utf8))
        #expect(partial.keyRow == 40 && partial.showTrackpad && partial.trackpadSize == 0.6)
        let s = DeckSettings(keyRow: 52, showKeyboard: false, showTrackpad: true, trackpadSize: 0.2, padBesideKeyboard: true)
        #expect(try JSONDecoder().decode(DeckSettings.self, from: JSONEncoder().encode(s)) == s)
    }

    /// A 667-point page: the keys keep their shape instead of stretching to 90 pt, and the trackpad gets the rest.
    @Test func bookKeysStayMacBookShaped() {
        let d = DeckSettings()
        let left = d.bookKeyboardWidth(page: 667, units: 7.25)
        #expect(left <= 7.25 * 48 * 1.35 + 4 && left >= 667 * 0.5)
        #expect(667 - left >= 667 * 0.3)                                    // the trackpad's share at the default size
        #expect(DeckSettings(trackpadSize: 1).bookKeyboardWidth(page: 667, units: 7.25) < left)
        // No trackpad: the keys still don't stretch past their shape.
        #expect(DeckSettings(showTrackpad: false).bookKeyboardWidth(page: 667, units: 7.25) == 7.25 * 48 * 1.35 + 4)
    }

    @Test func splitRowsGrowTheKeyAtTheFold() {
        // Left page "tab q w e r t" (6.5 units) filled to 7.25: t grows.
        #expect(KeyboardSplit.fill([1.5, 1, 1, 1, 1, 1], to: 7.25, foldAtEnd: true) == [1.5, 1, 1, 1, 1, 1.75])
        // Right page "h j k l ; ' return" (7.75) filled to 8: h grows.
        #expect(KeyboardSplit.fill([1, 1, 1, 1, 1, 1, 1.75], to: 8, foldAtEnd: false) == [1.25, 1, 1, 1, 1, 1, 1.75])
        // Never shrinks, and an empty row stays empty.
        #expect(KeyboardSplit.fill([2, 2], to: 3, foldAtEnd: true) == [2, 2])
        #expect(KeyboardSplit.fill([], to: 3, foldAtEnd: true).isEmpty)
    }
}
