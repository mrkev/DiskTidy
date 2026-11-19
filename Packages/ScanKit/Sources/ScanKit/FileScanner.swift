import Darwin
import Foundation

public struct ScanOptions: Sendable {
    /// Paths skipped by default: the sealed system volume, other mounted volumes,
    /// and virtual/system-managed locations. An exclusion is ignored when a scan
    /// root lives inside it (so scanning `/Volumes/External` still works).
    public static let defaultExcludedPaths = [
        "/System", "/Volumes", "/dev", "/net", "/Network", "/private/var/vm", "/cores",
    ]

    public var includeHidden: Bool
    /// When false, bundles such as `.app` and `.photoslibrary` are not entered,
    /// so files inside them can't be offered for deletion.
    public var descendIntoPackages: Bool
    public var excludedPaths: [String]

    public init(
        includeHidden: Bool = true,
        descendIntoPackages: Bool = false,
        excludedPaths: [String] = ScanOptions.defaultExcludedPaths
    ) {
        self.includeHidden = includeHidden
        self.descendIntoPackages = descendIntoPackages
        self.excludedPaths = excludedPaths
    }
}

public struct ScanProgress: Sendable {
    public var filesVisited = 0
    public var bytesSeen: Int64 = 0
    public var currentPath = ""
}

public struct ScanResult: Sendable {
    public let files: [FileEntry]
    /// Items that couldn't be read (permissions, TCC, vanished mid-scan).
    public let errorCount: Int
    public let elapsed: TimeInterval

    public var totalAllocatedSize: Int64 { files.reduce(0) { $0 + $1.allocatedSize } }
}

public enum FileScanner {
    /// Walks `roots` and returns every regular file. Symlinks are not followed.
    /// Runs off the caller's actor; supports task cancellation.
    public static func scan(
        roots: [URL],
        options: ScanOptions = ScanOptions(),
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {
        try scanSync(roots: roots, options: options, progress: progress)
    }

    static func scanSync(
        roots: [URL],
        options: ScanOptions,
        progress: (@Sendable (ScanProgress) -> Void)?
    ) throws -> ScanResult {
        let start = Date()
        let errors = Counter()
        var files: [FileEntry] = []
        var state = ScanProgress()

        let exclusionPaths = options.excludedPaths.map(canonicalPath)
        for root in normalizedRoots(roots) {
            try Task.checkCancellation()
            let rootPath = root.path(percentEncoded: false)
            let exclusions = exclusionPaths.filter { !isPath(rootPath, inside: $0) }

            // A root may itself be a file.
            var rootStat = stat()
            if lstat(rootPath, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFREG {
                files.append(makeEntry(url: root, stat: rootStat))
                continue
            }

            var enumOptions: FileManager.DirectoryEnumerationOptions = []
            if !options.includeHidden { enumOptions.insert(.skipsHiddenFiles) }
            if !options.descendIntoPackages { enumOptions.insert(.skipsPackageDescendants) }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [],
                options: enumOptions,
                errorHandler: { _, _ in
                    errors.increment()
                    return true
                }
            ) else {
                errors.increment()
                continue
            }

            while let url = enumerator.nextObject() as? URL {
                let path = url.path(percentEncoded: false)
                if exclusions.contains(where: { isPath(path, inside: $0) }) {
                    enumerator.skipDescendants()
                    continue
                }

                var st = stat()
                guard lstat(path, &st) == 0 else {
                    errors.increment()
                    continue
                }
                guard (st.st_mode & S_IFMT) == S_IFREG else { continue }

                let entry = makeEntry(url: url, stat: st)
                files.append(entry)

                state.filesVisited += 1
                state.bytesSeen += entry.allocatedSize
                if state.filesVisited % 5_000 == 0 {
                    try Task.checkCancellation()
                    state.currentPath = path
                    progress?(state)
                }
            }
        }

        progress?(state)
        return ScanResult(files: files, errorCount: errors.value, elapsed: Date().timeIntervalSince(start))
    }

    /// Resolves symlinks (e.g. `/var` -> `/private/var`) so roots and exclusions
    /// compare equal to the paths the enumerator reports. Unlike
    /// `URL.resolvingSymlinksInPath()`, this keeps the `/private` prefix.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Canonicalizes roots and drops ones nested inside others so nothing is counted twice.
    static func normalizedRoots(_ roots: [URL]) -> [URL] {
        let standardized = roots.map {
            URL(fileURLWithPath: canonicalPath($0.path(percentEncoded: false)))
        }
        return standardized.filter { candidate in
            let path = candidate.path(percentEncoded: false)
            return !standardized.contains { other in
                let otherPath = other.path(percentEncoded: false)
                return otherPath != path && isPath(path, inside: otherPath)
            }
        }
    }

    static func isPath(_ path: String, inside directory: String) -> Bool {
        let dir = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return path == dir || path.hasPrefix(dir + "/")
    }

    static func makeEntry(url: URL, stat st: stat) -> FileEntry {
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return FileEntry(
            url: url,
            logicalSize: Int64(st.st_size),
            allocatedSize: Int64(st.st_blocks) * 512,
            modificationDate: Date(timeIntervalSince1970: mtime),
            identity: FileIdentity(device: st.st_dev, inode: st.st_ino),
            linkCount: Int(st.st_nlink)
        )
    }
}

/// Thread-safe counter for the enumerator's error callback.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}
