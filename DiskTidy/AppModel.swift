import AppKit
import Observation
import ScanKit

enum SidebarItem: Hashable, Identifiable {
    case largeFiles
    case duplicates
    case cleanup(CleanupCategory)

    static let scanItems: [SidebarItem] = [.largeFiles, .duplicates]
    static let cleanupItems: [SidebarItem] = CleanupCategory.allCases.map { .cleanup($0) }

    var id: Self { self }

    var title: String {
        switch self {
        case .largeFiles: "Large Files"
        case .duplicates: "Duplicates"
        case .cleanup(let category): category.title
        }
    }

    var systemImage: String {
        switch self {
        case .largeFiles: "externaldrive"
        case .duplicates: "doc.on.doc"
        case .cleanup(.caches): "archivebox"
        case .cleanup(.developer): "hammer"
        case .cleanup(.downloads): "arrow.down.circle"
        case .cleanup(.leftovers): "shippingbox"
        }
    }
}

enum ScanPhase: Equatable {
    case idle
    case scanning(filesVisited: Int)
    case comparing(label: String, fraction: Double?)

    var description: String {
        switch self {
        case .idle: ""
        case .scanning(let count): "Scanning… \(count.formatted()) files"
        case .comparing(let label, _): label
        }
    }
}

enum CleanupState {
    case scanning
    case loaded(CleanupReport)
}

/// User preferences for folder scans, persisted in UserDefaults.
struct ScanSettings: Codable, Equatable {
    var includeHidden = true
    var treatPackagesAsItems = true
    var groupDeveloperFolders = true
    var excludedFolders: [String] = []
    var duplicateMinimumSize: Int64 = 1_000_000

    static let duplicateSizeChoices: [Int64] = [100_000, 1_000_000, 10_000_000, 100_000_000]
}

@Observable
final class AppModel {
    static let largeFileThresholds: [Int64] = [10_000_000, 50_000_000, 100_000_000, 500_000_000, 1_000_000_000]

    var roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser]
    var selection: SidebarItem? = .largeFiles
    var largeFileThreshold: Int64 = 100_000_000 {
        didSet { recomputeLargeFiles() }
    }
    var settings: ScanSettings {
        didSet { saveSettings() }
    }

    private(set) var phase: ScanPhase = .idle
    private(set) var hasScanned = false
    private(set) var largeFiles: [FileEntry] = []
    private(set) var duplicateGroups: [DuplicateGroup] = []
    private(set) var summary: String?
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted
    private(set) var cleanup: [CleanupCategory: CleanupState] = [:]
    var lastError: String?

    /// Items at least as big as the smallest threshold any view needs.
    private var scannedItems: [FileEntry] = []
    private var scanTask: Task<Void, Never>?
    private var installedApps: InstalledApps?

    private static let settingsKey = "scanSettings"

    init() {
        settings = UserDefaults.standard.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(ScanSettings.self, from: $0) } ?? ScanSettings()
    }

    var isBusy: Bool { phase != .idle }

    var rootsTitle: String {
        guard roots.count == 1, let root = roots.first else { return "\(roots.count) Folders" }
        if root == FileManager.default.homeDirectoryForCurrentUser { return "Home" }
        return FileManager.default.displayName(atPath: root.path(percentEncoded: false))
    }

    var duplicateReclaimableBytes: Int64 {
        duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    // MARK: Folder scan

    /// Scans dropped folders (files are ignored). Returns false if nothing usable was dropped.
    func scanDropped(_ urls: [URL]) -> Bool {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        guard !folders.isEmpty, !isBusy else { return false }
        roots = folders
        startScan()
        return true
    }

    func chooseRoots() {
        guard let urls = chooseFolders(message: "Choose the folders to scan.", startingAt: roots.first) else { return }
        roots = urls
    }

    func startScan() {
        cancelScan()
        let roots = roots
        let settings = settings
        let options = ScanOptions(
            includeHidden: settings.includeHidden,
            treatPackagesAsItems: settings.treatPackagesAsItems,
            groupedFolderNames: settings.groupDeveloperFolders ? ScanOptions.developerFolderNames : [],
            excludedPaths: ScanOptions.defaultExcludedPaths + settings.excludedFolders,
            minimumRetainedSize: min(settings.duplicateMinimumSize, Self.largeFileThresholds.min() ?? 0)
        )
        let duplicateOptions = DuplicateOptions(minimumSize: settings.duplicateMinimumSize)
        phase = .scanning(filesVisited: 0)

        scanTask = Task {
            do {
                let scan = try await FileScanner.scan(roots: roots, options: options) { progress in
                    Task { @MainActor [weak self] in self?.update(progress) }
                }
                scannedItems = scan.items
                recomputeLargeFiles()
                duplicateGroups = []
                hasScanned = true
                phase = .comparing(label: "Looking for duplicates…", fraction: nil)

                duplicateGroups = try await DuplicateFinder.find(in: scan.items, options: duplicateOptions) { progress in
                    Task { @MainActor [weak self] in self?.update(progress) }
                }

                summary = String(
                    format: "%@ files · %@ · %.1fs",
                    scan.fileCount.formatted(),
                    ByteSize.format(scan.totalAllocatedSize),
                    scan.elapsed
                ) + (scan.errorCount > 0 ? " · \(scan.errorCount.formatted()) unreadable" : "")
            } catch is CancellationError {
                summary = "Scan stopped"
            } catch {
                lastError = error.localizedDescription
            }
            phase = .idle
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    private func update(_ progress: ScanProgress) {
        // Progress arrives from several threads, so it can be out of order.
        guard case .scanning(let shown) = phase, progress.filesVisited > shown else { return }
        phase = .scanning(filesVisited: progress.filesVisited)
    }

    private func update(_ progress: DuplicateProgress) {
        guard case .comparing = phase else { return }
        let label = switch progress.stage {
        case .quickPass: "Comparing files…"
        case .verifying: "Verifying duplicates…"
        }
        phase = .comparing(label: label, fraction: progress.fraction)
    }

    private func recomputeLargeFiles() {
        largeFiles = LargeFileFinder.find(in: scannedItems, minimumSize: largeFileThreshold)
    }

    func size(of urls: Set<URL>) -> Int64 {
        guard !urls.isEmpty else { return 0 }
        return scannedItems.reduce(Int64(0)) { total, item in
            urls.contains(item.url) ? total + item.allocatedSize : total
        }
    }

    func moveToTrash(_ urls: Set<URL>) {
        let outcome = Trash.moveToTrash(Array(urls))
        let trashed = Set(outcome.removed)
        scannedItems.removeAll { trashed.contains($0.url) }
        recomputeLargeFiles()
        duplicateGroups = duplicateGroups.compactMap { $0.removing(trashed) }
        showFailures(outcome.failures)
    }

    // MARK: Cleanup categories

    func cleanupReport(for category: CleanupCategory) -> CleanupReport? {
        if case .loaded(let report) = cleanup[category] { return report }
        return nil
    }

    func scanCleanup(_ category: CleanupCategory) {
        if case .scanning = cleanup[category] { return }
        cleanup[category] = .scanning
        let includeContainers = hasFullDiskAccess
        Task {
            let apps = await loadInstalledApps()
            let context = CleanupContext(includeAppContainers: includeContainers, installedApps: apps)
            cleanup[category] = .loaded(await CleanupScanner.scan(category, context: context))
        }
    }

    func clean(_ urls: Set<URL>, in category: CleanupCategory) {
        guard let report = cleanupReport(for: category) else { return }
        let items = report.items.filter { urls.contains($0.url) }
        Task {
            let outcome = await Cleaner.perform(items)
            if let current = cleanupReport(for: category) {
                cleanup[category] = .loaded(current.removing(Set(outcome.removed)))
            }
            showFailures(outcome.failures)
        }
    }

    private func loadInstalledApps() async -> InstalledApps {
        if let installedApps { return installedApps }
        let apps = await Task.detached(priority: .userInitiated) { InstalledApps.discover() }.value
        installedApps = apps
        return apps
    }

    // MARK: Settings

    func addExcludedFolders() {
        guard let urls = chooseFolders(message: "Choose folders to leave out of scans.", startingAt: nil) else { return }
        let new = urls.map { $0.path(percentEncoded: false) }.filter { !settings.excludedFolders.contains($0) }
        settings.excludedFolders += new
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    // MARK: Helpers

    func reveal(_ urls: Set<URL>) {
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
    }

    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted
    }

    private func showFailures(_ failures: [URL: String]) {
        guard !failures.isEmpty else { return }
        let details = failures
            .sorted { $0.key.lastPathComponent < $1.key.lastPathComponent }
            .prefix(5)
            .map { "\($0.key.lastPathComponent): \($0.value)" }
            .joined(separator: "\n")
        lastError = "Couldn't remove \(failures.count) item(s).\n\n\(details)"
    }

    private func chooseFolders(message: String, startingAt directory: URL?) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = message
        panel.directoryURL = directory
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls
    }
}

enum FullDiskAccess {
    /// The TCC database is only readable by processes with Full Disk Access.
    static var isGranted: Bool {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
