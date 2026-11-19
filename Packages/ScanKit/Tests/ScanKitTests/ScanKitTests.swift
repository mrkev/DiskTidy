import Darwin
import Foundation
import Testing
@testable import ScanKit

/// A temporary directory removed when the fixture is deinitialized.
final class TempDir {
    let url: URL

    init() throws {
        let requested = FileManager.default.temporaryDirectory
            .appending(path: "ScanKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        // Use the canonical path (/private/var/...) so URLs match what the scanner reports.
        url = URL(fileURLWithPath: FileScanner.canonicalPath(requested.path(percentEncoded: false)), isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ name: String, _ data: Data) throws -> URL {
        let file = url.appending(path: name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }
}

func bytes(_ seed: UInt8, count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed })
}

@Suite struct ByteSizeTests {
    @Test(arguments: [
        ("2048", Int64(2048)), ("500KB", 500_000), ("100M", 100_000_000),
        ("1.5GB", 1_500_000_000), (" 1 tb ", nil), ("abc", nil), ("-1MB", nil),
    ] as [(String, Int64?)])
    func parse(input: String, expected: Int64?) {
        #expect(ByteSize.parse(input) == expected)
    }
}

@Suite struct ScannerTests {
    @Test func findsRegularFilesAndSkipsSymlinks() async throws {
        let dir = try TempDir()
        let a = try dir.write("a.bin", bytes(1, count: 10))
        try dir.write("sub/b.bin", bytes(2, count: 20))
        try FileManager.default.createSymbolicLink(at: dir.url.appending(path: "link"), withDestinationURL: a)

        let result = try await FileScanner.scan(roots: [dir.url])
        #expect(Set(result.files.map(\.name)) == ["a.bin", "b.bin"])
    }

    @Test func nestedRootsAreNotCountedTwice() async throws {
        let dir = try TempDir()
        try dir.write("sub/b.bin", bytes(2, count: 20))

        let result = try await FileScanner.scan(roots: [dir.url, dir.url.appending(path: "sub")])
        #expect(result.files.count == 1)
    }

    @Test func excludedPathsAreSkippedUnlessTheyContainTheRoot() async throws {
        let dir = try TempDir()
        try dir.write("keep/a.bin", bytes(1, count: 10))
        try dir.write("skip/b.bin", bytes(2, count: 10))
        let root = dir.url.path(percentEncoded: false)

        let skipped = try await FileScanner.scan(
            roots: [dir.url], options: ScanOptions(excludedPaths: [root + "skip"])
        )
        #expect(skipped.files.map(\.name) == ["a.bin"])

        let containing = try await FileScanner.scan(
            roots: [dir.url], options: ScanOptions(excludedPaths: [root])
        )
        #expect(containing.files.count == 2)
    }
}

@Suite struct LargeFileTests {
    @Test func filtersSortsAndCollapsesHardLinks() async throws {
        let dir = try TempDir()
        let big = try dir.write("big.bin", bytes(1, count: 300_000))
        try dir.write("medium.bin", bytes(2, count: 120_000))
        try dir.write("small.bin", bytes(3, count: 1_000))
        try FileManager.default.linkItem(at: big, to: dir.url.appending(path: "big-link.bin"))

        let scan = try await FileScanner.scan(roots: [dir.url])
        let large = LargeFileFinder.find(in: scan.files, minimumSize: 100_000)
        #expect(large.count == 2)
        #expect(large.first?.logicalSize == 300_000)
        #expect(large.last?.name == "medium.bin")
    }
}

@Suite struct DuplicateTests {
    @Test func findsSmallAndLargeDuplicates() async throws {
        let dir = try TempDir()
        // Small files: decided by the quick pass alone.
        try dir.write("small-1.txt", bytes(7, count: 1_000))
        try dir.write("small-2.txt", bytes(7, count: 1_000))
        try dir.write("small-other.txt", bytes(8, count: 1_000))
        // Large files: same head and tail, different middle. Only the full hash tells them apart.
        var a = bytes(9, count: 200_000)
        try dir.write("large-1.bin", a)
        try dir.write("large-2.bin", a)
        a[100_000] ^= 0xFF
        try dir.write("large-different-middle.bin", a)

        let scan = try await FileScanner.scan(roots: [dir.url])
        let groups = try await DuplicateFinder.find(in: scan.files)

        let names = Set(groups.map { Set($0.files.map(\.name)) })
        #expect(names == [["small-1.txt", "small-2.txt"], ["large-1.bin", "large-2.bin"]])
    }

    @Test func hardLinksAreNotDuplicates() async throws {
        let dir = try TempDir()
        let file = try dir.write("a.bin", bytes(1, count: 5_000))
        try FileManager.default.linkItem(at: file, to: dir.url.appending(path: "b.bin"))

        let scan = try await FileScanner.scan(roots: [dir.url])
        #expect(try await DuplicateFinder.find(in: scan.files).isEmpty)
    }

    @Test func apfsClonesAreCountedOnce() async throws {
        let dir = try TempDir()
        let original = try dir.write("original.bin", bytes(4, count: 400_000))
        try dir.write("copy.bin", bytes(4, count: 400_000))
        let clone = dir.url.appending(path: "clone.bin")
        let status = original.withUnsafeFileSystemRepresentation { src in
            clone.withUnsafeFileSystemRepresentation { dst in clonefile(src!, dst!, 0) }
        }
        try #require(status == 0, "clonefile failed; temp dir is not on APFS")

        let scan = try await FileScanner.scan(roots: [dir.url])
        let groups = try await DuplicateFinder.find(in: scan.files)
        let group = try #require(groups.first)
        #expect(group.files.count == 3)
        #expect(group.sharesStorage)
        // original + clone share storage, copy is independent: deleting frees one copy's worth.
        #expect(group.reclaimableBytes == group.files[0].allocatedSize)
    }

    @Test func removingFilesShrinksOrDissolvesGroups() async throws {
        let dir = try TempDir()
        let urls = try (1...3).map { try dir.write("\($0).bin", bytes(5, count: 2_000)) }

        let scan = try await FileScanner.scan(roots: [dir.url])
        let group = try #require(try await DuplicateFinder.find(in: scan.files).first)
        #expect(group.removing([urls[0]])?.files.count == 2)
        #expect(group.removing([urls[0], urls[1]]) == nil)
    }
}
