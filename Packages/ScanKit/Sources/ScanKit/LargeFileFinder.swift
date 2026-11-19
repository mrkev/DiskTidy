import Foundation

public enum LargeFileFinder {
    /// Files whose on-disk size is at least `minimumSize`, largest first.
    /// Hard links to the same file are listed once.
    public static func find(in files: [FileEntry], minimumSize: Int64, limit: Int? = nil) -> [FileEntry] {
        var seen = Set<FileIdentity>()
        var result = files
            .filter { $0.allocatedSize >= minimumSize }
            .sorted { $0.allocatedSize > $1.allocatedSize }
            .filter { seen.insert($0.identity).inserted }
        if let limit, result.count > limit {
            result.removeSubrange(limit...)
        }
        return result
    }
}
