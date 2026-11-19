import AppKit
import Observation
import ScanKit

enum SidebarItem: String, CaseIterable, Identifiable {
    case largeFiles
    case duplicates

    var id: Self { self }

    var title: String {
        switch self {
        case .largeFiles: "Large Files"
        case .duplicates: "Duplicates"
        }
    }

    var systemImage: String {
        switch self {
        case .largeFiles: "externaldrive"
        case .duplicates: "doc.on.doc"
        }
    }
}

enum ScanPhase: Equatable {
    case idle
    case scanning(filesVisited: Int)
    case comparing(label: String, fraction: Double?)
}

@Observable
final class AppModel {
    var roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser]
    var selection: SidebarItem? = .largeFiles
    var largeFileThreshold: Int64 = 100_000_000 {
        didSet { recomputeLargeFiles() }
    }
    /// Smaller duplicates are ignored. Lots of tiny dupes is mostly noise.
    let duplicateMinimumSize: Int64 = 1_000_000

    private(set) var phase: ScanPhase = .idle
    private(set) var hasScanned = false
    private(set) var largeFiles: [FileEntry] = []
    private(set) var duplicateGroups: [DuplicateGroup] = []
    private(set) var summary: String?
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted
    var lastError: String?

    private var scannedFiles: [FileEntry] = []
    private var scanTask: Task<Void, Never>?

    var isBusy: Bool { phase != .idle }

    var rootsTitle: String {
        guard roots.count == 1, let root = roots.first else { return "\(roots.count) Folders" }
        if root == FileManager.default.homeDirectoryForCurrentUser { return "Home" }
        return FileManager.default.displayName(atPath: root.path(percentEncoded: false))
    }

    var duplicateReclaimableBytes: Int64 {
        duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    // MARK: Scanning

    func chooseRoots() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose the folders to scan."
        panel.directoryURL = roots.first
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        roots = panel.urls
    }

    func startScan() {
        cancelScan()
        let roots = roots
        let duplicateOptions = DuplicateOptions(minimumSize: duplicateMinimumSize)
        phase = .scanning(filesVisited: 0)

        scanTask = Task {
            do {
                let scan = try await FileScanner.scan(roots: roots) { progress in
                    Task { @MainActor [weak self] in self?.update(progress) }
                }
                scannedFiles = scan.files
                recomputeLargeFiles()
                duplicateGroups = []
                hasScanned = true
                phase = .comparing(label: "Looking for duplicates…", fraction: nil)

                duplicateGroups = try await DuplicateFinder.find(in: scan.files, options: duplicateOptions) { progress in
                    Task { @MainActor [weak self] in self?.update(progress) }
                }

                summary = String(
                    format: "%@ files · %@ · %.1fs",
                    scan.files.count.formatted(),
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
        guard case .scanning = phase else { return }
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
        largeFiles = LargeFileFinder.find(in: scannedFiles, minimumSize: largeFileThreshold)
    }

    // MARK: Actions

    func size(of urls: Set<URL>) -> Int64 {
        guard !urls.isEmpty else { return 0 }
        return scannedFiles.reduce(Int64(0)) { total, file in
            urls.contains(file.url) ? total + file.allocatedSize : total
        }
    }

    func moveToTrash(_ urls: Set<URL>) {
        let outcome = Trash.moveToTrash(Array(urls))
        let trashed = Set(outcome.trashed)
        scannedFiles.removeAll { trashed.contains($0.url) }
        recomputeLargeFiles()
        duplicateGroups = duplicateGroups.compactMap { $0.removing(trashed) }
        if !outcome.failures.isEmpty {
            let names = outcome.failures.keys.map(\.lastPathComponent).sorted().prefix(5).joined(separator: ", ")
            lastError = "Couldn't move \(outcome.failures.count) item(s) to the Trash: \(names)"
        }
    }

    func reveal(_ urls: Set<URL>) {
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
    }

    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted
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
