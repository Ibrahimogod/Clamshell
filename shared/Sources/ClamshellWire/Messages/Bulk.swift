/// Messages bigger than one datagram, delivered reliably (protocol 1.2): cursor images, clipboard.
///
/// The sender splits the encoded inner message into `BulkChunk`s of ≤ 1000 bytes; the receiver acks
/// what it has (`BulkAck`, a bitmap) and the sender resends the rest every 150 ms, up to 20 times.
/// Pure logic; the caller sends what `BulkSender.poll` returns. A transfer is one inner message, any
/// channel (it is re-decoded on arrival), at most 32 MiB, with at most 512 chunks in flight.
public struct BulkChunk: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.bulkChunk

    public var transferId: UInt32
    public var index: UInt16
    public var count: UInt16
    public var data: [UInt8]

    public init(transferId: UInt32, index: UInt16, count: UInt16, data: [UInt8]) {
        self.transferId = transferId; self.index = index; self.count = count; self.data = data
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(transferId))
        t.uint(2, UInt64(index))
        t.uint(3, UInt64(count))
        t.bytes(4, data)
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4])
        transferId = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "transferId")
        index = try t.requiredUInt(2).narrowed(to: UInt16.self, field: "index")
        count = try t.requiredUInt(3).narrowed(to: UInt16.self, field: "count")
        data = try t.requiredBytes(4)
        guard count > 0, index < count else { throw WireError.invalidValue("chunk \(index) of \(count)") }
    }
}

public struct BulkAck: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.bulkAck

    public var transferId: UInt32
    /// Bit i set = chunk i received. Complete when every bit below `count` is set.
    public var received: [UInt8]

    public init(transferId: UInt32, received: [UInt8]) { self.transferId = transferId; self.received = received }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(transferId))
        t.bytes(2, received)
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2])
        transferId = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "transferId")
        received = try t.optionalBytes(2) ?? []
    }

    public func has(_ i: Int) -> Bool { i / 8 < received.count && received[i / 8] & (1 << UInt8(i % 8)) != 0 }
}

public struct BulkSender: Sendable {
    public static let chunkSize = 1000
    /// 32 MiB: clipboard images and dropped files (M5). The receiver holds a transfer in memory.
    public static let maxBytes = 32 << 20
    /// Chunks in flight per transfer (512 KB): the first burst, then refilled as acks arrive.
    public static let window = 512
    struct Transfer: Sendable {
        var chunks: [[UInt8]]
        var acked: Set<Int> = []
        var sentAt: [Int: UInt64] = [:]          // in flight: chunk → last send time
        var nextUnsent = 0
        var idleRounds = 0                       // retransmit rounds with no new ack
        var progressed = false
    }
    private var nextId: UInt32 = 1
    private var transfers: [UInt32: Transfer] = [:]
    public var retryNs: UInt64 = 150_000_000
    /// Retransmit rounds without any progress before giving up (3 s at 150 ms).
    public var maxTries = 20

    public init() {}

    public var pending: Int { transfers.count }

    /// Progress of the oldest transfer, 0…1 (for a file's progress bar), nil when idle.
    public var progress: Double? {
        guard let t = transfers.min(by: { $0.key < $1.key })?.value, !t.chunks.isEmpty else { return nil }
        return Double(t.acked.count) / Double(t.chunks.count)
    }

    /// Queues `message`; returns the first burst (up to `window` chunks). Returns nothing if it is too big.
    public mutating func send(_ message: InnerMessage, nowNs: UInt64) -> [InnerMessage] {
        let bytes = message.encoded
        guard bytes.count <= Self.maxBytes else { return [] }
        let id = nextId
        nextId &+= 1
        if nextId == 0 { nextId = 1 }
        let chunks = stride(from: 0, to: max(bytes.count, 1), by: Self.chunkSize).map { Array(bytes[$0..<min($0 + Self.chunkSize, bytes.count)]) }
        var t = Transfer(chunks: chunks)
        let out = Self.fill(id: id, &t, nowNs: nowNs)
        transfers[id] = t
        return out
    }

    /// Drops every queued transfer (a cancelled file).
    public mutating func cancelAll() { transfers.removeAll() }

    public mutating func handle(_ ack: BulkAck) {
        guard var t = transfers[ack.transferId] else { return }
        for i in t.sentAt.keys where ack.has(i) {
            t.acked.insert(i)
            t.sentAt[i] = nil
            t.progressed = true
        }
        transfers[ack.transferId] = t.acked.count == t.chunks.count ? nil : t
    }

    /// Sends new chunks into the window freed by acks, and resends chunks unacked for `retryNs`.
    /// Gives up on a transfer after `maxTries` resend rounds in a row with no new ack.
    public mutating func poll(nowNs: UInt64) -> [InnerMessage] {
        var out: [InnerMessage] = []
        for (id, var t) in transfers {
            if t.progressed { t.idleRounds = 0; t.progressed = false }
            let due = t.sentAt.filter { nowNs >= $0.value + retryNs }.keys.sorted()
            if !due.isEmpty {
                t.idleRounds += 1
                guard t.idleRounds < maxTries else { transfers[id] = nil; continue }
                for i in due {
                    t.sentAt[i] = nowNs
                    out.append(Self.chunk(id, t, i))
                }
            }
            out += Self.fill(id: id, &t, nowNs: nowNs)
            transfers[id] = t
        }
        return out
    }

    private static func chunk(_ id: UInt32, _ t: Transfer, _ i: Int) -> InnerMessage {
        BulkChunk(transferId: id, index: UInt16(i), count: UInt16(t.chunks.count), data: t.chunks[i]).message
    }

    private static func fill(id: UInt32, _ t: inout Transfer, nowNs: UInt64) -> [InnerMessage] {
        var out: [InnerMessage] = []
        while t.sentAt.count < window, t.nextUnsent < t.chunks.count {
            t.sentAt[t.nextUnsent] = nowNs
            out.append(chunk(id, t, t.nextUnsent))
            t.nextUnsent += 1
        }
        return out
    }
}

public struct BulkReceiver: Sendable {
    struct Partial: Sendable { var chunks: [[UInt8]?]; var lastNs: UInt64 }
    private var partial: [UInt32: Partial] = [:]
    private var done: [UInt32: Int] = [:]          // id → chunk count, to re-ack duplicates
    private var doneOrder: [UInt32] = []

    public init() {}

    /// Returns the ack to send, and the message when a transfer just completed.
    public mutating func add(_ c: BulkChunk, nowNs: UInt64) -> (ack: BulkAck, completed: InnerMessage?) {
        if let n = done[c.transferId] { return (BulkAck(transferId: c.transferId, received: Self.bitmap(all: n)), nil) }
        var p = partial[c.transferId] ?? Partial(chunks: Array(repeating: nil, count: Int(c.count)), lastNs: nowNs)
        guard p.chunks.count == Int(c.count), Int(c.count) * BulkSender.chunkSize <= BulkSender.maxBytes + BulkSender.chunkSize else {
            return (BulkAck(transferId: c.transferId, received: []), nil)
        }
        p.chunks[Int(c.index)] = c.data
        p.lastNs = nowNs
        var bits = [UInt8](repeating: 0, count: (p.chunks.count + 7) / 8)
        for (i, ch) in p.chunks.enumerated() where ch != nil { bits[i / 8] |= 1 << UInt8(i % 8) }
        let ack = BulkAck(transferId: c.transferId, received: bits)
        guard p.chunks.allSatisfy({ $0 != nil }) else { partial[c.transferId] = p; return (ack, nil) }
        partial[c.transferId] = nil
        done[c.transferId] = p.chunks.count
        doneOrder.append(c.transferId)
        if doneOrder.count > 64 { done[doneOrder.removeFirst()] = nil }
        partial = partial.filter { nowNs - $0.value.lastNs < 10_000_000_000 }     // drop abandoned transfers
        let bytes = p.chunks.flatMap { $0 ?? [] }
        return (ack, try? InnerMessage.decodeAll(bytes).first)
    }

    static func bitmap(all n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: (n + 7) / 8)
        for i in 0..<n { b[i / 8] |= 1 << UInt8(i % 8) }
        return b
    }
}
