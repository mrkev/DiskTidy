import Darwin
import Foundation

/// One entry of a directory, as returned by getattrlistbulk(2).
struct DirectoryEntry {
    enum Kind { case file, directory, other }

    var name = ""
    var kind = Kind.other
    var device: Int32 = 0
    var fileID: UInt64 = 0
    var modificationDate = Date.distantPast
    var flags: UInt32 = 0
    var linkCount: UInt32 = 1
    var logicalSize: Int64 = 0
    var allocatedSize: Int64 = 0

    var isHidden: Bool { name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0 }
}

/// Sizes summed over a directory tree.
public struct TreeSize: Sendable, Hashable {
    public var logicalSize: Int64 = 0
    public var allocatedSize: Int64 = 0
    public var fileCount = 0
    public var newestModification: Date?
    public var errorCount = 0

    public init() {}

    mutating func add(_ entry: DirectoryEntry) {
        logicalSize += entry.logicalSize
        allocatedSize += entry.allocatedSize
        fileCount += 1
        if newestModification.map({ entry.modificationDate > $0 }) ?? true {
            newestModification = entry.modificationDate
        }
    }
}

/// Reads directories with getattrlistbulk(2): one syscall returns names, types,
/// sizes and dates for many entries at once, which is several times faster than
/// enumerating with FileManager and calling lstat per file.
///
/// Not thread-safe: each thread should use its own reader (it owns a buffer).
final class BulkReader {
    private let buffer: UnsafeMutableRawBufferPointer
    private var request = attrlist()

    init(bufferSize: Int = 128 * 1024) {
        buffer = .allocate(byteCount: bufferSize, alignment: 16)
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = bits(ATTR_CMN_RETURNED_ATTRS) | bits(ATTR_CMN_NAME) | bits(ATTR_CMN_ERROR)
            | bits(ATTR_CMN_DEVID) | bits(ATTR_CMN_OBJTYPE) | bits(ATTR_CMN_MODTIME)
            | bits(ATTR_CMN_FLAGS) | bits(ATTR_CMN_FILEID)
        request.fileattr = bits(ATTR_FILE_LINKCOUNT) | bits(ATTR_FILE_TOTALSIZE) | bits(ATTR_FILE_ALLOCSIZE)
    }

    deinit { buffer.deallocate() }

    /// Calls `body` for every entry in the directory at `path`.
    /// Returns false if the directory couldn't be fully read.
    @discardableResult
    func forEachEntry(in path: String, _ body: (DirectoryEntry) -> Void) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var complete = true
        while true {
            let count = getattrlistbulk(fd, &request, buffer.baseAddress!, buffer.count, 0)
            if count == 0 { break }
            if count < 0 {
                complete = false
                break
            }
            var entryStart = buffer.baseAddress!
            for _ in 0..<count {
                let length = entryStart.loadUnaligned(as: UInt32.self)
                if let entry = parse(entryStart) {
                    body(entry)
                } else {
                    complete = false
                }
                entryStart += Int(length)
            }
        }
        return complete
    }

    /// Total size of a file or directory tree. Symlinks are not followed.
    func measure(_ path: String, shouldStop: () -> Bool = { false }) -> TreeSize {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            var size = TreeSize()
            size.errorCount = 1
            return size
        }
        switch st.st_mode & S_IFMT {
        case S_IFREG:
            var size = TreeSize()
            var entry = DirectoryEntry()
            entry.logicalSize = Int64(st.st_size)
            entry.allocatedSize = Int64(st.st_blocks) * 512
            entry.modificationDate = Date(timespec: st.st_mtimespec)
            size.add(entry)
            return size
        case S_IFDIR:
            return measureTree(path, shouldStop: shouldStop)
        default:
            return TreeSize()
        }
    }

    /// Sums every regular file below `root` (hidden ones included).
    func measureTree(
        _ root: String,
        shouldStop: () -> Bool = { false },
        afterDirectory: (_ files: Int, _ bytes: Int64) -> Void = { _, _ in }
    ) -> TreeSize {
        var size = TreeSize()
        var stack = [root]
        while let directory = stack.popLast() {
            if shouldStop() { break }
            let before = (size.fileCount, size.allocatedSize)
            let ok = forEachEntry(in: directory) { entry in
                switch entry.kind {
                case .file: size.add(entry)
                case .directory: stack.append(joinPath(directory, entry.name))
                case .other: break
                }
            }
            if !ok { size.errorCount += 1 }
            afterDirectory(size.fileCount - before.0, size.allocatedSize - before.1)
        }
        return size
    }

    // Layout of each entry: u_int32_t length, attribute_set_t returned, then the
    // returned attributes in a fixed order (ERROR first, then by bit value),
    // each 4-byte aligned. See getattrlistbulk(2).
    private func parse(_ start: UnsafeMutableRawPointer) -> DirectoryEntry? {
        var p = start + 4
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr
        let file = returned.fileattr

        if common & bits(ATTR_CMN_ERROR) != 0 {
            let error = p.loadUnaligned(as: UInt32.self)
            p += 4
            if error != 0 { return nil }
        }

        var entry = DirectoryEntry()
        if common & bits(ATTR_CMN_NAME) != 0 {
            let reference = p.loadUnaligned(as: attrreference_t.self)
            entry.name = String(cString: (p + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
            p += MemoryLayout<attrreference_t>.size
        }
        if common & bits(ATTR_CMN_DEVID) != 0 {
            entry.device = p.loadUnaligned(as: Int32.self)
            p += 4
        }
        if common & bits(ATTR_CMN_OBJTYPE) != 0 {
            switch p.loadUnaligned(as: UInt32.self) {
            case 1: entry.kind = .file  // VREG
            case 2: entry.kind = .directory  // VDIR
            default: entry.kind = .other  // VLNK, devices, sockets…
            }
            p += 4
        }
        if common & bits(ATTR_CMN_MODTIME) != 0 {
            entry.modificationDate = Date(timespec: p.loadUnaligned(as: timespec.self))
            p += MemoryLayout<timespec>.size
        }
        if common & bits(ATTR_CMN_FLAGS) != 0 {
            entry.flags = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if common & bits(ATTR_CMN_FILEID) != 0 {
            entry.fileID = p.loadUnaligned(as: UInt64.self)
            p += 8
        }
        if file & bits(ATTR_FILE_LINKCOUNT) != 0 {
            entry.linkCount = p.loadUnaligned(as: UInt32.self)
            p += 4
        }
        if file & bits(ATTR_FILE_TOTALSIZE) != 0 {
            entry.logicalSize = p.loadUnaligned(as: Int64.self)
            p += 8
        }
        if file & bits(ATTR_FILE_ALLOCSIZE) != 0 {
            entry.allocatedSize = p.loadUnaligned(as: Int64.self)
            p += 8
        }
        return entry
    }
}

@inline(__always)
private func bits<T: BinaryInteger>(_ value: T) -> attrgroup_t {
    attrgroup_t(truncatingIfNeeded: value)
}

func joinPath(_ directory: String, _ name: String) -> String {
    directory.hasSuffix("/") ? directory + name : directory + "/" + name
}

extension Date {
    init(timespec ts: timespec) {
        self.init(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9)
    }
}

/// Runs blocking work on a Dispatch queue so it never ties up Swift's
/// cooperative thread pool.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}
