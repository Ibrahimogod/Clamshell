/// Files of any size and whole folders (protocol 1.9, `filesV2`), in both directions.
///
/// The sender announces each file with a `FileBegin`; the receiver answers with a `FileAccept` saying from
/// which byte to send (0, or how much a partial copy from an earlier try already holds). The data then goes
/// as `FileSegment`s of up to 64 KiB, each one bulk transfer (`BulkChunk`/`BulkAck`), and the receiver
/// confirms what it has written with `FileProgress`. When every byte is in, the receiver checks the whole
/// file against `sha256` and reports `saved` or `damaged`. Either side can stop a file with `FileCancel`.
/// The control messages are small and go on the control channel; a sender repeats a `FileBegin` that got no
/// answer, and the receiver answers a repeat with where it is now, so a repeat is also how a transfer resumes.

/// Sender → receiver: one file of a batch (a pick of files, or a folder).
public struct FileBegin: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.fileBegin
    /// Most path components a folder entry may have, and the most bytes in the whole path.
    public static let maxDepth = 32
    public static let maxPathBytes = 1024

    public var transferId: UInt32
    public var batchId: UInt32
    /// "name.ext" for a single file, "Folder/sub/name.ext" for a file inside a picked folder ("/" separated).
    public var path: String
    public var size: UInt64
    public var sha256: [UInt8]
    /// Last modification, Unix seconds (0 = unknown).
    public var modified: UInt64
    /// This file's place in its batch, and how many files the batch has, for "3 of 10".
    public var index: UInt32
    public var count: UInt32

    public init(transferId: UInt32, batchId: UInt32, path: String, size: UInt64, sha256: [UInt8], modified: UInt64 = 0,
                index: UInt32 = 0, count: UInt32 = 1) {
        self.transferId = transferId; self.batchId = batchId; self.path = path; self.size = size
        self.sha256 = sha256; self.modified = modified; self.index = index; self.count = count
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(transferId))
        t.uint(2, UInt64(batchId))
        t.string(3, path)
        t.uint(4, size)
        t.bytes(5, sha256)
        if modified > 0 { t.uint(6, modified) }
        if index > 0 { t.uint(7, UInt64(index)) }
        if count != 1 { t.uint(8, UInt64(count)) }
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4, 5, 6, 7, 8])
        transferId = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "transferId")
        batchId = try (t.optionalUInt(2) ?? 0).narrowed(to: UInt32.self, field: "batchId")
        path = try t.requiredString(3)
        size = try t.requiredUInt(4)
        sha256 = try t.requiredBytes(5)
        modified = try t.optionalUInt(6) ?? 0
        index = try (t.optionalUInt(7) ?? 0).narrowed(to: UInt32.self, field: "index")
        count = try (t.optionalUInt(8) ?? 1).narrowed(to: UInt32.self, field: "count")
        guard transferId != 0 else { throw WireError.invalidValue("transfer id 0") }
        guard sha256.count == 32 else { throw WireError.invalidValue("sha256 length \(sha256.count)") }
        guard path.utf8.count <= Self.maxPathBytes else { throw WireError.invalidValue("path of \(path.utf8.count) bytes") }
    }

    /// The path as safe components to create under the receiver's folder: each one cleaned like a
    /// `FileOffer` name, with "." and ".." and empty parts dropped. nil when nothing usable is left or the
    /// path is deeper than `maxDepth`. The last component is the file's name.
    public static func safeComponents(_ path: String) -> [String]? {
        let raw = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        let parts = raw.filter { $0 != "." && $0 != ".." && !$0.trimmingSpaces().isEmpty }.map(FileOffer.safeName)
        guard !parts.isEmpty, parts.count <= maxDepth else { return nil }
        return parts
    }
}

/// Receiver → sender: whether to send a file, and from which byte.
public struct FileAccept: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.fileAccept

    public enum Status: UInt8, Sendable {
        /// Send from `offset`.
        case accepted = 0
        /// The receiver doesn't take files now (the Mac's "Accept files" is off).
        case refused = 1
        /// Not enough free space.
        case noSpace = 2
        /// The name or path can't be used.
        case badName = 3
        /// The receiver already saved this file in this batch (a repeat after the end): nothing to send.
        case alreadySaved = 4
    }

    public var transferId: UInt32
    public var status: Status
    public var offset: UInt64

    public init(transferId: UInt32, status: Status = .accepted, offset: UInt64 = 0) {
        self.transferId = transferId; self.status = status; self.offset = offset
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(transferId))
        if status != .accepted { t.uint(2, UInt64(status.rawValue)) }
        if offset > 0 { t.uint(3, offset) }
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3])
        transferId = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "transferId")
        let raw = try (t.optionalUInt(2) ?? 0).narrowed(to: UInt8.self, field: "status")
        guard let s = Status(rawValue: raw) else { throw WireError.invalidValue("file status \(raw)") }
        status = s
        offset = try t.optionalUInt(3) ?? 0
    }
}

/// Sender → receiver, through the bulk path: `data` belongs at byte `offset` of the file.
public struct FileSegment: WireMessage {
    public static let channel = Channel.files
    public static let type = MessageType.fileSegment
    public static let maxBytes = 64 << 10

    public var transferId: UInt32
    public var offset: UInt64
    public var data: [UInt8]

    public init(transferId: UInt32, offset: UInt64, data: [UInt8]) {
        self.transferId = transferId; self.offset = offset; self.data = data
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(transferId))
        t.uint(2, offset)
        t.bytes(3, data)
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3])
        transferId = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "transferId")
        offset = try t.optionalUInt(2) ?? 0
        data = try t.requiredBytes(3)
        guard !data.isEmpty, data.count <= Self.maxBytes else { throw WireError.invalidValue("segment of \(data.count) bytes") }
    }
}

/// Receiver → sender: how many bytes from the start are written, and how the file ended.
public struct FileProgress: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.fileProgress

    public enum State: UInt8, Sendable {
        case receiving = 0
        /// Every byte is in; the receiver is checking the hash.
        case checking = 1
        case saved = 2
        /// The hash didn't match: the partial copy is gone, so sending again starts from 0.
        case damaged = 3
        /// The receiver couldn't write (disk full, permissions).
        case writeFailed = 4
    }

    public var transferId: UInt32
    public var confirmed: UInt64
    public var state: State
    /// With `saved`: the name the file got (it may differ, e.g. "report 2.pdf").
    public var savedName: String?

    public init(transferId: UInt32, confirmed: UInt64, state: State = .receiving, savedName: String? = nil) {
        self.transferId = transferId; self.confirmed = confirmed; self.state = state; self.savedName = savedName
    }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(transferId))
        t.uint(2, confirmed)
        if state != .receiving { t.uint(3, UInt64(state.rawValue)) }
        if let savedName { t.string(4, savedName) }
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2, 3, 4])
        transferId = try t.requiredUInt(1).narrowed(to: UInt32.self, field: "transferId")
        confirmed = try t.optionalUInt(2) ?? 0
        let raw = try (t.optionalUInt(3) ?? 0).narrowed(to: UInt8.self, field: "state")
        guard let s = State(rawValue: raw) else { throw WireError.invalidValue("file state \(raw)") }
        state = s
        savedName = try t.optionalString(4)
    }
}

/// Either side: stop a transfer (`transferId`), or every transfer of a batch (`transferId` 0, `batchId`).
/// The receiver keeps a partial copy, so sending the same file again later resumes it.
public struct FileCancel: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.fileCancel

    public var transferId: UInt32
    public var batchId: UInt32

    public init(transferId: UInt32, batchId: UInt32 = 0) { self.transferId = transferId; self.batchId = batchId }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        t.uint(1, UInt64(transferId))
        if batchId != 0 { t.uint(2, UInt64(batchId)) }
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2])
        transferId = try (t.optionalUInt(1) ?? 0).narrowed(to: UInt32.self, field: "transferId")
        batchId = try (t.optionalUInt(2) ?? 0).narrowed(to: UInt32.self, field: "batchId")
    }
}

/// Phone → Mac (1.9, `curtain`): hide the Mac's own screen, and turn its keyboard and trackpad off, for the
/// rest of this session. A field left out keeps the Mac's current setting.
public struct PrivacyRequest: WireMessage {
    public static let channel = Channel.control
    public static let type = MessageType.privacyRequest

    public var curtain: Bool?
    public var blockLocalInput: Bool?

    public init(curtain: Bool? = nil, blockLocalInput: Bool? = nil) { self.curtain = curtain; self.blockLocalInput = blockLocalInput }

    public func encodeBody() -> [UInt8] {
        var t = TLVWriter()
        if let curtain { t.bool(1, curtain) }
        if let blockLocalInput { t.bool(2, blockLocalInput) }
        return t.bytes
    }

    public init(body: [UInt8]) throws {
        let t = try TLVReader(body, knownTags: [1, 2])
        curtain = try t.optionalUInt(1).map { $0 != 0 }
        blockLocalInput = try t.optionalUInt(2).map { $0 != 0 }
    }
}
