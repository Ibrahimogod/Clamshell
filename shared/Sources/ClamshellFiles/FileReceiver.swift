import ClamshellWire
import CryptoKit
import Foundation

/// The receiving side of protocol 1.9 files: answers `FileBegin`s, writes `FileSegment`s at their offsets,
/// confirms progress, checks the hash, and saves the file under `root` (keeping a sent folder's structure).
///
/// A file being received lives in `root/.clamshell-partial/<sha256>-<size>.part`, with the number of bytes
/// known good beside it in a `.offset` file. A transfer that stops (dropped connection, cancel, app quit)
/// keeps both, and when the same file is announced again (same hash and size, any transfer id) the receiver
/// answers with that offset, so only the rest is sent. Partial files untouched for a week are deleted.
@MainActor
public final class FileReceiver {
    public enum State: Sendable, Equatable {
        case receiving
        case checking
        case saved(String)
        case failed(String)
        case cancelled
    }

    /// What the UI shows: the file in flight, or the last one that ended.
    public struct Status: Sendable, Equatable {
        public var transferId: UInt32
        public var batchId: UInt32
        public var name: String
        public var index: UInt32
        public var count: UInt32
        public var size: UInt64
        public var received: UInt64
        public var state: State
        public var fraction: Double { size == 0 ? 1 : Double(received) / Double(size) }
    }

    public let root: URL
    /// Whether to take files now (the Mac's "Accept files").
    public var accepting: () -> Bool = { true }
    /// Sends a control message to the sender.
    public var send: (InnerMessage) -> Void = { _ in }
    /// Called whenever `status` changes.
    public var onChange: () -> Void = {}
    /// Called once per saved file, with where it went.
    public var onSaved: (URL) -> Void = { _ in }
    /// Free space to leave on the disk, on top of the file.
    public var spareBytes: UInt64 = 256 << 20
    /// Overrides the free-space lookup (tests).
    public var freeSpace: (() -> UInt64?)?

    public private(set) var status: Status?

    private struct Active {
        var begin: FileBegin
        var components: [String]
        var partURL: URL
        var offsetURL: URL
        var handle: FileHandle?
        var contiguous: UInt64
        /// Segments written beyond `contiguous` (offset → length), from out-of-order arrival.
        var ahead: [UInt64: UInt64] = [:]
        var checking = false
        var savedOffset: UInt64
        var savedAtNs: UInt64
    }

    private var active: Active?
    /// Recently saved transfers (id → shown name), so a repeated `FileBegin` after the end is answered.
    private var saved: [UInt32: String] = [:]
    private var savedOrder: [UInt32] = []
    /// A sent folder's top folder, mapped once per batch to a name not already in `root` ("Photos 2").
    private var batchRoots: [String: String] = [:]

    private var partialDir: URL { root.appendingPathComponent(".clamshell-partial", isDirectory: true) }

    public init(root: URL) {
        self.root = root
        cleanUpOldPartials()
    }

    // MARK: Messages from the sender

    public func handle(_ b: FileBegin, nowNs: UInt64) {
        if let name = saved[b.transferId] {
            send(FileProgress(transferId: b.transferId, confirmed: b.size, state: .saved, savedName: name).message)
            return
        }
        if var a = active, a.begin.transferId == b.transferId {
            // A repeat: the sender lost track (stall, new connection). Tell it where we are.
            if a.checking {
                send(FileProgress(transferId: b.transferId, confirmed: b.size, state: .checking).message)
            } else {
                a.ahead = [:]       // what's past the hole comes again
                active = a
                send(FileAccept(transferId: b.transferId, offset: a.contiguous).message)
            }
            return
        }
        guard accepting() else { send(FileAccept(transferId: b.transferId, status: .refused).message); return }
        guard let components = FileBegin.safeComponents(b.path) else {
            send(FileAccept(transferId: b.transferId, status: .badName).message); return
        }
        if let a = active, !a.checking { park(a) }
        active = nil

        let key = b.sha256.map { String(format: "%02x", $0) }.joined() + "-\(b.size)"
        let partURL = partialDir.appendingPathComponent(key + ".part")
        let offsetURL = partialDir.appendingPathComponent(key + ".offset")
        let fm = FileManager.default
        var offset: UInt64 = 0
        if let text = try? String(contentsOf: offsetURL, encoding: .utf8), let o = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let size = (try? fm.attributesOfItem(atPath: partURL.path))?[.size] as? NSNumber, o <= size.uint64Value, o <= b.size {
            offset = o
        }
        let needed = b.size - offset + spareBytes
        if let free = freeSpace?() ?? Self.freeSpace(at: root), free < needed {
            send(FileAccept(transferId: b.transferId, status: .noSpace).message); return
        }
        let handle: FileHandle
        do {
            try fm.createDirectory(at: partialDir, withIntermediateDirectories: true)
            if offset == 0 || !fm.fileExists(atPath: partURL.path) {
                offset = 0
                try Data().write(to: partURL)
            }
            handle = try FileHandle(forUpdating: partURL)
        } catch {
            send(FileAccept(transferId: b.transferId, status: .refused).message)
            setStatus(b, components: components, received: 0, state: .failed("couldn't write here: \(error.localizedDescription)"))
            return
        }
        // Touch it, so the week-old cleanup leaves a partial that's being resumed.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: partURL.path)
        let a = Active(begin: b, components: components, partURL: partURL, offsetURL: offsetURL, handle: handle,
                       contiguous: offset, savedOffset: offset, savedAtNs: nowNs)
        // A file still being checked can only be here if its sender gave up on it; this one takes over.
        active = a
        send(FileAccept(transferId: b.transferId, offset: offset).message)
        setStatus(b, components: components, received: offset, state: .receiving)
        if offset >= b.size { finish(nowNs: nowNs) }
    }

    public func handle(_ s: FileSegment, nowNs: UInt64) {
        guard var a = active, a.begin.transferId == s.transferId, !a.checking, let handle = a.handle else { return }
        let end = s.offset + UInt64(s.data.count)
        guard end <= a.begin.size else { return }
        if end > a.contiguous {
            do {
                try handle.seek(toOffset: s.offset)
                try handle.write(contentsOf: s.data)
            } catch {
                fail(&a, state: .writeFailed, note: "couldn't save \(displayName(a)): \(error.localizedDescription)")
                return
            }
            if s.offset <= a.contiguous {
                a.contiguous = end
                while let len = a.ahead.removeValue(forKey: a.contiguous) { a.contiguous += len }
                // Pieces now inside the confirmed range are no longer needed.
                a.ahead = a.ahead.filter { $0.key + $0.value > a.contiguous }
            } else {
                a.ahead[s.offset] = max(a.ahead[s.offset] ?? 0, UInt64(s.data.count))
            }
        }
        if a.contiguous - a.savedOffset >= 4 << 20 || nowNs >= a.savedAtNs + 1_000_000_000 {
            try? String(a.contiguous).write(to: a.offsetURL, atomically: true, encoding: .utf8)
            a.savedOffset = a.contiguous
            a.savedAtNs = nowNs
        }
        active = a
        send(FileProgress(transferId: a.begin.transferId, confirmed: a.contiguous).message)
        if status?.transferId == a.begin.transferId { status?.received = a.contiguous; onChange() }
        if a.contiguous >= a.begin.size { finish(nowNs: nowNs) }
    }

    /// The sender stopped a file or a batch. The partial copy stays, for a later resume.
    public func handle(_ c: FileCancel) {
        guard let a = active, !a.checking,
              a.begin.transferId == c.transferId || (c.transferId == 0 && c.batchId != 0 && a.begin.batchId == c.batchId) else { return }
        park(a)
        active = nil
        if var s = status, s.transferId == a.begin.transferId { s.state = .cancelled; status = s; onChange() }
    }

    /// Stops what's coming in (the user tapped Cancel). Asks the sender to stop the whole batch.
    public func cancel() {
        guard let a = active else { return }
        send(FileCancel(transferId: 0, batchId: a.begin.batchId).message)
        if !a.checking { park(a); active = nil }
        if var s = status { s.state = .cancelled; status = s; onChange() }
    }

    /// Closes the open file (the session ended). The partial stays, and the sender's next `FileBegin` resumes it.
    public func suspend() {
        guard let a = active, !a.checking else { return }
        park(a)
        active = nil
    }

    public var busy: Bool { active != nil }

    // MARK: Internals

    private func park(_ a: Active) {
        try? a.handle?.synchronize()
        try? a.handle?.close()
        try? String(a.contiguous).write(to: a.offsetURL, atomically: true, encoding: .utf8)
    }

    private func finish(nowNs: UInt64) {
        guard var a = active else { return }
        try? a.handle?.synchronize()
        try? a.handle?.close()
        a.handle = nil
        a.checking = true
        active = a
        send(FileProgress(transferId: a.begin.transferId, confirmed: a.begin.size, state: .checking).message)
        if var s = status, s.transferId == a.begin.transferId { s.state = .checking; s.received = a.begin.size; status = s; onChange() }
        let url = a.partURL, expected = a.begin.sha256
        Task.detached(priority: .utility) {
            let ok = (try? FileListing.sha256(of: url)) == expected
            await MainActor.run { [weak self] in self?.checked(ok, transferId: a.begin.transferId) }
        }
    }

    private func checked(_ ok: Bool, transferId: UInt32) {
        guard var a = active, a.begin.transferId == transferId, a.checking else { return }
        let fm = FileManager.default
        guard ok else {
            try? fm.removeItem(at: a.partURL)
            try? fm.removeItem(at: a.offsetURL)
            active = nil
            send(FileProgress(transferId: transferId, confirmed: 0, state: .damaged).message)
            setStatus(a.begin, components: a.components, received: 0, state: .failed("\(displayName(a)) arrived damaged; sending it again"))
            return
        }
        do {
            let dest = try destination(for: a)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: a.partURL, to: dest)
            try? fm.removeItem(at: a.offsetURL)
            if a.begin.modified > 0 {
                try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(a.begin.modified))], ofItemAtPath: dest.path)
            }
            let shown = shownPath(dest)
            remember(transferId, shown)
            active = nil
            send(FileProgress(transferId: transferId, confirmed: a.begin.size, state: .saved, savedName: shown).message)
            setStatus(a.begin, components: a.components, received: a.begin.size, state: .saved(shown))
            onSaved(dest)
        } catch {
            a.checking = false
            fail(&a, state: .writeFailed, note: "couldn't save \(displayName(a)): \(error.localizedDescription)")
        }
    }

    private func fail(_ a: inout Active, state: FileProgress.State, note: String) {
        park(a)
        active = nil
        send(FileProgress(transferId: a.begin.transferId, confirmed: a.contiguous, state: state).message)
        setStatus(a.begin, components: a.components, received: a.contiguous, state: .failed(note))
    }

    /// Where the file goes: `root/name`, or `root/Folder/sub/name` for a file of a sent folder, never over an
    /// existing file ("name 2.ext"), and a batch's top folder never merged into an existing one.
    private func destination(for a: Active) throws -> URL {
        var parts = a.components
        if parts.count > 1 {
            let top = parts[0]
            let key = "\(a.begin.batchId)/\(top)"
            if let mapped = batchRoots[key] {
                parts[0] = mapped
            } else {
                let mapped = Self.unusedURL(in: root, name: top).lastPathComponent
                batchRoots[key] = mapped
                if batchRoots.count > 256 { batchRoots.removeAll(); batchRoots[key] = mapped }
                parts[0] = mapped
            }
        }
        var dir = root
        for p in parts.dropLast() { dir.appendPathComponent(p, isDirectory: true) }
        return Self.unusedURL(in: dir, name: parts[parts.count - 1])
    }

    private func shownPath(_ url: URL) -> String {
        let base = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return url.lastPathComponent }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    private func displayName(_ a: Active) -> String { a.components.last ?? "the file" }

    private func remember(_ id: UInt32, _ name: String) {
        saved[id] = name
        savedOrder.append(id)
        if savedOrder.count > 256 { saved[savedOrder.removeFirst()] = nil }
    }

    private func setStatus(_ b: FileBegin, components: [String], received: UInt64, state: State) {
        status = Status(transferId: b.transferId, batchId: b.batchId, name: components.last ?? "file", index: b.index,
                        count: b.count, size: b.size, received: received, state: state)
        onChange()
    }

    private func cleanUpOldPartials() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: partialDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        for url in items {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < weekAgo { try? fm.removeItem(at: url) }
        }
    }

    public static func freeSpace(at url: URL) -> UInt64? {
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let n = v.volumeAvailableCapacityForImportantUsage, n > 0 else { return nil }
        return UInt64(n)
    }

    /// `dir/name`, or `dir/name 2.ext`, `dir/name 3.ext`… whichever doesn't exist yet.
    public static func unusedURL(in dir: URL, name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        let ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
