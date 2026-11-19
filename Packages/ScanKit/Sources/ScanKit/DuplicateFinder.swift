import CryptoKit
import Foundation

public struct DuplicateOptions: Sendable {
    /// Files smaller than this are ignored. Empty files are always ignored.
    public var minimumSize: Int64
    /// Bytes hashed from each end of a file in the quick pass.
    public var partialChunkSize: Int
    public var maxConcurrency: Int

    public init(
        minimumSize: Int64 = 1,
        partialChunkSize: Int = 16 * 1024,
        maxConcurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount)
    ) {
        self.minimumSize = minimumSize
        self.partialChunkSize = partialChunkSize
        self.maxConcurrency = maxConcurrency
    }
}

public struct DuplicateProgress: Sendable {
    public enum Stage: Sendable {
        /// Hashing the first and last chunk of same-size files.
        case quickPass
        /// Hashing whole files that survived the quick pass.
        case verifying
    }

    public var stage: Stage
    public var completed: Int
    public var total: Int

    public var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

/// A set of files with identical contents.
public struct DuplicateGroup: Hashable, Sendable, Identifiable {
    public let id: String
    /// Logical size of each copy.
    public let fileSize: Int64
    /// Oldest first.
    public let files: [FileEntry]
    /// Estimated bytes freed by keeping one copy. APFS clones that already
    /// share storage are counted once.
    public let reclaimableBytes: Int64
    /// True when some copies are APFS clones of each other.
    public let sharesStorage: Bool

    init(id: String, fileSize: Int64, files: [FileEntry]) {
        let sorted = files.sorted { $0.modificationDate < $1.modificationDate }
        var cloneFamilies = Set<UInt64>()
        var independentCopies = 0
        for file in sorted {
            if let info = CloneInspector.info(for: file.url), info.mayShareBlocks, info.cloneID != 0 {
                cloneFamilies.insert(info.cloneID)
            } else {
                independentCopies += 1
            }
        }
        let storageUnits = cloneFamilies.count + independentCopies
        let perCopy = sorted.map(\.allocatedSize).max() ?? fileSize

        self.id = id
        self.fileSize = fileSize
        self.files = sorted
        self.reclaimableBytes = Int64(max(storageUnits - 1, 0)) * perCopy
        self.sharesStorage = storageUnits < sorted.count
    }

    /// The group without `urls`, or nil if fewer than two copies remain.
    public func removing(_ urls: Set<URL>) -> DuplicateGroup? {
        let remaining = files.filter { !urls.contains($0.url) }
        guard remaining.count > 1 else { return nil }
        if remaining.count == files.count { return self }
        return DuplicateGroup(id: id, fileSize: fileSize, files: remaining)
    }
}

public enum DuplicateFinder {
    /// Finds files with identical contents:
    /// 1. group by size (and collapse hard links),
    /// 2. hash the first and last chunk of each candidate,
    /// 3. fully hash files that still match.
    /// Unreadable files are skipped. Supports task cancellation.
    public static func find(
        in files: [FileEntry],
        options: DuplicateOptions = DuplicateOptions(),
        progress: (@Sendable (DuplicateProgress) -> Void)? = nil
    ) async throws -> [DuplicateGroup] {
        let chunk = options.partialChunkSize
        let minimumSize = max(1, options.minimumSize)

        // 1. Size buckets. Hard links are the same file, not duplicates.
        var byIdentity: [FileIdentity: FileEntry] = [:]
        for file in files where file.logicalSize >= minimumSize && byIdentity[file.identity] == nil {
            byIdentity[file.identity] = file
        }
        let sameSize = Dictionary(grouping: byIdentity.values, by: \.logicalSize)
            .values
            .filter { $0.count > 1 }
            .flatMap { $0 }

        // 2. Quick pass. For small files this already covers the whole file.
        let partial = try await hashAll(sameSize, stage: .quickPass, options: options, progress: progress) {
            try Hashing.partialHash(of: $0.url, size: $0.logicalSize, chunk: chunk)
        }

        var confirmed: [[(FileEntry, String)]] = []
        var needsFullHash: [FileEntry] = []
        for group in matchingGroups(partial) {
            if group[0].0.logicalSize <= Int64(chunk * 2) {
                confirmed.append(group)
            } else {
                needsFullHash.append(contentsOf: group.map(\.0))
            }
        }

        // 3. Full verification.
        let full = try await hashAll(needsFullHash, stage: .verifying, options: options, progress: progress) {
            try Hashing.fullHash(of: $0.url)
        }
        confirmed.append(contentsOf: matchingGroups(full))

        try Task.checkCancellation()
        return confirmed
            .map { group in
                let size = group[0].0.logicalSize
                return DuplicateGroup(id: "\(size)-\(group[0].1)", fileSize: size, files: group.map(\.0))
            }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    private struct HashKey: Hashable {
        let size: Int64
        let digest: String
    }

    private static func matchingGroups(_ hashed: [(FileEntry, String)]) -> [[(FileEntry, String)]] {
        Dictionary(grouping: hashed) { HashKey(size: $0.0.logicalSize, digest: $0.1) }
            .values
            .filter { $0.count > 1 }
    }

    /// Hashes files with bounded concurrency. Files that fail to hash are dropped.
    private static func hashAll(
        _ files: [FileEntry],
        stage: DuplicateProgress.Stage,
        options: DuplicateOptions,
        progress: (@Sendable (DuplicateProgress) -> Void)?,
        hash: @escaping @Sendable (FileEntry) throws -> String
    ) async throws -> [(FileEntry, String)] {
        guard !files.isEmpty else { return [] }
        var results: [(FileEntry, String)] = []
        results.reserveCapacity(files.count)
        var completed = 0
        progress?(DuplicateProgress(stage: stage, completed: 0, total: files.count))

        try await withThrowingTaskGroup(of: (FileEntry, String?).self) { group in
            var pending = files.makeIterator()
            for _ in 0..<max(1, options.maxConcurrency) {
                guard let file = pending.next() else { break }
                group.addTask { (file, try? hash(file)) }
            }
            while let (file, digest) = try await group.next() {
                completed += 1
                if let digest { results.append((file, digest)) }
                if completed % 100 == 0 || completed == files.count {
                    progress?(DuplicateProgress(stage: stage, completed: completed, total: files.count))
                }
                try Task.checkCancellation()
                if let next = pending.next() {
                    group.addTask { (next, try? hash(next)) }
                }
            }
        }
        return results
    }
}

enum Hashing {
    static let readSize = 1 << 20

    /// SHA-256 of the first and last `chunk` bytes, or of the whole file if it's
    /// no larger than `2 * chunk`.
    static func partialHash(of url: URL, size: Int64, chunk: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        if size <= Int64(chunk * 2) {
            while let data = try handle.read(upToCount: chunk * 2), !data.isEmpty {
                hasher.update(data: data)
            }
        } else {
            if let head = try handle.read(upToCount: chunk) { hasher.update(data: head) }
            try handle.seek(toOffset: UInt64(size) - UInt64(chunk))
            if let tail = try handle.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().hexString
    }

    static func fullHash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: readSize), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().hexString
    }
}

extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
