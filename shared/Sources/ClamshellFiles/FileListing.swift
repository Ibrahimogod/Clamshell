import ClamshellWire
import CryptoKit
import Foundation

/// A file ready to send (protocol 1.9): where it is, the path it goes under on the other side, and its hash.
public struct OutgoingFile: Sendable, Equatable {
    public var url: URL
    /// The wire path: "name.ext", or "Folder/sub/name.ext" for a file inside a picked folder.
    public var path: String
    public var size: UInt64
    public var sha256: [UInt8]
    /// Unix seconds, 0 when unknown.
    public var modified: UInt64

    public init(url: URL, path: String, size: UInt64, sha256: [UInt8], modified: UInt64 = 0) {
        self.url = url; self.path = path; self.size = size; self.sha256 = sha256; self.modified = modified
    }

    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// Turns what someone picked (files and folders) into the files to send.
public enum FileListing {
    /// Files as themselves; folders as every regular file inside, at any depth, under "Folder/…". Hidden
    /// files (".DS_Store", ".git"), symbolic links and anything unreadable are left out. Sorted by path, so a
    /// folder arrives in a predictable order.
    public static func expand(_ urls: [URL]) -> [(url: URL, path: String, size: UInt64, modified: UInt64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        var out: [(URL, String, UInt64, UInt64)] = []
        func entry(_ url: URL, path: String) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true, v.isRegularFile == true else { return }
            out.append((url, path, UInt64(max(v.fileSize ?? 0, 0)), UInt64(max(v.contentModificationDate?.timeIntervalSince1970 ?? 0, 0))))
        }
        for url in urls {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { continue }
            guard v?.isDirectory == true else { entry(url, path: url.lastPathComponent); continue }
            let root = url.lastPathComponent
            let base = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var inside: [(URL, String)] = []
            for case let child as URL in walker {
                let parts = child.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { continue }
                inside.append((child, ([root] + parts.dropFirst(base.count)).joined(separator: "/")))
            }
            for (child, path) in inside.sorted(by: { $0.1 < $1.1 }) { entry(child, path: path) }
        }
        return out.map { (url: $0.0, path: $0.1, size: $0.2, modified: $0.3) }
    }

    /// SHA-256 of a file, read 1 MiB at a time.
    public static func sha256(of url: URL) throws -> [UInt8] {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let data = try h.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return Array(hasher.finalize())
    }

    /// `expand` plus a hash of each file. Slow for big files: call it off the main actor.
    public static func prepare(_ urls: [URL]) throws -> [OutgoingFile] {
        try expand(urls).map { f in
            OutgoingFile(url: f.url, path: f.path, size: f.size, sha256: try sha256(of: f.url), modified: f.modified)
        }
    }

    /// Reads `count` bytes at `offset` (fewer at the end of the file); nil if the file can't be read.
    public static func read(_ url: URL, offset: UInt64, count: Int) -> [UInt8]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: offset)) != nil, let data = try? h.read(upToCount: count) else { return nil }
        return [UInt8](data)
    }

    /// "1.4 GB", "340 KB".
    public static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
