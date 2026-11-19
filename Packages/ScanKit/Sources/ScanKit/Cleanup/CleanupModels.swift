import Foundation

public enum CleanupCategory: String, CaseIterable, Sendable, Identifiable {
    case caches
    case developer
    case downloads
    case leftovers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .caches: "Caches & Logs"
        case .developer: "Developer"
        case .downloads: "Old Downloads"
        case .leftovers: "App Leftovers"
        }
    }

    public var summary: String {
        switch self {
        case .caches:
            "App caches, logs and package manager caches. They're rebuilt when needed; quit apps before removing their caches."
        case .developer:
            "Xcode build products, archives, device support files and simulators."
        case .downloads:
            "Items in your Downloads folder, dated by when they were downloaded."
        case .leftovers:
            "Files that look like they belong to apps that are no longer installed. Review before removing."
        }
    }
}

public enum CleanupAction: Sendable, Hashable {
    case moveToTrash
    /// Deleted with `xcrun simctl delete`, so CoreSimulator stays consistent.
    case deleteSimulator(udid: String)
}

public struct CleanupItem: Sendable, Hashable, Identifiable {
    public let url: URL
    public let title: String
    public let detail: String?
    public let allocatedSize: Int64
    public let fileCount: Int
    /// Download date for downloads; otherwise the newest modification inside.
    public let date: Date?
    public let action: CleanupAction

    public var id: URL { url }
}

public struct CleanupGroup: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let note: String?
    /// Largest first.
    public let items: [CleanupItem]

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.allocatedSize } }

    func removing(_ urls: Set<URL>) -> CleanupGroup? {
        let remaining = items.filter { !urls.contains($0.url) }
        guard !remaining.isEmpty else { return nil }
        return CleanupGroup(id: id, title: title, note: note, items: remaining)
    }
}

public struct CleanupReport: Sendable {
    public let category: CleanupCategory
    public let groups: [CleanupGroup]

    public var items: [CleanupItem] { groups.flatMap(\.items) }
    public var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }

    public func removing(_ urls: Set<URL>) -> CleanupReport {
        CleanupReport(category: category, groups: groups.compactMap { $0.removing(urls) })
    }
}

public struct CleanupContext: Sendable {
    public var home: URL
    /// Whether to look inside ~/Library/Containers and Group Containers. Without
    /// Full Disk Access, macOS asks the user for permission per app.
    public var includeAppContainers: Bool
    public var installedApps: InstalledApps

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        includeAppContainers: Bool = false,
        installedApps: InstalledApps
    ) {
        self.home = home
        self.includeAppContainers = includeAppContainers
        self.installedApps = installedApps
    }
}
