import ClamshellWire
import Testing
@testable import ClamshellInput

@Suite("Key map")
struct KeyMapTests {
    @Test func everyMacBookKeyIsMapped() {
        var usages: [UInt16] = Array(0x04...0x45)              // letters, digits, Return…F12
        usages += [0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52, 0x64]
        usages += Array(0xE0...0xE7) + [HIDUsage.function]
        for u in usages where u != 0x32 || true { #expect(KeyMap.virtualKey(usage: u) != nil, "usage \(u)") }
    }

    @Test func codesAreUniqueExceptKnownAliases() {
        var byCode: [UInt16: [UInt16]] = [:]
        for (u, c) in KeyMap.table { byCode[c, default: []].append(u) }
        let dupes = byCode.filter { $0.value.count > 1 }
        #expect(Set(dupes.keys) == [0x2A], "only \\ and non-US # share kVK_ANSI_Backslash")
    }

    @Test func spotChecks() {
        #expect(KeyMap.virtualKey(usage: 0x04) == 0x00)       // a
        #expect(KeyMap.virtualKey(usage: 0x1D) == 0x06)       // z
        #expect(KeyMap.virtualKey(usage: 0x28) == 0x24)       // Return
        #expect(KeyMap.virtualKey(usage: 0x2A) == 0x33)       // Delete
        #expect(KeyMap.virtualKey(usage: 0x52) == 0x7E)       // ↑
        #expect(KeyMap.virtualKey(usage: 0xE3) == 0x37)       // left ⌘
    }
}

/// Phone sender → (lossy link) → Mac receiver.
@Suite("Input channel")
struct InputChannelTests {
    let ms: UInt64 = 1_000_000

    @Test func messagesRoundTrip() throws {
        let msgs: [InnerMessage] = [
            KeyEvent(seq: 1, usage: 0x04, down: true, modifiers: [.leftShift, .capsLock]).message,
            KeyEvent(seq: 2, page: HIDUsage.consumerPage, usage: MediaKey.volumeUp.rawValue, down: true, modifiers: []).message,
            PointerMove(seq: 3, dx: -40, dy: 17).message,
            PointerMove(seq: 4, dx: 0, dy: 0, absolute: (65535, 12)).message,
            PointerButtonEvent(seq: 5, button: .right, down: true, modifiers: .leftCommand).message,
            ScrollEvent(seq: 6, dx: 0, dy: -160, phase: .ended, velocityX: -5, velocityY: 900).message,
            GestureEvent(seq: 7, kind: .missionControl).message,
            InputState(seq: 8, modifiers: .leftOption, keys: [0x04, 0x05], buttons: .left).message,
            CursorPosition(appliedSeq: 9, x: -3, y: 4000, visible: true, shapeId: 0xDEAD_BEEF).message,
            CursorShape(shapeId: 1, png: [1, 2, 3], hotX: 16, hotY: 32, width: 256, height: 256).message,
        ]
        let decoded = try InnerMessage.decodeAll(InnerMessage.encodeAll(msgs))
        #expect(decoded == msgs)
        #expect(try KeyEvent(decoded[0]).modifiers == [.leftShift, .capsLock])
        #expect(try PointerMove(decoded[2]).dx == -40)
        #expect(try ScrollEvent(decoded[5]).velocityY == 900)
        #expect(try InputState(decoded[7]).keys == [0x04, 0x05])
        #expect(decoded.compactMap(\.inputSeq) == [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    @Test func redundancyCoversALostPacket() {
        var s = InputSender(), r = InputReceiver()
        var actions: [InputAction] = []
        let packets = [s.key(usage: 0x04, down: true, nowNs: 0), s.key(usage: 0x04, down: false, nowNs: 10 * ms),
                       s.key(usage: 0x05, down: true, nowNs: 20 * ms), s.key(usage: 0x05, down: false, nowNs: 30 * ms)]
        for (i, p) in packets.enumerated() where i != 1 { actions += r.receive(p, nowNs: UInt64(i) * 10 * ms) }   // packet 1 lost
        #expect(actions == [.key(code: 0x00, down: true, flags: [], isRepeat: false), .key(code: 0x00, down: false, flags: [], isRepeat: false),
                            .key(code: 0x0B, down: true, flags: [], isRepeat: false), .key(code: 0x0B, down: false, flags: [], isRepeat: false)])
    }

    @Test func globeSwitchesInputSourceOnceAndNeverTypes() {
        var s = InputSender(), r = InputReceiver()
        var actions: [InputAction] = []
        actions += r.receive(s.key(usage: HIDUsage.nextInputSource, down: true, page: HIDUsage.clamshellPage, nowNs: 0), nowNs: 0)
        actions += r.receive(s.key(usage: HIDUsage.nextInputSource, down: false, page: HIDUsage.clamshellPage, nowNs: ms), nowNs: ms)
        actions += r.receive(s.key(usage: 0x04, down: true, page: 0xFF00, nowNs: 2 * ms), nowNs: 2 * ms)   // another vendor page: ignored
        #expect(actions == [.nextInputSource])
        #expect(r.heldKeys.isEmpty)
    }

    @Test func aLostModifierUpIsReconciledByTheNextKey() {
        var r = InputReceiver()
        _ = r.receive([KeyEvent(seq: 1, usage: 0xE3, down: true, modifiers: .leftCommand).message], nowNs: 0)
        #expect(r.modifiers == .leftCommand)
        // ⌘-up (seq 2) and its copies are lost; the next key says nothing is held.
        let a = r.receive([KeyEvent(seq: 3, usage: 0x04, down: true, modifiers: []).message], nowNs: ms)
        #expect(a == [.key(code: 0x37, down: false, flags: [], isRepeat: false), .key(code: 0x00, down: true, flags: [], isRepeat: false)])
    }

    @Test func modifierFlagsTravelWithKeys() {
        var s = InputSender(), r = InputReceiver()
        var a = r.receive(s.key(usage: 0xE1, down: true, nowNs: 0), nowNs: 0)
        a += r.receive(s.key(usage: 0x04, down: true, nowNs: ms), nowNs: ms)
        #expect(a == [.key(code: 0x38, down: true, flags: .leftShift, isRepeat: false), .key(code: 0x00, down: true, flags: .leftShift, isRepeat: false)])
    }

    @Test func reorderedOldEventDoesNotUndoANewerOne() {
        var r = InputReceiver()
        _ = r.receive([KeyEvent(seq: 1, usage: 0x04, down: true, modifiers: []).message], nowNs: 0)
        _ = r.receive([KeyEvent(seq: 3, usage: 0x04, down: false, modifiers: []).message], nowNs: ms)
        let late = r.receive([KeyEvent(seq: 2, usage: 0x04, down: true, modifiers: []).message], nowNs: 2 * ms)
        #expect(late.isEmpty)
        #expect(r.heldKeys.isEmpty)
    }

    @Test func watchdogReleasesAfterTwoSecondsOfSilence() {
        var r = InputReceiver()
        _ = r.receive([KeyEvent(seq: 1, usage: 0xE3, down: true, modifiers: .leftCommand).message,
                       PointerButtonEvent(seq: 2, button: .left, down: true, modifiers: .leftCommand).message], nowNs: 0)
        #expect(r.tick(nowNs: 1_900 * ms).isEmpty)
        let a = r.tick(nowNs: 2_100 * ms)
        #expect(a.contains(.button(.left, down: false, clickCount: 1, flags: .leftCommand)))
        #expect(a.contains(.key(code: 0x37, down: false, flags: [], isRepeat: false)))
        #expect(r.modifiers.isEmpty && r.buttons.isEmpty)
    }

    @Test func heartbeatKeepsAHeldKeyAliveAndSenderSendsIt() {
        var s = InputSender(), r = InputReceiver()
        _ = r.receive(s.key(usage: 0xE2, down: true, nowNs: 0), nowNs: 0)
        var t: UInt64 = 0
        while t < 3_000 * ms {
            t += 10 * ms
            let p = s.tick(nowNs: t)
            if !p.isEmpty { _ = r.receive(p, nowNs: t) }
            #expect(!r.tick(nowNs: t).contains(.key(code: 0x3A, down: false, flags: [], isRepeat: false)))
        }
        #expect(r.modifiers == .leftOption)
    }

    @Test func inputStateReleasesAStuckKey() {
        var r = InputReceiver()
        _ = r.receive([KeyEvent(seq: 1, usage: 0x04, down: true, modifiers: []).message], nowNs: 0)
        let a = r.receive([InputState(seq: 5, modifiers: [], keys: [], buttons: []).message], nowNs: ms)
        #expect(a == [.key(code: 0x00, down: false, flags: [], isRepeat: false)])
    }

    @Test func keyRepeatsOnTheMacSchedule() {
        var cfg = InputConfig(initialKeyRepeatTicks: 15, keyRepeatTicks: 2, doubleClickSeconds: nil, naturalScroll: nil)
        cfg.watchdogNs = 10_000_000_000
        var r = InputReceiver(config: cfg)
        _ = r.receive([KeyEvent(seq: 1, usage: 0x2A, down: true, modifiers: []).message], nowNs: 0)
        var repeats = 0
        var t: UInt64 = 0
        while t < 1_000 * ms { t += 5 * ms; repeats += r.tick(nowNs: t).count }
        // first after 225 ms, then every 30 ms: (1000 - 225) / 30 + 1 ≈ 26
        #expect((24...27).contains(repeats))
        _ = r.receive([KeyEvent(seq: 2, usage: 0x2A, down: false, modifiers: []).message], nowNs: t)
        #expect(r.tick(nowNs: t + 500 * ms).isEmpty)
    }

    @Test func doubleClickCounts() {
        var r = InputReceiver()
        var a: [InputAction] = []
        for (i, t) in [0, 100, 200, 300].enumerated() {
            a += r.receive([PointerButtonEvent(seq: UInt32(i + 1), button: .left, down: i % 2 == 0).message], nowNs: UInt64(t) * ms)
        }
        #expect(a[0] == .button(.left, down: true, clickCount: 1, flags: []))
        #expect(a[2] == .button(.left, down: true, clickCount: 2, flags: []))
        _ = r.receive([PointerMove(seq: 9, dx: 400, dy: 0).message], nowNs: 350 * ms)
        let far = r.receive([PointerButtonEvent(seq: 10, button: .left, down: true).message], nowNs: 400 * ms)
        #expect(far == [.button(.left, down: true, clickCount: 1, flags: [])])
    }

    @Test func scrollMomentumDecaysAndEnds() {
        var r = InputReceiver()
        var a = r.receive([ScrollEvent(seq: 1, dx: 0, dy: 160, phase: .began).message,
                           ScrollEvent(seq: 2, dx: 0, dy: 320, phase: .changed).message,
                           ScrollEvent(seq: 3, dx: 0, dy: 0, phase: .ended, velocityX: 0, velocityY: 1500).message], nowNs: 0)
        #expect(a.map(\.scrollPhase) == [.began, .changed, .ended])
        if case .scroll(_, let dy, _, _, _) = a[1] { #expect(dy == 20) }
        a = []
        var t: UInt64 = 0
        while t < 4_000 * ms { t += 8 * ms; a += r.tick(nowNs: t) }
        let phases = a.compactMap(\.momentumPhase)
        #expect(phases.first == .begin)
        #expect(phases.last == .end)
        #expect(phases.filter { $0 == .begin }.count == 1)
        let total = a.reduce(0.0) { if case .scroll(_, let dy, _, _, _) = $1 { return $0 + dy }; return $0 }
        #expect(total > 200 && total < 600)                     // ≈ v / (-ln 0.997 · 1000) ≈ 500 pt
    }

    @Test func traditionalScrollingInverts() {
        var r = InputReceiver(config: InputConfig(initialKeyRepeatTicks: nil, keyRepeatTicks: nil, doubleClickSeconds: nil, naturalScroll: false))
        let a = r.receive([ScrollEvent(seq: 1, dx: 16, dy: 32, phase: .began).message], nowNs: 0)
        #expect(a == [.scroll(dx: -1, dy: -2, phase: .began, momentum: .none, flags: [])])
    }

    @Test func mediaKeys() {
        var r = InputReceiver()
        let a = r.receive([KeyEvent(seq: 1, page: HIDUsage.consumerPage, usage: MediaKey.mute.rawValue, down: true, modifiers: []).message], nowNs: 0)
        #expect(a == [.media(.mute, down: true)])
    }

    @Test func stickyModifiers() {
        var s = StickyModifiers()
        var e = s.tap(0xE3, nowNs: 0); #expect(e == .down)
        #expect(s.state(0xE3) == .latched)
        var r = s.keyReleased(); #expect(r == [0xE3])
        #expect(s.state(0xE3) == .off)
        e = s.tap(0xE3, nowNs: 1_000 * ms); #expect(e == .down)
        e = s.tap(0xE3, nowNs: 1_200 * ms); #expect(e == StickyModifiers.Effect.none)   // double tap: locked
        r = s.keyReleased(); #expect(r.isEmpty)
        e = s.tap(0xE3, nowNs: 3_000 * ms); #expect(e == .up)
    }

    @Test func dedupeWindow() {
        var d = InputDeduper()
        let a = [d.accept(10), d.accept(10), d.accept(8)]
        #expect(a == [true, false, true])                       // a late but unseen number still counts
        var w = InputDeduper()
        let b = [w.accept(UInt32.max), w.accept(0), w.accept(UInt32.max)]
        #expect(b == [true, true, false])                       // wraps
    }
}

extension InputAction {
    var scrollPhase: ScrollPhase? { if case .scroll(_, _, let p, let m, _) = self, m == .none { return p }; return nil }
    var momentumPhase: MomentumPhase? { if case .scroll(_, _, _, let m, _) = self, m != .none { return m }; return nil }
}

@Suite("Trackpad")
struct TrackpadTests {
    typealias P = [Int: (x: Double, y: Double)]

    func run(_ frames: [(Double, P)], settings: TrackpadInterpreter.Settings = .init()) -> [TrackpadOutput] {
        var t = TrackpadInterpreter(settings: settings)
        var out: [TrackpadOutput] = []
        for (time, p) in frames { out += t.tick(at: time); out += t.update(p, at: time) }
        return out
    }

    @Test func tapClicks() {
        let out = run([(0, [1: (100, 100)]), (0.08, [1: (101, 100)]), (0.12, [:])])
        #expect(out == [.button(.left, down: true), .button(.left, down: false), .haptic(.click)])
    }

    @Test func twoFingerTapRightClicks() {
        let out = run([(0, [1: (100, 100)]), (0.02, [1: (100, 100), 2: (150, 100)]), (0.1, [:])])
        #expect(out.first == .button(.right, down: true))
    }

    @Test func oneFingerMovesWithAcceleration() {
        var frames: [(Double, P)] = [(0, [1: (0, 0)])]
        for i in 1...10 { frames.append((Double(i) / 120, [1: (Double(i) * 10, 0)])) }    // 1200 pt/s
        frames.append((0.2, [:]))
        let out = run(frames)
        let dx = out.reduce(0.0) { if case .move(let x, _) = $1 { return $0 + x }; return $0 }
        #expect(dx > 100 * 2)                                   // fast motion is amplified
        #expect(!out.contains(.button(.left, down: true)))
        let slow = run([(0, [1: (0, 0)]), (0.1, [1: (5, 0)]), (0.2, [1: (10, 0)]), (0.3, [1: (15, 0)]), (0.4, [:])])
        let sdx = slow.reduce(0.0) { if case .move(let x, _) = $1 { return $0 + x }; return $0 }
        #expect(abs(sdx - 15) < 0.5)                            // precision zone: 1:1
    }

    @Test func twoFingerScrollHasPhasesAndVelocity() {
        var frames: [(Double, P)] = [(0, [1: (100, 300), 2: (160, 300)])]
        for i in 1...12 { let y = 300 - Double(i) * 15; frames.append((Double(i) / 120, [1: (100, y), 2: (160, y)])) }
        frames.append((13.0 / 120, [:]))
        let out = run(frames)
        let phases: [ScrollPhase] = out.compactMap { if case .scroll(_, _, let p, _, _) = $0 { return p }; return nil }
        #expect(phases.first == .began)
        #expect(phases.last == .ended)
        if case .scroll(_, _, .ended, _, let vy) = out.last! { #expect(vy < -1500) } else { Issue.record("no end") }
    }

    @Test func threeFingerSwipes() {
        let right = run([(0, [1: (100, 100), 2: (140, 100), 3: (180, 100)]), (0.05, [1: (170, 100), 2: (210, 100), 3: (250, 100)]), (0.1, [:])])
        #expect(right == [.gesture(.spaceLeft)])
        let up = run([(0, [1: (100, 300), 2: (140, 300), 3: (180, 300)]), (0.05, [1: (100, 220), 2: (140, 220), 3: (180, 220)]), (0.1, [:])])
        #expect(up == [.gesture(.missionControl)])
    }

    @Test func fourFingerAppSwitcher() {
        let p = { (x: Double) -> P in [1: (x, 100), 2: (x + 30, 100), 3: (x + 60, 100), 4: (x + 90, 100)] }
        let out = run([(0, p(100)), (0.05, p(150)), (0.1, p(240)), (0.15, p(330)), (0.3, [:])])
        #expect(out.filter { $0 != .haptic(.step) } == [.gesture(.appSwitcherBegin), .gesture(.appSwitcherNext), .gesture(.appSwitcherNext), .gesture(.appSwitcherEnd)])
    }

    @Test func holdThenDrag() {
        let out = run([(0, [1: (100, 100)]), (0.2, [1: (100, 100)]), (0.45, [1: (101, 100)]), (0.5, [1: (140, 100)]), (0.6, [:])])
        #expect(out.prefix(2) == [.button(.left, down: true), .haptic(.dragStart)])
        #expect(out.contains { if case .move = $0 { return true }; return false })
        #expect(out.last == .button(.left, down: false))
    }

    @Test func pinchZooms() {
        let out = run([(0, [1: (200, 200), 2: (260, 200)]), (0.05, [1: (170, 200), 2: (290, 200)]), (0.1, [1: (140, 200), 2: (320, 200)]), (0.2, [:])])
        #expect(out.contains(.gesture(.zoomIn)))
        #expect(!out.contains { if case .scroll = $0 { return true }; return false })
    }
}

@Suite("Bulk transfers")
struct BulkTests {
    @Test func bigMessageSurvivesLossAndDuplicates() throws {
        var s = BulkSender(), r = BulkReceiver()
        let big = ClipboardOffer(items: [ClipboardItem(uti: "public.utf8-plain-text", data: Array(repeating: 0x41, count: 5_500))], changeCount: 3)
        let first = s.send(big.message, nowNs: 0)
        #expect(first.count == 6)
        var completed: InnerMessage?
        for (i, m) in first.enumerated() where i != 2 && i != 4 {                    // two chunks lost
            let (ack, done) = r.add(try BulkChunk(m), nowNs: 0)
            s.handle(ack)
            if let done { completed = done }
        }
        #expect(completed == nil)
        #expect(s.poll(nowNs: 100_000_000).isEmpty)                                    // not yet time
        let resent = s.poll(nowNs: 200_000_000)
        #expect(resent.count == 2)
        for m in resent { let (ack, done) = r.add(try BulkChunk(m), nowNs: 200_000_000); s.handle(ack); if let done { completed = done } }
        #expect(try ClipboardOffer(#require(completed)) == big)
        #expect(s.pending == 0)
        let dup = r.add(try BulkChunk(first[0]), nowNs: 300_000_000)                   // a late duplicate: re-acked, not redelivered
        #expect(dup.completed == nil && dup.ack.has(5))
    }

    @Test func senderGivesUp() {
        var s = BulkSender()
        _ = s.send(GestureEvent(seq: 1, kind: .zoomIn).message, nowNs: 0)
        var t: UInt64 = 0
        for _ in 0..<40 { t += 200_000_000; _ = s.poll(nowNs: t) }
        #expect(s.pending == 0)
    }
}

@Suite("Bulk window and files (M5)")
struct BulkWindowTests {
    @Test func bigFileGoesThroughTheWindowWithLoss() throws {
        var s = BulkSender(), r = BulkReceiver()
        let data = (0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let offer = FileOffer(name: "photo.heic", sha256: [UInt8](repeating: 1, count: 32), data: data)
        var wire = s.send(offer.message, nowNs: 0)
        #expect(wire.count == BulkSender.window)
        var completed: InnerMessage?
        var t: UInt64 = 0
        var n = 0
        while completed == nil, t < 60_000_000_000 {
            for m in wire {
                n += 1
                if n % 7 == 0 { continue }                                            // 1 in 7 lost
                let (ack, done) = r.add(try BulkChunk(m), nowNs: t)
                if n % 5 != 0 { s.handle(ack) }                                       // some acks lost too
                if let done { completed = done }
            }
            t += 50_000_000
            wire = s.poll(nowNs: t)
        }
        let got = try FileOffer(#require(completed))
        #expect(got.data == data && got.name == "photo.heic")
        for _ in 0..<5 { t += 200_000_000; for m in s.poll(nowNs: t) { s.handle(r.add(try BulkChunk(m), nowNs: t).ack) } }
        #expect(s.pending == 0)
    }

    @Test func progressKeepsASlowTransferAlive() throws {
        var s = BulkSender(), r = BulkReceiver()
        let first = s.send(FileOffer(name: "a", sha256: [UInt8](repeating: 0, count: 32), data: [UInt8](repeating: 9, count: 600_000)).message, nowNs: 0)
        // Only one chunk acked per 150 ms round: far longer than 20 rounds, but never idle.
        var queue = first
        var t: UInt64 = 0
        for _ in 0..<40 {
            if let m = queue.first { s.handle(r.add(try BulkChunk(m), nowNs: t).ack); queue.removeFirst() }
            t += 150_000_000
            queue += s.poll(nowNs: t)
        }
        #expect(s.pending == 1)
    }

    @Test func safeNames() {
        #expect(FileOffer.safeName("../../etc/passwd") == "passwd")
        #expect(FileOffer.safeName(".hidden") == "hidden")
        #expect(FileOffer.safeName("a\u{0}b:c\u{202E}.txt") == "abc.txt")
        #expect(FileOffer.safeName("   ") == "file")
        #expect(FileOffer.safeName("C:\\Users\\x\\report.pdf") == "report.pdf")
        let long = String(repeating: "x", count: 300) + ".png"
        #expect(FileOffer.safeName(long).utf8.count == 200 && FileOffer.safeName(long).hasSuffix(".png"))
    }

    @Test func clipboardPolicy() {
        #expect(ClipboardPolicy.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(!ClipboardPolicy.shouldSkip(types: ["public.utf8-plain-text"]))
        let big = ClipboardItem(uti: "public.utf8-plain-text", data: [UInt8](repeating: 1, count: ClipboardPolicy.maxTextBytes + 1))
        let ok = ClipboardItem(uti: "public.png", data: [1, 2, 3])
        #expect(ClipboardPolicy.filter([big, ok]) == [ok])
    }
}
