import Darwin
import Foundation
import Synchronization
import UniformTypeIdentifiers

public struct ScanOptions: Sendable {
    /// Paths skipped by default: the sealed system volume, other mounted volumes,
    /// and virtual/system-managed locations. An exclusion is ignored when a scan
    /// root lives inside it (so scanning `/Volumes/External` still works).
    public static let defaultExcludedPaths = [
        "/System", "/Volumes", "/dev", "/net", "/Network", "/private/var/vm", "/cores",
    ]

    /// Folders that are reported as one item instead of being scanned file by file.
    /// Their contents are generated or managed by tools, so individual files in
    /// them aren't meaningful cleanup candidates (and duplicates inside are noise).
    public static let developerFolderNames: Set<String> = [
        "node_modules", "bower_components", ".pnpm-store",
        ".git", ".hg", ".svn",
        "Pods", "Carthage", ".build", "DerivedData", ".swiftpm",
        ".gradle", "__pycache__", ".venv", "venv", ".tox", ".mypy_cache", ".pytest_cache",
        ".next", ".nuxt", ".turbo", ".parcel-cache", ".expo", ".angular",
    ]

    public var includeHidden: Bool
    /// Report bundles such as `.app` and `.photoslibrary` as one item with their
    /// total size. When false, their contents are scanned like normal folders.
    public var treatPackagesAsItems: Bool
    /// Folder names reported as one item (see `developerFolderNames`).
    public var groupedFolderNames: Set<String>
    public var excludedPaths: [String]
    /// Items smaller than this are counted in the totals but not returned.
    /// Keeps memory flat on scans of millions of files.
    public var minimumRetainedSize: Int64
    public var maxConcurrency: Int

    public init(
        includeHidden: Bool = true,
        treatPackagesAsItems: Bool = true,
        groupedFolderNames: Set<String> = ScanOptions.developerFolderNames,
        excludedPaths: [String] = ScanOptions.defaultExcludedPaths,
        minimumRetainedSize: Int64 = 0,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.includeHidden = includeHidden
        self.treatPackagesAsItems = treatPackagesAsItems
        self.groupedFolderNames = groupedFolderNames
        self.excludedPaths = excludedPaths
        self.minimumRetainedSize = minimumRetainedSize
        self.maxConcurrency = maxConcurrency
    }
}

public struct ScanProgress: Sendable {
    public var filesVisited = 0
    public var bytesSeen: Int64 = 0
    public var currentPath = ""
}

public struct ScanResult: Sendable {
    /// Files, packages and grouped folders at least `minimumRetainedSize` big.
    public let items: [FileEntry]
    /// Every regular file seen, including ones inside packages and grouped folders.
    public let fileCount: Int
    public let totalAllocatedSize: Int64
    /// Directories or entries that couldn't be read (permissions, TCC, vanished).
    public let errorCount: Int
    public let elapsed: TimeInterval
}

public enum FileScanner {
    /// Walks `roots` in parallel. Symlinks are not followed. Supports cancellation.
    public static func scan(
        roots: [URL],
        options: ScanOptions = ScanOptions(),
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {
        let start = Date()
        let rootPaths = normalizedRoots(roots.map { $0.path(percentEncoded: false) })
        let exclusions = options.excludedPaths
            .map(canonicalPath)
            .filter { exclusion in !rootPaths.contains { isPath($0, inside: exclusion) } }

        // Roots may be files.
        var rootItems: [FileEntry] = []
        var rootSize = TreeSize()
        var directories: [String] = []
        var rootErrors = 0
        for path in rootPaths {
            var st = stat()
            guard lstat(path, &st) == 0 else {
                rootErrors += 1
                continue
            }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                directories.append(path)
            case S_IFREG:
                let entry = FileEntry(path: path, stat: st)
                rootSize.fileCount += 1
                rootSize.allocatedSize += entry.allocatedSize
                if entry.isRetained(minimum: options.minimumRetainedSize) { rootItems.append(entry) }
            default:
                break
            }
        }

        let walk = ParallelWalk(options: options, exclusions: exclusions, directories: directories, progress: progress)
        await withTaskCancellationHandler {
            await runBlocking { walk.run() }
        } onCancel: {
            walk.cancel()
        }
        try Task.checkCancellation()

        let result = walk.result()
        progress?(ScanProgress(filesVisited: result.fileCount, bytesSeen: result.bytes, currentPath: ""))
        return ScanResult(
            items: rootItems + result.items,
            fileCount: rootSize.fileCount + result.fileCount,
            totalAllocatedSize: rootSize.allocatedSize + result.bytes,
            errorCount: rootErrors + result.errors,
            elapsed: Date().timeIntervalSince(start)
        )
    }

    /// Resolves symlinks (e.g. `/var` -> `/private/var`) so roots and exclusions
    /// compare equal to the paths the walker produces. Unlike
    /// `URL.resolvingSymlinksInPath()`, this keeps the `/private` prefix.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Canonicalizes roots and drops ones nested inside others so nothing is counted twice.
    static func normalizedRoots(_ paths: [String]) -> [String] {
        let canonical = Array(Set(paths.map(canonicalPath))).sorted()
        return canonical.filter { path in
            !canonical.contains { other in other != path && isPath(path, inside: other) }
        }
    }

    static func isPath(_ path: String, inside directory: String) -> Bool {
        let dir = directory.count > 1 && directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        if dir == "/" { return true }
        return path == dir || path.hasPrefix(dir + "/")
    }
}

/// Walks directory trees on several threads. Workers pull directories from a
/// shared stack and push the subdirectories they find. Packages and grouped
/// folders are measured whole by the worker that finds them.
private final class ParallelWalk: @unchecked Sendable {
    private let options: ScanOptions
    private let exclusions: [String]
    private let progress: (@Sendable (ScanProgress) -> Void)?
    private let packageTypes = PackageTypeCache()

    private let condition = NSCondition()
    private var pending: [String]  // guarded by condition
    private var active = 0  // guarded by condition
    private var items: [FileEntry] = []  // guarded by condition
    private var errors = 0  // guarded by condition

    private let cancelled = Atomic<Bool>(false)
    private let filesVisited = Atomic<Int>(0)
    private let bytesSeen = Atomic<Int64>(0)

    init(options: ScanOptions, exclusions: [String], directories: [String], progress: (@Sendable (ScanProgress) -> Void)?) {
        self.options = options
        self.exclusions = exclusions
        self.pending = directories
        self.progress = progress
    }

    func run() {
        guard !pending.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: max(1, options.maxConcurrency)) { _ in worker() }
    }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    func result() -> (items: [FileEntry], fileCount: Int, bytes: Int64, errors: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (items, filesVisited.load(ordering: .relaxed), bytesSeen.load(ordering: .relaxed), errors)
    }

    private var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    private func worker() {
        let reader = BulkReader()
        var found: [FileEntry] = []
        var failures = 0
        while let directory = nextDirectory() {
            var subdirectories: [String] = []
            visit(directory, reader: reader, found: &found, failures: &failures, subdirectories: &subdirectories)
            finish(adding: subdirectories)
        }
        condition.lock()
        items.append(contentsOf: found)
        errors += failures
        condition.unlock()
    }

    private func nextDirectory() -> String? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty && active > 0 && !isCancelled {
            condition.wait()
        }
        if isCancelled || pending.isEmpty {
            condition.broadcast()
            return nil
        }
        active += 1
        return pending.removeLast()
    }

    private func finish(adding subdirectories: [String]) {
        condition.lock()
        pending.append(contentsOf: subdirectories)
        active -= 1
        condition.broadcast()
        condition.unlock()
    }

    private func visit(
        _ directory: String,
        reader: BulkReader,
        found: inout [FileEntry],
        failures: inout Int,
        subdirectories: inout [String]
    ) {
        var grouped: [(path: String, entry: DirectoryEntry, kind: FileEntry.Kind)] = []
        var files = 0
        var bytes: Int64 = 0

        let ok = reader.forEachEntry(in: directory) { entry in
            if !options.includeHidden && entry.isHidden { return }
            let path = joinPath(directory, entry.name)
            switch entry.kind {
            case .file:
                files += 1
                bytes += entry.allocatedSize
                if max(entry.allocatedSize, entry.logicalSize) >= options.minimumRetainedSize {
                    found.append(FileEntry(path: path, entry: entry))
                }
            case .directory:
                if exclusions.contains(where: { FileScanner.isPath(path, inside: $0) }) { return }
                if let kind = groupKind(forDirectoryNamed: entry.name) {
                    grouped.append((path, entry, kind))
                } else {
                    subdirectories.append(path)
                }
            case .other:
                break
            }
        }
        if !ok { failures += 1 }
        record(files: files, bytes: bytes, path: directory)

        // Measured after the loop: the reader's buffer is busy during forEachEntry.
        for group in grouped {
            let size = reader.measureTree(group.path, shouldStop: { isCancelled }) { files, bytes in
                record(files: files, bytes: bytes, path: group.path)
            }
            failures += size.errorCount
            let item = FileEntry(
                url: URL(fileURLWithPath: group.path, isDirectory: true),
                logicalSize: size.logicalSize,
                allocatedSize: size.allocatedSize,
                modificationDate: max(size.newestModification ?? .distantPast, group.entry.modificationDate),
                identity: FileIdentity(device: group.entry.device, inode: group.entry.fileID),
                linkCount: 1,
                kind: group.kind,
                fileCount: size.fileCount
            )
            if item.isRetained(minimum: options.minimumRetainedSize) { found.append(item) }
        }
    }

    private func groupKind(forDirectoryNamed name: String) -> FileEntry.Kind? {
        if options.groupedFolderNames.contains(name) { return .folder }
        if options.treatPackagesAsItems, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let ext = name[name.index(after: dot)...]
            if !ext.isEmpty, packageTypes.isPackage(extension: String(ext)) { return .package }
        }
        return nil
    }

    private func record(files: Int, bytes: Int64, path: String) {
        guard files > 0 else { return }
        let count = filesVisited.wrappingAdd(files, ordering: .relaxed)
        let total = bytesSeen.wrappingAdd(bytes, ordering: .relaxed).newValue
        if count.oldValue / 5_000 != count.newValue / 5_000 {
            progress?(ScanProgress(filesVisited: count.newValue, bytesSeen: total, currentPath: path))
        }
    }
}

/// Caches whether a directory extension is a package type (`.app`, `.photoslibrary`, …).
final class PackageTypeCache: Sendable {
    private let cache = Mutex<[String: Bool]>([:])

    func isPackage(extension ext: String) -> Bool {
        let key = ext.lowercased()
        if let known = cache.withLock({ $0[key] }) { return known }
        let isPackage = UTType(filenameExtension: key, conformingTo: .directory)?.conforms(to: .package) ?? false
        cache.withLock { $0[key] = isPackage }
        return isPackage
    }
}

extension FileEntry {
    init(path: String, entry: DirectoryEntry) {
        self.init(
            url: URL(fileURLWithPath: path, isDirectory: false),
            logicalSize: entry.logicalSize,
            allocatedSize: entry.allocatedSize,
            modificationDate: entry.modificationDate,
            identity: FileIdentity(device: entry.device, inode: entry.fileID),
            linkCount: Int(entry.linkCount)
        )
    }

    init(path: String, stat st: stat) {
        self.init(
            url: URL(fileURLWithPath: path, isDirectory: false),
            logicalSize: Int64(st.st_size),
            allocatedSize: Int64(st.st_blocks) * 512,
            modificationDate: Date(timespec: st.st_mtimespec),
            identity: FileIdentity(device: st.st_dev, inode: st.st_ino),
            linkCount: Int(st.st_nlink)
        )
    }

    func isRetained(minimum: Int64) -> Bool {
        max(allocatedSize, logicalSize) >= minimum
    }
}
