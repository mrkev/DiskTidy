import Foundation
import Testing
@testable import ScanKit

/// The temporary directory is itself one of Time Machine's built-in exclusions,
/// so unflagged items there are `.excludedBySystem` rather than `.included`.
private let unflagged: Set<BackupStatus> = [.included, .excludedBySystem]

@Suite struct BackupExclusionTests {
    @Test func togglesStickyExclusion() async throws {
        let dir = try TempDir()
        let file = try dir.write("a.bin", bytes(1, count: 10))
        let baseline = BackupExclusion.status(of: file)
        #expect(unflagged.contains(baseline))

        #expect(await BackupExclusion.setExcluded(true, for: [file]).isEmpty)
        #expect(BackupExclusion.status(of: file) == .excluded)

        #expect(await BackupExclusion.setExcluded(false, for: [file]).isEmpty)
        #expect(BackupExclusion.status(of: file) == baseline)
    }

    @Test func reportsExcludedFolder() async throws {
        let dir = try TempDir()
        let folder = dir.url.appending(path: "sub", directoryHint: .isDirectory)
        let file = try dir.write("sub/deeper/a.bin", bytes(1, count: 10))
        let other = try dir.write("b.bin", bytes(2, count: 10))

        #expect(await BackupExclusion.setExcluded(true, for: [folder]).isEmpty)
        let statuses = await BackupExclusion.status(of: [file, other, folder])
        #expect(statuses[folder] == .excluded)
        #expect(statuses[other].map(unflagged.contains) == true)
        guard case .excludedByFolder(let excludedBy) = statuses[file] else {
            Issue.record("expected excludedByFolder, got \(String(describing: statuses[file]))")
            return
        }
        #expect(excludedBy.standardizedFileURL.path(percentEncoded: false).hasSuffix("/sub/"))
        #expect(statuses[file]?.canToggle == false)
    }

    @Test func reportsFailures() async {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let failures = await BackupExclusion.setExcluded(true, for: [missing])
        #expect(failures[missing] != nil)
    }
}

@Suite struct SystemBackupExclusionTests {
    /// ~/Library/Caches is one of Time Machine's built-in exclusions.
    @Test func reportsBuiltInExclusions() async throws {
        let caches = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let statuses = await BackupExclusion.status(of: [caches])
        #expect(statuses[caches] == .excludedBySystem)
    }
}
