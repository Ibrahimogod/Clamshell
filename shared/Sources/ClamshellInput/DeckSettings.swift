/// The deck's settings (Layout › Keyboard & trackpad): how big the keys are, whether the keyboard and the
/// trackpad strip show, how big the strip is, and whether it sits beside the keyboard in laptop posture.
/// Stored as JSON on the phone; fields missing from an older copy take their defaults.
public struct DeckSettings: Codable, Equatable, Sendable {
    /// One key row's height in points (the function row is half of it).
    public static let keyRowRange: ClosedRange<Double> = 36...64
    public static let defaultKeyRow: Double = 48

    public var keyRow: Double
    public var showKeyboard: Bool
    public var showTrackpad: Bool
    /// 0 = smallest … 1 = largest.
    public var trackpadSize: Double
    /// Laptop: the trackpad beside the keyboard instead of below it.
    public var padBesideKeyboard: Bool

    public init(keyRow: Double = DeckSettings.defaultKeyRow, showKeyboard: Bool = true, showTrackpad: Bool = true,
                trackpadSize: Double = 0.6, padBesideKeyboard: Bool = false) {
        self.keyRow = keyRow
        self.showKeyboard = showKeyboard
        self.showTrackpad = showTrackpad
        self.trackpadSize = trackpadSize
        self.padBesideKeyboard = padBesideKeyboard
    }

    /// 1.0.1 had a single "lower half" choice: deck, split (side by side), pad (trackpad only), keys (keyboard only).
    public init(legacyDeckMode: String?) {
        self.init()
        switch legacyDeckMode {
        case "pad": showKeyboard = false
        case "keys": showTrackpad = false
        case "split": padBesideKeyboard = true
        default: break
        }
    }

    private enum CodingKeys: String, CodingKey { case keyRow, showKeyboard, showTrackpad, trackpadSize, padBesideKeyboard }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeckSettings()
        keyRow = try c.decodeIfPresent(Double.self, forKey: .keyRow) ?? d.keyRow
        showKeyboard = try c.decodeIfPresent(Bool.self, forKey: .showKeyboard) ?? d.showKeyboard
        showTrackpad = try c.decodeIfPresent(Bool.self, forKey: .showTrackpad) ?? d.showTrackpad
        trackpadSize = try c.decodeIfPresent(Double.self, forKey: .trackpadSize) ?? d.trackpadSize
        padBesideKeyboard = try c.decodeIfPresent(Bool.self, forKey: .padBesideKeyboard) ?? d.padBesideKeyboard
    }

    private var row: Double { min(max(keyRow, Self.keyRowRange.lowerBound), Self.keyRowRange.upperBound) }
    private var size: Double { min(max(trackpadSize, 0), 1) }

    /// 5.5 rows and 7 gaps of 4 pt, but never more than `limit`.
    public func keyboardHeight(limit: Double) -> Double { min(row * 5.5 + 28, max(limit, 0)) }

    /// Laptop, below the keyboard: the share of the deck's width the trackpad takes (it fills the height left).
    public var trackpadWidthShare: Double { 0.5 + 0.5 * size }

    /// Laptop, beside the keyboard: the trackpad's width in points.
    public var trackpadSideWidth: Double { 160 + 200 * size }

    /// Book, keyboard hidden: the strip's height in points; the Mac's picture gets what is left.
    public func trackpadStripHeight(limit: Double) -> Double { min(80 + 200 * size, max(limit, 0)) }

    /// Book: how wide one keyboard half is on a page `page` points wide, for a half `units` keys wide. Keys stay
    /// MacBook-shaped (about 1.35× as wide as they are tall) at the page's outer edge, and the inner part of the
    /// page, by the fold, holds that page's trackpad: 20–45% of the page as the trackpad size goes up.
    public func bookKeyboardWidth(page: Double, units: Double) -> Double {
        let room = showTrackpad ? page * (0.8 - 0.25 * size) : page
        return max(0, min(room, units * row * 1.35 + 4))
    }
}

/// The keyboard split at the fold (book posture): each page holds one half of every row.
public enum KeyboardSplit {
    /// The key widths of one half-row, filled out to `units`: the key next to the fold grows, nothing shrinks.
    /// On the left page the fold is after the last key; on the right page it is before the first.
    public static func fill(_ widths: [Double], to units: Double, foldAtEnd: Bool) -> [Double] {
        guard let i = foldAtEnd ? widths.indices.last : widths.indices.first else { return widths }
        var w = widths
        w[i] += max(0, units - widths.reduce(0, +))
        return w
    }
}
