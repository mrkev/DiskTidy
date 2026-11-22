import CoreServices
import Darwin
import Foundation

/// Whether Time Machine backs up an item.
public enum BackupStatus: Sendable, Hashable {
    case included
    /// The item itself carries the sticky exclusion flag, so it can be toggled.
    case excluded
    /// An enclosing folder carries the exclusion flag.
    case excludedByFolder(URL)
    /// Excluded by path, e.g. in Time Machine settings. Changing that needs admin rights.
    case excludedByPath
    /// Time Machine's built-in exclusions (caches, temporary files, cloud storage, …).
    case excludedBySystem

    public var isExcluded: Bool { self != .included }
    /// Only the item's own sticky flag can be changed here.
    public var canToggle: Bool { self == .included || self == .excluded }
}

/// Reads and sets Time Machine exclusions.
///
/// Exclusions set here are "sticky": stored as an extended attribute on the item
/// (like `tmutil addexclusion` without `-p`), so they follow it when moved and need no admin rights.
public enum BackupExclusion {
    static let attributeName = "com.apple.metadata:com_apple_backup_excludeItem"

    public static func status(of urls: [URL]) async -> [URL: BackupStatus] {
        await runBlocking {
            var folders: [String: Bool] = [:]
            var result: [URL: BackupStatus] = [:]
            result.reserveCapacity(urls.count)
            for url in urls {
                result[url] = status(of: url, folderCache: &folders)
            }
            let included = urls.filter { result[$0] == .included }
            for url in systemExcluded(included) {
                result[url] = .excludedBySystem
            }
            return result
        }
    }

    public static func status(of url: URL) -> BackupStatus {
        var folders: [String: Bool] = [:]
        let status = status(of: url, folderCache: &folders)
        if status == .included, !systemExcluded([url]).isEmpty { return .excludedBySystem }
        return status
    }

    /// Sets or clears the item's own exclusion flag. Returns error messages for items that failed.
    public static func setExcluded(_ excluded: Bool, for urls: [URL]) async -> [URL: String] {
        await runBlocking {
            var failures: [URL: String] = [:]
            for url in urls {
                var values = URLResourceValues()
                values.isExcludedFromBackup = excluded
                var target = url
                do {
                    try target.setResourceValues(values)
                } catch {
                    failures[url] = error.localizedDescription
                }
            }
            return failures
        }
    }

    // MARK: Private

    private static func status(of url: URL, folderCache: inout [String: Bool]) -> BackupStatus {
        if hasStickyFlag(url) { return .excluded }
        // Covers sticky flags on ancestors and path-based exclusions (on the item or an ancestor).
        guard CSBackupIsItemExcluded(url as CFURL, nil) else { return .included }

        var folder = url.deletingLastPathComponent()
        while true {
            let path = folder.path(percentEncoded: false)
            let flagged = folderCache[path] ?? {
                let value = hasStickyFlag(folder)
                folderCache[path] = value
                return value
            }()
            if flagged { return .excludedByFolder(folder) }
            if path == "/" { break }
            folder = folder.deletingLastPathComponent()
        }
        return .excludedByPath
    }

    /// The items Time Machine skips because of its built-in rules. Those live in a private
    /// framework that `CSBackupIsItemExcluded` doesn't consult, so ask `tmutil isexcluded`,
    /// which does (about 0.5 ms per path, batched).
    private static func systemExcluded(_ urls: [URL]) -> Set<URL> {
        var excluded = Set<URL>()
        for chunk in stride(from: 0, to: urls.count, by: 256).map({ urls[$0..<min($0 + 256, urls.count)] }) {
            var byPath: [String: URL] = [:]
            for url in chunk {
                var path = url.path(percentEncoded: false)
                if path.count > 1, path.hasSuffix("/") { path.removeLast() }
                byPath[path] = url
            }
            guard let output = run("/usr/bin/tmutil", ["isexcluded"] + byPath.keys) else { continue }
            // Lines look like "[Excluded]  /path/to/item".
            for line in output.split(separator: "\n") where line.hasPrefix("[Excluded]") {
                let path = line.dropFirst("[Excluded]".count).trimmingPrefix(while: { $0 == " " })
                if let url = byPath[String(path)] { excluded.insert(url) }
            }
        }
        return excluded
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting so a full pipe can't block the child.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func hasStickyFlag(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }
}
