import Foundation
import Testing
@testable import ScanKit

@Suite struct GroupingTests {
    @Test func packagesAreReportedAsOneItem() async throws {
        let dir = try TempDir()
        try dir.write("Tool.app/Contents/MacOS/Tool", bytes(1, count: 40_000))
        try dir.write("Tool.app/Contents/Resources/data.bin", bytes(2, count: 60_000))
        try dir.write("loose.bin", bytes(3, count: 1_000))

        let result = try await FileScanner.scan(roots: [dir.url])
        let package = try #require(result.items.first { $0.kind == .package })
        #expect(package.name == "Tool.app")
        #expect(package.fileCount == 2)
        #expect(package.logicalSize == 100_000)
        #expect(result.items.count == 2)  // Tool.app + loose.bin
        #expect(result.fileCount == 3)  // totals still include files inside

        let expanded = try await FileScanner.scan(roots: [dir.url], options: ScanOptions(treatPackagesAsItems: false))
        #expect(Set(expanded.items.map(\.name)) == ["Tool", "data.bin", "loose.bin"])
    }

    @Test func aPackageRootIsScannedInside() async throws {
        let dir = try TempDir()
        let app = dir.url.appending(path: "Tool.app")
        try dir.write("Tool.app/Contents/MacOS/Tool", bytes(1, count: 1_000))

        let result = try await FileScanner.scan(roots: [app])
        #expect(result.items.map(\.name) == ["Tool"])
    }

    @Test func developerFoldersAreGrouped() async throws {
        let dir = try TempDir()
        try dir.write("project/node_modules/a/index.js", bytes(1, count: 5_000))
        try dir.write("project/node_modules/b/index.js", bytes(1, count: 5_000))
        try dir.write("project/.git/objects/pack.pack", bytes(2, count: 9_000))
        try dir.write("project/src/main.js", bytes(3, count: 100))

        let result = try await FileScanner.scan(roots: [dir.url])
        let folders = result.items.filter { $0.kind == .folder }
        #expect(Set(folders.map(\.name)) == ["node_modules", ".git"])
        #expect(folders.first { $0.name == "node_modules" }?.fileCount == 2)
        #expect(result.items.contains { $0.name == "main.js" })

        // Identical files inside node_modules aren't offered as duplicates.
        #expect(try await DuplicateFinder.find(in: result.items).isEmpty)
    }

    @Test func hiddenFilesCanBeSkipped() async throws {
        let dir = try TempDir()
        try dir.write(".secret", bytes(1, count: 100))
        try dir.write(".hidden-dir/file", bytes(1, count: 100))
        try dir.write("visible", bytes(1, count: 100))

        let all = try await FileScanner.scan(roots: [dir.url])
        #expect(all.items.count == 3)
        let visible = try await FileScanner.scan(roots: [dir.url], options: ScanOptions(includeHidden: false))
        #expect(visible.items.map(\.name) == ["visible"])
    }

    @Test func smallItemsAreCountedButNotRetained() async throws {
        let dir = try TempDir()
        for i in 0..<50 { try dir.write("small/\(i).txt", bytes(UInt8(i), count: 500)) }
        try dir.write("big.bin", bytes(9, count: 200_000))

        let result = try await FileScanner.scan(roots: [dir.url], options: ScanOptions(minimumRetainedSize: 100_000))
        #expect(result.items.map(\.name) == ["big.bin"])
        #expect(result.fileCount == 51)
        #expect(result.totalAllocatedSize >= 200_000)
    }

    @Test func scanningIsCancellable() async throws {
        let dir = try TempDir()
        for i in 0..<200 { try dir.write("d\(i % 20)/\(i).txt", bytes(1, count: 10)) }

        let task = Task { try await FileScanner.scan(roots: [dir.url]) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func packageTypesAreRecognized() {
        let cache = PackageTypeCache()
        #expect(cache.isPackage(extension: "app"))
        #expect(cache.isPackage(extension: "photoslibrary"))
        #expect(cache.isPackage(extension: "xcarchive"))
        #expect(!cache.isPackage(extension: "txt"))
        #expect(!cache.isPackage(extension: "d"))
    }
}
