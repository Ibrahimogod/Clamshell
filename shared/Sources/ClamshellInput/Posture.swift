import CoreGraphics

/// How the Duo is held (ADR-0012). Inferred from the hinge, the division region and the scene geometry;
/// there is no posture API.
public enum Posture: String, Sendable, CaseIterable, Codable {
    /// Half open, fold horizontal: the Mac on the top half, the deck on the bottom half.
    case laptop
    /// Half open, fold vertical: two pages side by side.
    case book
    /// Fully open: one big screen, direct touch or trackpad.
    case flat
    /// Closed: the scene is on the cover screen, a glance at the Mac.
    case cover
}

/// What the phone reports, all optional because the simulator and other phones have no hinge.
public struct PostureInputs: Sendable, Equatable {
    public enum Hinge: Sendable, Equatable { case unknown, closed, partiallyOpen, fullyOpen }

    public var hinge: Hinge
    /// The division (fold) region in scene coordinates, if the device reports one (active or not).
    public var division: CGRect?
    /// The scene's bounds.
    public var bounds: CGSize

    public init(hinge: Hinge = .unknown, division: CGRect? = nil, bounds: CGSize) {
        self.hinge = hinge
        self.division = division
        self.bounds = bounds
    }
}

public enum PostureInference {
    /// The pure rule from ADR-0012.
    public static func infer(_ i: PostureInputs) -> Posture {
        switch i.hinge {
        case .closed:
            return .cover
        case .fullyOpen:
            return .flat
        case .partiallyOpen:
            if let d = i.division, d.width > 0 || d.height > 0 { return d.width >= d.height ? .laptop : .book }
            return fallback(i.bounds, folded: true)
        case .unknown:
            if let d = i.division, d.width > 0 || d.height > 0 { return d.width >= d.height ? .laptop : .book }
            return fallback(i.bounds, folded: false)
        }
    }

    /// No hinge: a portrait phone is used like the laptop posture (screen above, deck below); a landscape
    /// one like flat. A half-open hinge with no division region is laptop in portrait, book in landscape.
    static func fallback(_ size: CGSize, folded: Bool) -> Posture {
        let portrait = size.height >= size.width
        if folded { return portrait ? .laptop : .book }
        return portrait ? .laptop : .flat
    }
}

/// Debounce (ADR-0012): the UI follows a new posture once it has held for 150 ms, the Mac's display mode
/// once it has held for 600 ms. A pin overrides inference until it is cleared.
public struct PostureDebouncer: Sendable {
    public static let uiDelayNs: UInt64 = 150_000_000
    public static let displayDelayNs: UInt64 = 600_000_000

    public private(set) var ui: Posture
    public private(set) var display: Posture
    public private(set) var pinned: Posture?
    private var candidate: Posture
    private var since: UInt64

    public init(initial: Posture, nowNs: UInt64) {
        ui = initial
        display = initial
        candidate = initial
        since = nowNs
    }

    /// What layout uses: the pin if set, else the debounced inference.
    public var effective: Posture { pinned ?? ui }

    public mutating func pin(_ p: Posture?) { pinned = p }

    /// Feed a fresh inference. Returns true when `ui` or `display` changed.
    @discardableResult
    public mutating func observe(_ p: Posture, nowNs: UInt64) -> Bool {
        if p != candidate { candidate = p; since = nowNs }
        return tick(nowNs: nowNs)
    }

    /// Call periodically (or after the delays) to let a held candidate through.
    @discardableResult
    public mutating func tick(nowNs: UInt64) -> Bool {
        let held = nowNs &- since
        var changed = false
        if candidate != ui, held >= Self.uiDelayNs { ui = candidate; changed = true }
        if candidate != display, held >= Self.displayDelayNs { display = candidate; changed = true }
        return changed
    }
}

/// What the lower half shows in the laptop posture.
public enum DeckMode: String, Sendable, CaseIterable, Codable {
    case deck    // keyboard + trackpad
    case split   // split keyboard on the sides, trackpad in the middle
    case pad     // trackpad only
    case keys    // keyboard only
}

/// Hardware keyboard remaps (M4). iOS keeps ⌘-Tab and ⌘-Space for itself, so ⌥-Tab and ⌃-Space are sent
/// to the Mac as ⌘-Tab and ⌘-Space. Works on HID usages; the swapped modifier stays ⌘ until it is released.
public struct HardwareKeyRemap: Sendable {
    public var enabled = true
    private var held: Set<UInt16> = []                  // physical modifiers down
    private var swapped: Set<UInt16> = []               // physical modifiers whose press was replaced by ⌘

    public init() {}

    private static let leftOption: UInt16 = 0xE2, rightOption: UInt16 = 0xE6
    private static let leftControl: UInt16 = 0xE0, rightControl: UInt16 = 0xE4
    private static let leftCommand: UInt16 = 0xE3
    private static let tab: UInt16 = 0x2B, space: UInt16 = 0x2C

    public enum Event: Sendable, Equatable { case key(UInt16, down: Bool) }

    /// One physical key change in, the key events to send out.
    public mutating func handle(_ usage: UInt16, down: Bool) -> [Event] {
        if (0xE0...0xE7).contains(usage) {
            if down { held.insert(usage) } else {
                held.remove(usage)
                if swapped.remove(usage) != nil { return [.key(Self.leftCommand, down: false)] }
            }
            return [.key(usage, down: down)]
        }
        guard enabled, down else { return [.key(usage, down: down)] }
        let trigger: UInt16?
        switch usage {
        case Self.tab: trigger = held.first { $0 == Self.leftOption || $0 == Self.rightOption }
        case Self.space: trigger = held.first { $0 == Self.leftControl || $0 == Self.rightControl }
        default: trigger = nil
        }
        guard let mod = trigger else { return [.key(usage, down: true)] }
        var out: [Event] = []
        if !swapped.contains(mod) {
            // Release the real modifier on the Mac and hold ⌘ instead, for as long as the modifier is held,
            // so ⌥-Tab-Tab-Tab walks the switcher like ⌘-Tab-Tab-Tab.
            out.append(.key(mod, down: false))
            out.append(.key(Self.leftCommand, down: true))
            swapped.insert(mod)
        }
        out.append(.key(usage, down: true))
        return out
    }
}
