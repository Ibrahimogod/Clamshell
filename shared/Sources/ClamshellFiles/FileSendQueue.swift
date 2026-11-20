import ClamshellWire
import Foundation

/// The sending side of protocol 1.9 files. Pure logic: the caller sends what `poll` returns (control
/// messages directly, each segment as one bulk transfer) and feeds back the receiver's answers.
///
/// One file is in flight at a time, in the order queued. At most `inFlightSegments` segments may be sent
/// beyond what the receiver has confirmed, which paces a big file to what the path and the receiver's disk
/// take, and keeps a backlog from building in front of the video. A file with no answer or no progress is
/// announced again (`FileBegin`): the receiver answers with how much it has, so that is also how a transfer
/// resumes after a dropped connection.
public struct FileSendQueue: Sendable {
    public static let segmentBytes = FileSegment.maxBytes
    public var inFlightSegments = 8
    /// A `FileBegin` with no `FileAccept` after this is sent again.
    public var answerTimeoutNs: UInt64 = 5_000_000_000
    /// No `FileProgress` for this long while sending or checking: announce the file again.
    public var stallTimeoutNs: UInt64 = 10_000_000_000
    /// Announcements in a row without any answer before the file fails (about a minute).
    public var maxRepeats = 6

    public enum Phase: Sendable, Equatable {
        case queued
        case announced
        case sending
        /// Every byte is confirmed; the receiver is checking the hash.
        case checking
        case saved(String)
        case failed(String)
        case cancelled

        public var finished: Bool {
            switch self {
            case .saved, .failed, .cancelled: true
            default: false
            }
        }
    }

    public struct Item: Sendable, Identifiable {
        public let id: UInt32
        public let batchId: UInt32
        public let file: OutgoingFile
        public let index: UInt32
        public let count: UInt32
        public internal(set) var phase: Phase = .queued
        public internal(set) var confirmed: UInt64 = 0
        var nextOffset: UInt64 = 0
        var lastActivityNs: UInt64 = 0
        var repeats = 0
        var damagedRetries = 0

        public var fraction: Double { file.size == 0 ? (phase.finished ? 1 : 0) : Double(confirmed) / Double(file.size) }

        var begin: FileBegin {
            FileBegin(transferId: id, batchId: batchId, path: file.path, size: file.size, sha256: file.sha256,
                      modified: file.modified, index: index, count: count)
        }
    }

    public private(set) var items: [Item] = []
    private var nextId: UInt32
    private var nextBatch: UInt32

    public init() {
        // Random starts, so ids from a restarted app don't meet a receiver's memory of the old ones.
        nextId = UInt32.random(in: 1...0x7FFF_FFFF)
        nextBatch = UInt32.random(in: 1...0x7FFF_FFFF)
    }

    /// Queues one batch (a pick of files, or a folder). Returns its id.
    @discardableResult
    public mutating func enqueue(_ files: [OutgoingFile]) -> UInt32 {
        let batch = nextBatch
        nextBatch = nextBatch == UInt32.max ? 1 : nextBatch + 1
        for (i, f) in files.enumerated() {
            items.append(Item(id: nextId, batchId: batch, file: f, index: UInt32(i), count: UInt32(files.count)))
            nextId = nextId == UInt32.max ? 1 : nextId + 1
        }
        return batch
    }

    /// The file being sent now, if any.
    public var current: Item? { items.first { !$0.phase.finished } }
    public var busy: Bool { current != nil }

    /// Bytes confirmed and bytes queued, over the unfinished batches (for one progress bar).
    public var totals: (done: UInt64, total: UInt64, files: Int, filesDone: Int) {
        let batches = Set(items.filter { !$0.phase.finished }.map(\.batchId))
        let open = items.filter { batches.contains($0.batchId) }
        let done = open.reduce(UInt64(0)) { $0 + ($1.phase.finished ? $1.file.size : min($1.confirmed, $1.file.size)) }
        return (done, open.reduce(UInt64(0)) { $0 + $1.file.size }, open.count, open.filter(\.phase.finished).count)
    }

    /// Control messages to send now, and segments (each one bulk transfer).
    public mutating func poll(nowNs: UInt64, read: (URL, UInt64, Int) -> [UInt8]?) -> (control: [InnerMessage], segments: [InnerMessage]) {
        guard let i = items.firstIndex(where: { !$0.phase.finished }) else { return ([], []) }
        var item = items[i]
        var control: [InnerMessage] = []
        var segments: [InnerMessage] = []
        defer { items[i] = item }
        switch item.phase {
        case .queued:
            item.phase = .announced
            item.lastActivityNs = nowNs
            item.repeats = 0
            control.append(item.begin.message)
        case .announced:
            if nowNs >= item.lastActivityNs + answerTimeoutNs { announceAgain(&item, nowNs: nowNs, into: &control) }
        case .sending:
            let window = UInt64(inFlightSegments * Self.segmentBytes)
            while item.nextOffset < item.file.size, item.nextOffset < item.confirmed + window {
                let n = Int(min(UInt64(Self.segmentBytes), item.file.size - item.nextOffset))
                guard let data = read(item.file.url, item.nextOffset, n), data.count == n else {
                    item.phase = .failed("couldn't read \(item.file.name) any more")
                    control.append(FileCancel(transferId: item.id).message)
                    return (control, segments)
                }
                segments.append(FileSegment(transferId: item.id, offset: item.nextOffset, data: data).message)
                item.nextOffset += UInt64(n)
            }
            if nowNs >= item.lastActivityNs + stallTimeoutNs { announceAgain(&item, nowNs: nowNs, into: &control) }
        case .checking:
            if nowNs >= item.lastActivityNs + stallTimeoutNs { announceAgain(&item, nowNs: nowNs, into: &control) }
        case .saved, .failed, .cancelled:
            break
        }
        return (control, segments)
    }

    private func announceAgain(_ item: inout Item, nowNs: UInt64, into control: inout [InnerMessage]) {
        item.repeats += 1
        guard item.repeats <= maxRepeats else { item.phase = .failed("the other side stopped answering"); return }
        item.phase = .announced
        item.lastActivityNs = nowNs
        control.append(item.begin.message)
    }

    public mutating func handle(_ a: FileAccept, nowNs: UInt64) {
        guard let i = items.firstIndex(where: { $0.id == a.transferId }), !items[i].phase.finished else { return }
        var item = items[i]
        defer { items[i] = item }
        item.lastActivityNs = nowNs
        item.repeats = 0
        switch a.status {
        case .accepted:
            let offset = min(a.offset, item.file.size)
            item.confirmed = offset
            item.nextOffset = offset
            item.phase = offset >= item.file.size ? .checking : .sending
        case .refused: item.phase = .failed("the other side doesn't take files now")
        case .noSpace: item.phase = .failed("not enough space on the other side")
        case .badName: item.phase = .failed("the name can't be used on the other side")
        case .alreadySaved: item.phase = .saved(item.file.name)
        }
    }

    public mutating func handle(_ p: FileProgress, nowNs: UInt64) {
        guard let i = items.firstIndex(where: { $0.id == p.transferId }), !items[i].phase.finished else { return }
        var item = items[i]
        defer { items[i] = item }
        item.lastActivityNs = nowNs
        item.repeats = 0
        switch p.state {
        case .receiving:
            item.confirmed = max(item.confirmed, min(p.confirmed, item.file.size))
            if item.phase == .announced { item.phase = .sending; item.nextOffset = max(item.nextOffset, item.confirmed) }
            if item.confirmed >= item.file.size { item.phase = .checking }
        case .checking:
            item.confirmed = item.file.size
            item.phase = .checking
        case .saved:
            item.confirmed = item.file.size
            item.phase = .saved(p.savedName ?? item.file.name)
        case .damaged:
            // The receiver threw its copy away; one more try from the start, then give up.
            guard item.damagedRetries == 0 else { item.phase = .failed("\(item.file.name) arrived damaged twice"); return }
            item.damagedRetries += 1
            item.confirmed = 0
            item.nextOffset = 0
            item.phase = .queued
        case .writeFailed:
            item.phase = .failed("the other side couldn't save \(item.file.name)")
        }
    }

    /// The receiver stopped a file (or a whole batch).
    public mutating func handle(_ c: FileCancel) {
        for i in items.indices where !items[i].phase.finished
            && (items[i].id == c.transferId || (c.transferId == 0 && items[i].batchId == c.batchId)) {
            items[i].phase = .cancelled
        }
    }

    /// Stops everything still queued or in flight. Returns the cancels to send.
    public mutating func cancelAll() -> [InnerMessage] {
        var out: [InnerMessage] = []
        for i in items.indices where !items[i].phase.finished {
            if items[i].phase != .queued { out.append(FileCancel(transferId: items[i].id).message) }
            items[i].phase = .cancelled
        }
        return out
    }

    /// A new connection to the same peer: announce the file in flight again now, so it resumes.
    public mutating func reconnected() {
        guard let i = items.firstIndex(where: { !$0.phase.finished }), items[i].phase != .queued else { return }
        items[i].phase = .queued
        items[i].repeats = 0
    }

    /// Forgets finished batches (keeps the unfinished ones and their finished files, for "3 of 10").
    public mutating func pruneFinished() {
        let open = Set(items.filter { !$0.phase.finished }.map(\.batchId))
        items.removeAll { !open.contains($0.batchId) }
    }
}
