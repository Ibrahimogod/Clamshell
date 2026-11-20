import Foundation
import Testing
@testable import ClamshellWire

/// Golden-byte fixtures for protocol v1.0 (ADR-0011 §4). Each file holds the hex of one encoded
/// inner message. Once committed, a fixture must never change: a new layout gets a new message type
/// and a new fixture. To create fixtures for *new* messages only, run
/// `CLAMSHELL_WRITE_FIXTURES=1 swift test --filter FixtureTests` and review the diff.
@Suite("Fixtures v1.0")
struct FixtureTests {
    struct Sample: Sendable {
        let name: String
        let message: InnerMessage
        let check: @Sendable (InnerMessage) throws -> Bool
    }

    static let hostStats = HostStats(encodeMicros: 7_200, framesSent: 1_000, keyframes: 2, refinements: 40, bytesSent: 25_000_000,
                                     encoderDrops: 3, skippedWhileBusy: 9)

    static let keyboard = KeyboardLayout(id: "com.apple.keylayout.Arabic", name: "Arabic", language: "ar",
                                         keys: [.init(usage: 0x04, base: "ش", shifted: "ِ"), .init(usage: 0x1E, base: "١", shifted: "!")])

    static let samples: [Sample] = [
        Sample(name: "keyboard_layout", message: FixtureTests.keyboard.message) { try KeyboardLayout($0) == FixtureTests.keyboard },
        Sample(name: "hello", message: MessageTests.phoneHello.message) { try Hello($0) == MessageTests.phoneHello },
        Sample(name: "incompatible", message: Incompatible(requiredMajor: 2, peerMajor: 1, hint: .updateMac).message) {
            try Incompatible($0) == Incompatible(requiredMajor: 2, peerMajor: 1, hint: .updateMac)
        },
        Sample(name: "ping", message: Ping(id: 0x0102_0304, t1: 0x1122_3344_5566_7788).message) {
            try Ping($0) == Ping(id: 0x0102_0304, t1: 0x1122_3344_5566_7788)
        },
        Sample(name: "pong", message: Pong(id: 5, t1: 10, t2: 20, t3: 30).message) { try Pong($0) == Pong(id: 5, t1: 10, t2: 20, t3: 30) },
        Sample(name: "goodbye", message: Goodbye(reason: .revoked).message) { try Goodbye($0) == Goodbye(reason: .revoked) },
        Sample(name: "host_stats", message: FixtureTests.hostStats.message) { try HostStats($0) == FixtureTests.hostStats },
        Sample(name: "keyframe_request", message: KeyframeRequest(reason: .frameLost, lastGoodFrameId: 1000).message) {
            try KeyframeRequest($0) == KeyframeRequest(reason: .frameLost, lastGoodFrameId: 1000)
        },
        Sample(name: "video_format", message: FixtureTests.format.message) { try VideoFormat($0) == FixtureTests.format },
        Sample(name: "video_fragment", message: FixtureTests.fragment.message) { try VideoFragment($0) == FixtureTests.fragment },
        // Protocol 1.1 (additive, so they live with the 1.0 set).
        Sample(name: "receiver_report", message: FixtureTests.report.message) { try ReceiverReport($0) == FixtureTests.report },
        Sample(name: "host_state", message: FixtureTests.hostState.message) { try HostState($0) == FixtureTests.hostState },
        // Protocol 1.2: input channel, cursor, host state with input access.
        Sample(name: "host_state_1_2", message: FixtureTests.hostState12.message) { try HostState($0) == FixtureTests.hostState12 },
        Sample(name: "key_event", message: KeyEvent(seq: 300, usage: 0x04, down: true, modifiers: [.leftShift]).message) {
            try KeyEvent($0) == KeyEvent(seq: 300, usage: 0x04, down: true, modifiers: [.leftShift])
        },
        Sample(name: "pointer_move", message: PointerMove(seq: 301, dx: -24, dy: 160).message) { try PointerMove($0) == PointerMove(seq: 301, dx: -24, dy: 160) },
        Sample(name: "pointer_button", message: PointerButtonEvent(seq: 302, button: .left, down: false, modifiers: .leftCommand).message) {
            try PointerButtonEvent($0) == PointerButtonEvent(seq: 302, button: .left, down: false, modifiers: .leftCommand)
        },
        Sample(name: "scroll", message: FixtureTests.scroll.message) { try ScrollEvent($0) == FixtureTests.scroll },
        Sample(name: "gesture", message: GestureEvent(seq: 304, kind: .spaceRight).message) { try GestureEvent($0) == GestureEvent(seq: 304, kind: .spaceRight) },
        Sample(name: "input_state", message: FixtureTests.inputState.message) { try InputState($0) == FixtureTests.inputState },
        Sample(name: "cursor_position", message: FixtureTests.cursor.message) { try CursorPosition($0) == FixtureTests.cursor },
        Sample(name: "cursor_shape", message: FixtureTests.shape.message) { try CursorShape($0) == FixtureTests.shape },
        Sample(name: "clipboard_offer", message: FixtureTests.clip.message) { try ClipboardOffer($0) == FixtureTests.clip },
        Sample(name: "home_endpoint", message: FixtureTests.home.message) {
            let h = try HomeEndpoint($0)
            return h.host == FixtureTests.home.host && h.udpPort == 51820 && h.tcpPort == 443 && h.seq == 7
        },
        Sample(name: "file_offer", message: FileOffer(name: "notes.txt", sha256: [UInt8](repeating: 0xAB, count: 32), data: Array("hi".utf8)).message) {
            let f = try FileOffer($0)
            return f.name == "notes.txt" && f.data == Array("hi".utf8) && f.sha256.count == 32
        },
        Sample(name: "display_mode_request", message: DisplayModeRequest(mode: .flat).message) { try DisplayModeRequest($0).mode == .flat },
        Sample(name: "audio_packet", message: AudioPacket(seq: 7, captureNs: 1_000_000, data: [0xFC, 0xFF, 0xFE]).message) {
            let p = try AudioPacket($0); return p.seq == 7 && p.captureNs == 1_000_000 && p.data == [0xFC, 0xFF, 0xFE]
        },
        // Protocol 1.8: frame-rate cap, window streaming, app expiry, host state with mic/window/fps.
        Sample(name: "frame_rate_request", message: FrameRateRequest(maxFps: 60).message) { try FrameRateRequest($0).maxFps == 60 },
        Sample(name: "window_list_request", message: WindowListRequest().message) { _ = try WindowListRequest($0); return true },
        Sample(name: "window_list", message: FixtureTests.windows.message) { try WindowList($0).windows == FixtureTests.windows.windows },
        Sample(name: "source_request", message: SourceRequest(windowId: 4242, fit: true).message) {
            let r = try SourceRequest($0); return r.windowId == 4242 && r.fit
        },
        Sample(name: "hello_1_8", message: FixtureTests.hello18.message) { try Hello($0) == FixtureTests.hello18 },
        Sample(name: "host_state_1_8", message: FixtureTests.hostState18.message) { try HostState($0) == FixtureTests.hostState18 },
        // Protocol 1.9: resumable files and folders, privacy screen.
        Sample(name: "file_begin", message: FixtureTests.fileBegin.message) { try FileBegin($0) == FixtureTests.fileBegin },
        Sample(name: "file_accept", message: FixtureTests.fileAccept.message) { try FileAccept($0) == FixtureTests.fileAccept },
        Sample(name: "file_segment", message: FixtureTests.fileSegment.message) { try FileSegment($0) == FixtureTests.fileSegment },
        Sample(name: "file_progress", message: FixtureTests.fileProgress.message) { try FileProgress($0) == FixtureTests.fileProgress },
        Sample(name: "file_cancel", message: FileCancel(transferId: 0, batchId: 41).message) { try FileCancel($0) == FileCancel(transferId: 0, batchId: 41) },
        Sample(name: "privacy_request", message: FixtureTests.privacy.message) { try PrivacyRequest($0) == FixtureTests.privacy },
        Sample(name: "hello_1_9", message: FixtureTests.hello19.message) { try Hello($0) == FixtureTests.hello19 },
        Sample(name: "host_state_1_9", message: FixtureTests.hostState19.message) { try HostState($0) == FixtureTests.hostState19 },
    ]

    static let fileBegin = FileBegin(transferId: 0x0102_0304, batchId: 41, path: "Album/2026/beach.heic", size: 6_000_000_000,
                                     sha256: (0..<32).map { UInt8($0) }, modified: 1_795_000_000, index: 3, count: 12)
    static let fileAccept = FileAccept(transferId: 0x0102_0304, status: .accepted, offset: 4_194_304)
    static let fileSegment = FileSegment(transferId: 0x0102_0304, offset: 4_194_304, data: [0xDE, 0xAD, 0xBE, 0xEF])
    static let fileProgress = FileProgress(transferId: 0x0102_0304, confirmed: 6_000_000_000, state: .saved, savedName: "Album 2/2026/beach.heic")
    static let privacy = PrivacyRequest(curtain: true, blockLocalInput: true)
    static let hello19 = Hello(protoMinor: 9, appVersion: "1.2.0", build: 8,
                               capabilities: [.hevc444Decode, .filesToPhone, .micOpus, .windowStreaming, .frameRateCap, .filesV2, .curtain],
                               maxFps: 60, deviceName: "iPhone", connectionId: 0xC1A5_0000_0002, appExpires: 1_796_000_000)
    static let hostState19 = HostState(screen: .locked, keepsAwake: true, targetBitrateKbps: 12_000, inputAllowed: true,
                                       fps: 60, curtain: true, localInputBlocked: true)

    static let windows = WindowList(windows: [
        StreamableWindow(id: 4242, app: "Xcode", title: "Clamshell — HostController.swift", width: 1512, height: 944),
        StreamableWindow(id: 77, app: "Notes", title: "", width: 800, height: 600),
    ])
    static let hello18 = Hello(protoMinor: 8, appVersion: "1.1.0", build: 7, capabilities: [.hevc444Decode, .filesToPhone, .micOpus, .windowStreaming, .frameRateCap],
                               maxFps: 60, deviceName: "iPhone", connectionId: 0xC1A5_0000_0001, appExpires: 1_795_500_000)
    static let hostState18 = HostState(screen: .active, keepsAwake: true, targetBitrateKbps: 12_000, inputAllowed: true,
                                       micReady: true, window: "Xcode — HostController.swift", fps: 60)

    static let home = HomeEndpoint(host: "home.example.net", udpPort: 51820, tcpPort: 443, observedAt: 1_795_000_000, seq: 7)

    static let hostState12 = HostState(screen: .active, keepsAwake: true, targetBitrateKbps: 9_000, fecPercent: 0, inputAllowed: true)
    static let scroll = ScrollEvent(seq: 303, dx: 0, dy: -48, phase: .ended, velocityX: 0, velocityY: -1200)
    static let inputState = InputState(seq: 305, modifiers: [.leftCommand, .capsLock], keys: [0x04], buttons: .left)
    static let cursor = CursorPosition(appliedSeq: 306, x: 7_512, y: 5_336, visible: true, shapeId: 0x1234_5678_9ABC)
    static let shape = CursorShape(shapeId: 0x1234_5678_9ABC, png: [0x89, 0x50, 0x4E, 0x47], hotX: 64, hotY: 64, width: 384, height: 384)
    static let clip = ClipboardOffer(items: [ClipboardItem(uti: "public.utf8-plain-text", data: Array("hi".utf8))], changeCount: 7)

    static let report = ReceiverReport(intervalMicros: 100_000, bytesReceived: 412_000, framesCompleted: 12, framesLost: 1,
                                       fragmentsReceived: 351, fragmentsExpected: 360, queuingDelayMicros: 14_500,
                                       highestFrameId: 90_210, fecRecovered: 4, rttMicros: 48_000)
    static let hostState = HostState(screen: .locked, keepsAwake: true, targetBitrateKbps: 18_500, fecPercent: 20)

    static let format = VideoFormat(generation: 1, codec: .hevc, widthPixels: 1878, heightPixels: 1334, chroma: .yuv444,
                                    fullRange: true, parameterSets: [[0x40, 0x01, 0x0C], [0x42, 0x01, 0x01], [0x44, 0x01, 0xC1]])
    static let fragment = VideoFragment(frameId: 77, index: 1, count: 3, flags: [.keyframe], formatGeneration: 1,
                                        captureTimeNs: 123_456_789_000, payload: [0x00, 0x00, 0x01, 0x26, 0x01, 0xAF])

    static var writing: Bool { ProcessInfo.processInfo.environment["CLAMSHELL_WRITE_FIXTURES"] == "1" }

    static func bundledDirectory() throws -> URL {
        let url = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return url.appendingPathComponent("v1.0")
    }

    @Test(arguments: FixtureTests.samples.map(\.name))
    func fixtureMatches(_ name: String) throws {
        let sample = try #require(Self.samples.first { $0.name == name })
        let encoded = sample.message.encoded
        if Self.writing {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/v1.0")
            let file = dir.appendingPathComponent("\(name).hex")
            if !FileManager.default.fileExists(atPath: file.path) {
                try (encoded.hex + "\n").write(to: file, atomically: true, encoding: .utf8)
            }
            return
        }
        let text = try String(contentsOf: Self.bundledDirectory().appendingPathComponent("\(name).hex"), encoding: .utf8)
        let golden = try #require([UInt8](hex: text), "fixture \(name) is not valid hex")
        #expect(encoded == golden, "encoder output for \(name) changed: that is a wire break")
        let decoded = try #require(try InnerMessage.decodeAll(golden).first)
        #expect(try sample.check(decoded))
    }

    @Test func everyFixtureHasASample() throws {
        guard !Self.writing else { return }
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.bundledDirectory().path).filter { $0.hasSuffix(".hex") }
        let names = Set(files.map { String($0.dropLast(4)) })
        #expect(names == Set(Self.samples.map(\.name)))
    }
}
