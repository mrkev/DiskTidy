import Foundation

/// Identifies the underlying file on disk. Hard links share an identity.
public struct FileIdentity: Hashable, Sendable {
    public let device: Int32
    public let inode: UInt64
}

/// A regular file found during a scan.
public struct FileEntry: Hashable, Sendable, Identifiable {
    public let url: URL
    /// Length of the file's contents in bytes (what `ls -l` shows).
    public let logicalSize: Int64
    /// Bytes actually allocated on disk (what deleting it could free, ignoring clones).
    public let allocatedSize: Int64
    public let modificationDate: Date
    public let identity: FileIdentity
    public let linkCount: Int

    public init(
        url: URL,
        logicalSize: Int64,
        allocatedSize: Int64,
        modificationDate: Date,
        identity: FileIdentity,
        linkCount: Int
    ) {
        self.url = url
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modificationDate = modificationDate
        self.identity = identity
        self.linkCount = linkCount
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    public var path: String { url.path(percentEncoded: false) }
    public var parentPath: String { url.deletingLastPathComponent().path(percentEncoded: false) }
    /// Parent folder with the home directory shortened to `~`.
    public var displayParentPath: String { (parentPath as NSString).abbreviatingWithTildeInPath }
}

public enum ByteSize {
    /// Formats bytes the way Finder does (decimal units).
    public static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false  // "0 bytes", not "Zero KB"
        return formatter.string(fromByteCount: bytes)
    }

    /// Parses sizes like `2048`, `500KB`, `100M`, `1.5GB`. Uses decimal units to match `format`.
    public static func parse(_ text: String) -> Int64? {
        var s = text.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasSuffix("B") { s.removeLast() }
        let multipliers: [Character: Double] = ["K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12]
        var multiplier = 1.0
        if let last = s.last, let m = multipliers[last] {
            multiplier = m
            s.removeLast()
        }
        guard let value = Double(s), value >= 0 else { return nil }
        return Int64(value * multiplier)
    }
}
