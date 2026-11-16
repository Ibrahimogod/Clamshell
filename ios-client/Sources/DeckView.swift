import ClamshellInput
import ClamshellWire
import SwiftUI
import UIKit

/// "Shell & Ember" palette for the deck.
enum DeckStyle {
    static let base = UIColor(red: 0.075, green: 0.078, blue: 0.09, alpha: 1)
    static let key = UIColor(red: 0.16, green: 0.165, blue: 0.185, alpha: 1)
    static let keyDown = UIColor(red: 0.30, green: 0.31, blue: 0.34, alpha: 1)
    static let label = UIColor(white: 0.9, alpha: 1)
    static let dim = UIColor(white: 0.6, alpha: 1)
    static let ember = UIColor(red: 1.0, green: 0.48, blue: 0.2, alpha: 1)
    static let pad = UIColor(red: 0.12, green: 0.125, blue: 0.14, alpha: 1)
}

/// One key on the deck. `usage` 0 = a special action.
struct DeckKey {
    enum Kind { case normal, modifier, media(MediaKey?, fKey: UInt16), lock, fn }
    let label: String
    let usage: UInt16
    let width: CGFloat           // in key units
    var kind: Kind = .normal
    var shifted: String? = nil

    func resized(_ w: CGFloat) -> DeckKey { DeckKey(label: label, usage: usage, width: w, kind: kind, shifted: shifted) }
}

/// Which part of the keyboard a deck view shows: all of it, or one page's half in book posture.
enum KeyboardHalf { case whole, left, right }

/// fn, caps lock and sticky modifiers, shared by the two halves of a split keyboard so 🌐 on the left page
/// turns the right page's top row into F-keys, and so on. Any change redraws both halves.
@MainActor
final class KeyboardState {
    static let changed = Notification.Name("KeyboardState.changed")
    var fnHeld = false
    var fnSent = false
    var capsOn = false
    var sticky = StickyModifiers()
    func changed() { NotificationCenter.default.post(name: Self.changed, object: self) }
}

/// The fold between the two pages in book posture, in a deck view's own coordinates: nothing goes there.
struct FoldGap: Equatable {
    var x: CGFloat
    var width: CGFloat
}

/// The MacBook ANSI layout, 14.5 units wide; the function row is half height.
enum DeckLayout {
    static func k(_ l: String, _ u: UInt16, _ w: CGFloat = 1, shifted: String? = nil) -> DeckKey { DeckKey(label: l, usage: u, width: w, shifted: shifted) }
    static func m(_ l: String, _ u: UInt16, _ w: CGFloat) -> DeckKey { DeckKey(label: l, usage: u, width: w, kind: .modifier) }
    static func f(_ n: Int, _ media: MediaKey?, _ glyph: String) -> DeckKey {
        DeckKey(label: glyph, usage: 0, width: 13.0 / 12.0 * 0.923, kind: .media(media, fKey: UInt16(0x3A + n - 1)), shifted: "F\(n)")
    }

    static let functionRow: [DeckKey] = [
        k("esc", 0x29, 1.5),
        f(1, .brightnessDown, "☀︎−"), f(2, .brightnessUp, "☀︎+"), f(3, .missionControl, "▦"), f(4, .spotlight, "⌕"),
        f(5, nil, "F5"), f(6, nil, "F6"), f(7, .previous, "◁◁"), f(8, .play, "▷‖"), f(9, .next, "▷▷"),
        f(10, .mute, "🔇"), f(11, .volumeDown, "🔉"), f(12, .volumeUp, "🔊"),
        DeckKey(label: "🔒", usage: 0, width: 1, kind: .lock),
    ]

    static let rows: [[DeckKey]] = [
        [k("`", 0x35, shifted: "~"), k("1", 0x1E, shifted: "!"), k("2", 0x1F, shifted: "@"), k("3", 0x20, shifted: "#"), k("4", 0x21, shifted: "$"),
         k("5", 0x22, shifted: "%"), k("6", 0x23, shifted: "^"), k("7", 0x24, shifted: "&"), k("8", 0x25, shifted: "*"), k("9", 0x26, shifted: "("),
         k("0", 0x27, shifted: ")"), k("-", 0x2D, shifted: "_"), k("=", 0x2E, shifted: "+"), k("delete", 0x2A, 1.5)],
        [k("tab", 0x2B, 1.5)] + "qwertyuiop".map { k(String($0), letter($0)) } +
            [k("[", 0x2F, shifted: "{"), k("]", 0x30, shifted: "}"), k("\\", 0x31, shifted: "|")],
        [k("caps", 0x39, 1.75)] + "asdfghjkl".map { k(String($0), letter($0)) } +
            [k(";", 0x33, shifted: ":"), k("'", 0x34, shifted: "\""), k("return", 0x28, 1.75)],
        [m("shift", 0xE1, 2.25)] + "zxcvbnm".map { k(String($0), letter($0)) } +
            [k(",", 0x36, shifted: "<"), k(".", 0x37, shifted: ">"), k("/", 0x38, shifted: "?"), m("shift", 0xE5, 2.25)],
    ]

    /// The bottom row; the arrows (3 units) are laid out separately as an inverted T.
    static let bottom: [DeckKey] = [
        DeckKey(label: "🌐", usage: HIDUsage.function, width: 1, kind: .fn), m("⌃", 0xE0, 1), m("⌥", 0xE2, 1), m("⌘", 0xE3, 1.25),
        k("", 0x2C, 5), m("⌘", 0xE7, 1.25), m("⌥", 0xE6, 1),
    ]

    static func letter(_ c: Character) -> UInt16 { UInt16(c.asciiValue.map { $0 - 97 + 0x04 } ?? 0x04) }

    /// What one keyboard area holds: the rows, how many key units wide it is, and whether the arrows follow
    /// the bottom row.
    struct Plan {
        let function: [DeckKey]
        let rows: [[DeckKey]]
        let bottom: [DeckKey]
        let units: CGFloat
        let arrows: Bool
    }

    /// The whole MacBook keyboard; the function row fills the width exactly.
    static let whole = Plan(function: stretched(functionRow, to: 14.5), rows: rows, bottom: bottom, units: 14.5, arrows: true)

    /// Book posture: the keyboard split at the fold where a split MacBook keyboard would be (after 6, T, G, B
    /// and F6). Each half gets its own space bar; the key next to the fold grows so every row fills its page.
    static func half(left: Bool) -> Plan {
        let units: CGFloat = left ? 7.25 : 8
        let counts = [7, 6, 6, 6]                    // keys on the left page: ` to 6, tab to T, caps to G, shift to B
        let rows = zip(rows, counts).map { r, n in fill(left ? Array(r.prefix(n)) : Array(r.dropFirst(n)), to: units, foldAtEnd: left) }
        let space = k("", 0x2C, 2.5)
        let bottomRow = left ? Array(bottom.prefix(4)) + [space] : [space] + Array(bottom.suffix(2))
        let fRow = left ? Array(functionRow.prefix(7)) : Array(functionRow.dropFirst(7))
        return Plan(function: stretched(fRow, to: units), rows: rows,
                    bottom: fill(bottomRow, to: left ? units : units - 3, foldAtEnd: left), units: units, arrows: !left)
    }

    private static func fill(_ keys: [DeckKey], to units: CGFloat, foldAtEnd: Bool) -> [DeckKey] {
        let w = KeyboardSplit.fill(keys.map { Double($0.width) }, to: Double(units), foldAtEnd: foldAtEnd)
        return zip(keys, w).map { $0.resized(CGFloat($1)) }
    }

    private static func stretched(_ keys: [DeckKey], to units: CGFloat) -> [DeckKey] {
        let total = keys.reduce(0) { $0 + $1.width }
        return total > 0 ? keys.map { $0.resized($0.width * units / total) } : keys
    }
}

/// The keyboard: physical keys under each finger (a key stays the key it was touched on, no sliding),
/// with a light haptic on key-down. Media keys by default on the top row, F-keys with fn.
final class KeyboardDeckView: UIView {
    var input: InputClient? {
        didSet {
            guard input !== oldValue else { return }
            if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver) }
            layoutObserver = input.map { ic in
                NotificationCenter.default.addObserver(forName: InputClient.layoutChanged, object: ic, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setNeedsDisplay() }
                }
            }
            setNeedsDisplay()
        }
    }
    private var layoutObserver: NSObjectProtocol?
    /// 🌐 with a 1.6 Mac: tapped alone it switches the Mac's input source; held with another key it is fn.
    /// So fn reaches the Mac only once another key goes down while it's held.
        var sticky = UserDefaults.standard.bool(forKey: "stickyModifiers")
    /// Book posture: this view holds one half of the split keyboard.
    var half: KeyboardHalf = .whole { didSet { if half != oldValue { setNeedsLayout() } } }
    /// fn, caps lock and sticky modifiers; the two halves of a split keyboard share one.
    var state = KeyboardState() {
        didSet {
            guard state !== oldValue else { return }
            observeState()
            setNeedsDisplay()
        }
    }
    private var stateObserver: NSObjectProtocol?

    private func observeState() {
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
        stateObserver = NotificationCenter.default.addObserver(forName: KeyboardState.changed, object: state, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsDisplay() }
        }
    }

    private struct Placed { let key: DeckKey; let frame: CGRect }
    private var placed: [Placed] = []
    private var down: [ObjectIdentifier: (Placed, usage: UInt16, page: UInt16)] = [:]
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = DeckStyle.base
        contentMode = .redraw
        observeState()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layout()
        setNeedsDisplay()
    }

    private func layout() {
        placed.removeAll()
        switch half {
        case .whole: place(DeckLayout.whole, in: bounds)
        case .left: place(DeckLayout.half(left: true), in: bounds)
        case .right: place(DeckLayout.half(left: false), in: bounds)
        }
    }

    private func place(_ plan: DeckLayout.Plan, in area: CGRect) {
        let gap: CGFloat = 4
        let unit = (area.width - gap) / plan.units
        let rowH = (area.height - gap * 7) / 5.5
        var y = area.minY + gap
        /// Lays out one row and returns where it ends.
        @discardableResult func row(_ keys: [DeckKey], height: CGFloat) -> CGFloat {
            var x = area.minX + gap
            for k in keys {
                let w = k.width * unit - gap
                placed.append(Placed(key: k, frame: CGRect(x: x, y: y, width: w, height: height)))
                x += k.width * unit
            }
            y += height + gap
            return x
        }
        row(plan.function, height: rowH / 2)
        for r in plan.rows { row(r, height: rowH) }
        let bottomY = y
        let ax = row(plan.bottom, height: rowH)
        guard plan.arrows else { return }
        // Inverted-T arrows in the last 3 units.
        let half = (rowH - gap) / 2, aw = unit - gap
        placed.append(Placed(key: DeckKey(label: "◀", usage: 0x50, width: 1), frame: CGRect(x: ax, y: bottomY + half + gap, width: aw, height: half)))
        placed.append(Placed(key: DeckKey(label: "▲", usage: 0x52, width: 1), frame: CGRect(x: ax + unit, y: bottomY, width: aw, height: half)))
        placed.append(Placed(key: DeckKey(label: "▼", usage: 0x51, width: 1), frame: CGRect(x: ax + unit, y: bottomY + half + gap, width: aw, height: half)))
        placed.append(Placed(key: DeckKey(label: "▶", usage: 0x4F, width: 1), frame: CGRect(x: ax + 2 * unit, y: bottomY + half + gap, width: aw, height: half)))
    }

    override func draw(_ rect: CGRect) {
        let downFrames = Set(down.values.map { $0.0.frame.origin.x * 10_000 + $0.0.frame.origin.y })
        let shift = input?.modifiers.shift ?? false
        for p in placed {
            let isDown = downFrames.contains(p.frame.origin.x * 10_000 + p.frame.origin.y)
            var fill = isDown ? DeckStyle.keyDown : DeckStyle.key
            if case .modifier = p.key.kind, state.sticky.state(p.key.usage) != .off { fill = DeckStyle.ember.withAlphaComponent(0.5) }
            if case .fn = p.key.kind, state.fnHeld { fill = DeckStyle.ember.withAlphaComponent(0.5) }
            fill.setFill()
            UIBezierPath(roundedRect: p.frame, cornerRadius: 5).fill()
            var text = p.key.label
            var corner: String?
            if case .media = p.key.kind, state.fnHeld, let s = p.key.shifted { text = s }
            if shift, let s = p.key.shifted, case .normal = p.key.kind { text = s }
            if p.key.usage >= 0x04 && p.key.usage <= 0x1D, shift || state.capsOn { text = text.uppercased() }
            if case .normal = p.key.kind, let layout = input?.keyboardLayout, let l = layout.label(p.key.usage) {
                let mac = shift ? l.shifted : (state.capsOn ? l.base.uppercased() : l.base)
                if !mac.isEmpty {
                    // A non-Latin layout: keep the English letter small in the corner, for ⌘ shortcuts.
                    if mac.lowercased() != text.lowercased(), !p.key.label.isEmpty, mac.unicodeScalars.contains(where: { $0.value > 0x24F }) {
                        corner = p.key.label
                    }
                    text = Self.displayable(mac)
                }
            }
            if case .fn = p.key.kind, let layout = input?.keyboardLayout { text = "🌐 " + Self.shortName(layout) }
            let small = text.count > 2 || p.frame.height < 30
            let font = UIFont.systemFont(ofSize: small ? min(13, p.frame.height * 0.4) : min(21, p.frame.height * 0.45), weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: DeckStyle.label]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(x: p.frame.midX - size.width / 2, y: p.frame.midY - size.height / 2), withAttributes: attrs)
            if let corner, p.frame.height >= 26 {
                let ca: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: min(9, p.frame.height * 0.25)), .foregroundColor: DeckStyle.dim]
                (corner as NSString).draw(at: CGPoint(x: p.frame.minX + 3, y: p.frame.minY + 2), withAttributes: ca)
            }
            if p.key.usage == 0x39, state.capsOn {
                DeckStyle.ember.setFill()
                UIBezierPath(ovalIn: CGRect(x: p.frame.minX + 6, y: p.frame.minY + 6, width: 5, height: 5)).fill()
            }
        }
    }

    /// A label that is only a combining mark (Arabic harakat on Shift) gets a dotted circle to sit on.
    static func displayable(_ s: String) -> String {
        guard let first = s.unicodeScalars.first,
              [.nonspacingMark, .spacingMark, .enclosingMark].contains(first.properties.generalCategory) else { return s }
        return "\u{25CC}" + s
    }

    /// The layout's short name on 🌐: ع for Arabic, otherwise the language (EN, FR…).
    static func shortName(_ l: KeyboardLayout) -> String {
        let lang = l.language.split(separator: "-").first.map(String.init) ?? ""
        switch lang {
        case "ar": return "ع"
        case "": return String(l.name.prefix(2)).uppercased()
        default: return lang.uppercased()
        }
    }

    private var switchesInputSource: Bool { input?.keyboardLayout != nil }

    private func key(at point: CGPoint) -> Placed? {
        placed.first { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }
    }

    /// What a key sends now: the fn layer turns the top row into F-keys, arrows into Home/End/PgUp/PgDn,
    /// delete into forward delete.
    private func resolve(_ k: DeckKey) -> (usage: UInt16, page: UInt16)? {
        switch k.kind {
        case .media(let media, let fKey):
            if state.fnHeld || media == nil { return (fKey, HIDUsage.keyboardPage) }
            return media.map { ($0.rawValue, HIDUsage.consumerPage) }
        case .lock: return nil
        default:
            guard state.fnHeld else { return (k.usage, HIDUsage.keyboardPage) }
            let fnMap: [UInt16: UInt16] = [0x50: 0x4A, 0x4F: 0x4D, 0x52: 0x4B, 0x51: 0x4E, 0x2A: 0x4C]
            return (fnMap[k.usage] ?? k.usage, HIDUsage.keyboardPage)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let input else { return }
        for t in touches {
            guard let p = key(at: t.location(in: self)) else { continue }
            haptic.impactOccurred(intensity: 0.6)
            if case .lock = p.key.kind {
                input.chord(0x14, modifiers: [0xE0, 0xE3])     // ⌃⌘Q: lock screen
                continue
            }
            if case .fn = p.key.kind {
                state.fnHeld = true
                if switchesInputSource {
                    state.fnSent = false
                    down[ObjectIdentifier(t)] = (p, HIDUsage.function, HIDUsage.keyboardPage)
                    continue
                }
            } else if state.fnHeld, switchesInputSource, !state.fnSent {
                state.fnSent = true
                input.key(HIDUsage.function, down: true)
            }
            if sticky, case .modifier = p.key.kind {
                switch state.sticky.tap(p.key.usage, nowNs: PhoneClock.nowNs()) {
                case .down: input.key(p.key.usage, down: true)
                case .up: input.key(p.key.usage, down: false)
                case .none: break
                }
                continue
            }
            guard let r = resolve(p.key) else { continue }
            if r.usage == HIDUsage.capsLock { state.capsOn.toggle() }
            down[ObjectIdentifier(t)] = (p, r.usage, r.page)
            input.key(r.usage, down: true, page: r.page)
        }
        state.changed()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }

    private func release(_ touches: Set<UITouch>) {
        guard let input else { return }
        for t in touches {
            guard let d = down.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            if case .fn = d.0.key.kind, switchesInputSource {
                state.fnHeld = false
                if state.fnSent {
                    input.key(HIDUsage.function, down: false)
                } else {
                    input.key(HIDUsage.nextInputSource, down: true, page: HIDUsage.clamshellPage)
                    input.key(HIDUsage.nextInputSource, down: false, page: HIDUsage.clamshellPage)
                }
                state.fnSent = false
                continue
            }
            input.key(d.usage, down: false, page: d.page)
            if case .fn = d.0.key.kind { state.fnHeld = false }
            if sticky, case .normal = d.0.key.kind {
                for u in state.sticky.keyReleased() { input.key(u, down: false) }
            }
        }
        state.changed()
    }
}

/// The trackpad area: all touches go to `TrackpadInterpreter`, ticked every frame.
final class TrackpadView: UIView {
    var input: InputClient?
    /// Phone points to Mac points (the Mac display is bigger than this pad).
    var scrollScale: Double = 1.5
    private var interpreter = TrackpadInterpreter()
    /// Over the picture: pinch zooms the phone's view instead of sending ⌘= / ⌘- to the Mac.
    var zoom: PictureZoom? {
        didSet { interpreter.settings.continuousZoom = zoom != nil }
    }
    /// Book posture: the strip splits at the fold into one pad per page. A touch that starts on the fold is
    /// ignored; a finger on each page is still one two-finger gesture.
    var fold: FoldGap? {
        didSet {
            guard fold != oldValue else { return }
            styleForFold()
            setNeedsLayout()
        }
    }
    private let pages = [CALayer(), CALayer()]
    private var ignored: Set<ObjectIdentifier> = []
    private var touchIds: [ObjectIdentifier: Int] = [:]
    private var nextId = 0
    private var link: CADisplayLink?
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = DeckStyle.pad
        layer.cornerRadius = 10
        layer.borderColor = UIColor(white: 1, alpha: 0.06).cgColor
        layer.borderWidth = 1
        for p in pages {
            p.backgroundColor = DeckStyle.pad.cgColor
            p.cornerRadius = 10
            p.borderColor = UIColor(white: 1, alpha: 0.06).cgColor
            p.borderWidth = 1
            p.isHidden = true
            layer.addSublayer(p)
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func styleForFold() {
        let split = fold != nil
        backgroundColor = split ? .clear : DeckStyle.pad
        layer.borderWidth = split ? 0 : 1
        for p in pages { p.isHidden = !split }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let fold else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pages[0].frame = CGRect(x: 0, y: 0, width: max(0, fold.x), height: bounds.height)
        let right = fold.x + fold.width
        pages[1].frame = CGRect(x: right, y: 0, width: max(0, bounds.width - right), height: bounds.height)
        CATransaction.commit()
    }

    private func onFold(_ p: CGPoint) -> Bool {
        guard let fold else { return false }
        return p.x >= fold.x - 4 && p.x <= fold.x + fold.width + 4
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        guard window != nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() { apply(interpreter.tick(at: CACurrentMediaTime())) }

    private func points(_ event: UIEvent?) -> [Int: (x: Double, y: Double)] {
        var out: [Int: (x: Double, y: Double)] = [:]
        for t in event?.allTouches ?? [] where t.view === self && t.phase != .ended && t.phase != .cancelled {
            let id = ObjectIdentifier(t)
            if ignored.contains(id) { continue }
            if touchIds[id] == nil {
                if t.phase == .began, onFold(t.location(in: self)) { ignored.insert(id); continue }
                touchIds[id] = nextId; nextId += 1
            }
            if let i = touchIds[id] { let p = t.location(in: self); out[i] = (Double(p.x), Double(p.y)) }
        }
        return out
    }

    private func update(_ event: UIEvent?, ended: Set<UITouch> = []) {
        let pts = points(event)
        for t in ended { touchIds.removeValue(forKey: ObjectIdentifier(t)); ignored.remove(ObjectIdentifier(t)) }
        apply(interpreter.update(pts, at: CACurrentMediaTime()))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { update(event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update(event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { update(event, ended: touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { update(event, ended: touches) }

    private func apply(_ outs: [TrackpadOutput]) {
        guard let input else { return }
        for o in outs {
            switch o {
            case .move(let dx, let dy):
                // Zoomed in, the same finger travel moves the pointer less, so it stays as precise on screen.
                let k = Double(zoom?.scale ?? 1)
                input.move(dx: dx / k, dy: dy / k)
            case .zoom(let f, let x, let y, let dx, let dy): zoom?.pinch(factor: f, x: x, y: y, dx: dx, dy: dy)
            case .button(let b, let d): input.button(b, down: d)
            case .scroll(let dx, let dy, let phase, let vx, let vy):
                input.scroll(dx: dx * scrollScale, dy: dy * scrollScale, phase: phase, vx: vx * scrollScale, vy: vy * scrollScale)
            case .gesture(let g): input.gesture(g)
            case .haptic(let h):
                switch h {
                case .click: light.impactOccurred()
                case .dragStart: rigid.impactOccurred()
                case .step: light.impactOccurred(intensity: 0.5)
                }
            }
        }
    }
}

struct KeyboardDeck: UIViewRepresentable {
    let input: InputClient
    var half: KeyboardHalf = .whole
    /// Shared by the two halves of a split keyboard.
    var state: KeyboardState?
    func makeUIView(context: Context) -> KeyboardDeckView {
        let v = KeyboardDeckView()
        v.input = input
        v.half = half
        if let state { v.state = state }
        v.isAccessibilityElement = true
        v.accessibilityLabel = "Mac keyboard"
        v.accessibilityTraits = .allowsDirectInteraction
        return v
    }
    func updateUIView(_ v: KeyboardDeckView, context: Context) {
        v.input = input
        v.half = half
        if let state { v.state = state }
    }
}

struct Trackpad: UIViewRepresentable {
    let input: InputClient
    /// Over the picture (trackpad mode): no fill, so the Mac's screen shows through.
    var overlay = false
    /// With `overlay`: pinch zooms the picture on the phone.
    var zoom: PictureZoom?
    /// Book posture: one pad per page.
    var fold: FoldGap?
    func makeUIView(context: Context) -> TrackpadView {
        let v = TrackpadView()
        v.input = input
        v.zoom = zoom
        v.fold = fold
        if overlay { v.backgroundColor = .clear; v.layer.borderWidth = 0; v.layer.cornerRadius = 0 }
        v.isAccessibilityElement = true
        v.accessibilityLabel = overlay ? "Trackpad over the Mac's screen" : "Trackpad"
        v.accessibilityTraits = .allowsDirectInteraction
        return v
    }
    func updateUIView(_ v: TrackpadView, context: Context) { v.input = input; v.fold = fold }
}
