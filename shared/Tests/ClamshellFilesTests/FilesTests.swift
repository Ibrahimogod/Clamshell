import ClamshellWire
import Foundation
import Testing
@testable import ClamshellFiles

/// A temporary folder per test, deleted at the end.
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("clamshell-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ path: String, _ bytes: [UInt8]) throws -> URL {
        let u = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: u)
        return u
    }
}

func pattern(_ n: Int, seed: UInt8 = 7) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) } }

@Suite("File messages")
struct FileMessageTests {
    @Test func roundTrips() throws {
        let sha = [UInt8](repeating: 0xAB, count: 32)
        let b = FileBegin(transferId: 9, batchId: 4, path: "Photos/2026/a.jpg", size: 5_000_000_000, sha256: sha, modified: 1_790_000_000, index: 2, count: 10)
        #expect(try FileBegin(b.message) == b)
        let a = FileAccept(transferId: 9, status: .accepted, offset: 1 << 33)
        #expect(try FileAccept(a.message) == a)
        #expect(try FileAccept(FileAccept(transferId: 9, status: .noSpace).message).status == .noSpace)
        let s = FileSegment(transferId: 9, offset: 65536, data: pattern(100))
        #expect(try FileSegment(s.message) == s)
        #expect(s.message.channel == .files)
        let p = FileProgress(transferId: 9, confirmed: 77, state: .saved, savedName: "Photos 2/a.jpg")
        #expect(try FileProgress(p.message) == p)
        let c = FileCancel(transferId: 0, batchId: 4)
        #expect(try FileCancel(c.message) == c)
        let r = PrivacyRequest(curtain: true, blockLocalInput: false)
        #expect(try PrivacyRequest(r.message) == r)
        #expect(try PrivacyRequest(PrivacyRequest().message) == PrivacyRequest())
    }

    @Test func rejectsBadValues() {
        #expect(throws: (any Error).self) { try FileBegin(FileBegin(transferId: 0, batchId: 1, path: "a", size: 1, sha256: [UInt8](repeating: 0, count: 32)).message) }
        #expect(throws: (any Error).self) { try FileBegin(FileBegin(transferId: 1, batchId: 1, path: "a", size: 1, sha256: [1, 2]).message) }
        #expect(throws: (any Error).self) { try FileSegment(FileSegment(transferId: 1, offset: 0, data: []).message) }
        #expect(throws: (any Error).self) { try FileSegment(FileSegment(transferId: 1, offset: 0, data: pattern(FileSegment.maxBytes + 1)).message) }
        #expect(throws: (any Error).self) { try FileAccept(body: FileAccept(transferId: 1).encodeBody() + [0x02, 0x01, 0x09]) }
    }

    @Test func safeComponents() {
        #expect(FileBegin.safeComponents("Photos/2026/a.jpg") == ["Photos", "2026", "a.jpg"])
        #expect(FileBegin.safeComponents("../../etc/passwd") == ["etc", "passwd"])
        #expect(FileBegin.safeComponents("a\\..\\b/./.hidden") == ["a", "b", "hidden"])
        #expect(FileBegin.safeComponents("/") == nil)
        #expect(FileBegin.safeComponents("..") == nil)
        #expect(FileBegin.safeComponents(Array(repeating: "d", count: 40).joined(separator: "/")) == nil)
    }
}

@Suite("File listing")
struct FileListingTests {
    @Test func expandsFoldersSkippingHiddenFilesAndLinks() throws {
        let t = try TempDir()
        try t.write("Pick/b.txt", pattern(10))
        try t.write("Pick/sub/a.txt", pattern(20))
        try t.write("Pick/.DS_Store", pattern(5))
        try t.write("Pick/.git/config", pattern(5))
        try FileManager.default.createSymbolicLink(at: t.url.appendingPathComponent("Pick/link"), withDestinationURL: t.url.appendingPathComponent("Pick/b.txt"))
        let single = try t.write("single.bin", pattern(3))
        let list = FileListing.expand([t.url.appendingPathComponent("Pick"), single])
        #expect(list.map(\.path) == ["Pick/b.txt", "Pick/sub/a.txt", "single.bin"])
        #expect(list.map(\.size) == [10, 20, 3])
        let prepared = try FileListing.prepare([single])
        #expect(prepared.first?.sha256.count == 32)
        #expect(FileListing.read(single, offset: 1, count: 10) == Array(pattern(3)[1...]))
    }
}

/// A sender queue and a receiver joined in memory, with a lossy, reordering path for segments.
@MainActor
final class Link {
    var queue = FileSendQueue()
    let receiver: FileReceiver
    var toSender: [InnerMessage] = []
    var now: UInt64 = 1_000_000_000
    /// Drops the segment at this offset once.
    var dropOnce: Set<UInt64> = []
    var reverseSegments = false

    init(root: URL) {
        receiver = FileReceiver(root: root)
        receiver.send = { [unowned self] m in self.toSender.append(m) }
    }

    /// One round: the sender polls, the receiver takes what arrives, the sender takes the answers.
    func step() {
        now += 100_000_000
        let (control, segments) = queue.poll(nowNs: now) { FileListing.read($0, offset: $1, count: $2) }
        for m in control { deliverToReceiver(m) }
        var segs = segments
        if reverseSegments { segs.reverse() }
        for m in segs {
            if let s = try? FileSegment(m), dropOnce.remove(s.offset) != nil { continue }
            deliverToReceiver(m)
        }
        let answers = toSender
        toSender = []
        for m in answers {
            switch m.type {
            case .fileAccept: if let a = try? FileAccept(m) { queue.handle(a, nowNs: now) }
            case .fileProgress: if let p = try? FileProgress(m) { queue.handle(p, nowNs: now) }
            case .fileCancel: if let c = try? FileCancel(m) { queue.handle(c) }
            default: break
            }
        }
    }

    func deliverToReceiver(_ m: InnerMessage) {
        switch m.type {
        case .fileBegin: if let b = try? FileBegin(m) { receiver.handle(b, nowNs: now) }
        case .fileSegment: if let s = try? FileSegment(m) { receiver.handle(s, nowNs: now) }
        case .fileCancel: if let c = try? FileCancel(m) { receiver.handle(c) }
        default: break
        }
    }

    /// Steps until the queue is idle (the hash check runs off the main actor, so this yields).
    func run(maxSteps: Int = 2000) async {
        for _ in 0..<maxSteps where queue.busy {
            step()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

@Suite("File transfers", .serialized)
@MainActor
struct FileTransferTests {
    @Test func sendsAFolderAndFilesKeepingStructure() async throws {
        let src = try TempDir(), dst = try TempDir()
        let big = pattern(FileSegment.maxBytes * 20 + 123)
        try src.write("Album/one.bin", big)
        try src.write("Album/deep/two.txt", pattern(5, seed: 1))
        try src.write("empty.txt", [])
        let files = try FileListing.prepare([src.url.appendingPathComponent("Album"), src.url.appendingPathComponent("empty.txt")])
        try dst.write("Album/existing.txt", [1])       // the folder exists: the batch goes to "Album 2"

        let link = Link(root: dst.url)
        link.reverseSegments = true
        link.dropOnce = [UInt64(FileSegment.maxBytes * 3)]
        link.queue.stallTimeoutNs = 500_000_000
        link.queue.enqueue(files)
        await link.run()

        #expect(link.queue.items.allSatisfy { if case .saved = $0.phase { true } else { false } })
        #expect(try Data(contentsOf: dst.url.appendingPathComponent("Album 2/one.bin")) == Data(big))
        #expect(try Data(contentsOf: dst.url.appendingPathComponent("Album 2/deep/two.txt")) == Data(pattern(5, seed: 1)))
        #expect(FileManager.default.fileExists(atPath: dst.url.appendingPathComponent("empty.txt").path))
        #expect(link.queue.items.first { $0.file.path == "Album/one.bin" }?.phase == .saved("Album 2/one.bin"))
        let partials = try FileManager.default.contentsOfDirectory(atPath: dst.url.appendingPathComponent(".clamshell-partial").path)
        #expect(partials.isEmpty)
    }

    @Test func resumesAfterTheSessionDrops() async throws {
        let src = try TempDir(), dst = try TempDir()
        let data = pattern(FileSegment.maxBytes * 30, seed: 3)
        let file = try FileListing.prepare([try src.write("movie.mov", data)])

        let link = Link(root: dst.url)
        link.queue.enqueue(file)
        for _ in 0..<3 { link.step() }
        let partway = link.receiver.status?.received ?? 0
        #expect(partway > 0 && partway < UInt64(data.count))

        // The connection drops; a new receiver (the app restarted) sees the same partial file.
        link.receiver.suspend()
        let second = Link(root: dst.url)
        second.queue = link.queue
        second.queue.reconnected()
        var firstOffset: UInt64?
        second.receiver.send = { [unowned second] m in
            if firstOffset == nil, let a = try? FileAccept(m) { firstOffset = a.offset }
            second.toSender.append(m)
        }
        await second.run()
        #expect(firstOffset == partway)
        #expect(try Data(contentsOf: dst.url.appendingPathComponent("movie.mov")) == Data(data))
    }

    @Test func damagedFileIsSentAgainOnce() async throws {
        let src = try TempDir(), dst = try TempDir()
        let data = pattern(FileSegment.maxBytes * 2 + 9)
        var files = try FileListing.prepare([try src.write("x.bin", data)])
        files[0].sha256[0] ^= 0xFF          // never matches: damaged, retried, then failed
        let link = Link(root: dst.url)
        link.queue.enqueue(files)
        await link.run()
        guard case .failed = link.queue.items[0].phase else { Issue.record("expected failure, got \(link.queue.items[0].phase)"); return }
        #expect(!FileManager.default.fileExists(atPath: dst.url.appendingPathComponent("x.bin").path))
    }

    @Test func refusedAndNoSpace() async throws {
        let src = try TempDir(), dst = try TempDir()
        let files = try FileListing.prepare([try src.write("a.bin", pattern(10))])
        let link = Link(root: dst.url)
        link.receiver.accepting = { false }
        link.queue.enqueue(files)
        await link.run()
        #expect(link.queue.items[0].phase == .failed("the other side doesn't take files now"))

        let link2 = Link(root: dst.url)
        link2.receiver.freeSpace = { 1000 }
        link2.queue.enqueue(files)
        await link2.run()
        #expect(link2.queue.items[0].phase == .failed("not enough space on the other side"))
    }

    @Test func receiverCancelStopsTheBatch() async throws {
        let src = try TempDir(), dst = try TempDir()
        let files = try FileListing.prepare([try src.write("a.bin", pattern(FileSegment.maxBytes * 40)), try src.write("b.bin", pattern(10))])
        let link = Link(root: dst.url)
        link.queue.enqueue(files)
        link.step(); link.step()
        link.receiver.cancel()
        link.step()
        #expect(link.queue.items.allSatisfy { $0.phase == .cancelled })
        #expect(!link.queue.busy)
    }

    @Test func senderGivesUpWhenNobodyAnswers() {
        var q = FileSendQueue()
        q.enqueue([OutgoingFile(url: URL(fileURLWithPath: "/nonexistent"), path: "a", size: 1, sha256: [UInt8](repeating: 0, count: 32))])
        var now: UInt64 = 0, begins = 0
        for _ in 0..<200 {
            now += 1_000_000_000
            begins += q.poll(nowNs: now) { _, _, _ in nil }.control.count
        }
        #expect(begins == 1 + q.maxRepeats)
        #expect(q.items[0].phase == .failed("the other side stopped answering"))
    }
}
