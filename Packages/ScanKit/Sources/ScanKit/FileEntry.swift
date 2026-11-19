import Foundation

/// Identifies the underlying file on disk. Hard links share an identity.
public struct FileIdentity: Hashable, Sendable {
    public let device: Int32
    public let inode: UInt64
}

/// A file found during a scan, or a package/folder reported as a single item.
public struct FileEntry: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case file
        /// A bundle like `.app` or `.photoslibrary`, measured as a whole.
        case package
        /// A grouped folder like `node_modules`, measured as a whole.
        case folder
    }

    public let url: URL
    /// Length of the file's contents in bytes (what `ls -l` shows).
    public let logicalSize: Int64
    /// Bytes actually allocated on disk (what deleting it could free, ignoring clones).
    public let allocatedSize: Int64
    public let modificationDate: Date
    public let identity: FileIdentity
    public let linkCount: Int
    public let kind: Kind
    /// Number of files inside, for packages and folders. 1 for files.
    public let fileCount: Int

    public init(
        url: URL,
        logicalSize: Int64,
        allocatedSize: Int64,
        modificationDate: Date,
        identity: FileIdentity,
        linkCount: Int,
        kind: Kind = .file,
        fileCount: Int = 1
    ) {
        self.url = url
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modificationDate = modificationDate
        self.identity = identity
        self.linkCount = linkCount
        self.kind = kind
        self.fileCount = fileCount
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    /// Path without a trailing slash, also for packages and folders.
    public var path: String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
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
