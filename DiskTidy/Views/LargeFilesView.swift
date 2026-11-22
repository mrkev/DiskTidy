import ScanKit
import SwiftUI

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<URL>()
    @State private var sortOrder = [KeyPathComparator(\FileEntry.allocatedSize, order: .reverse)]
    @State private var pendingTrash: Set<URL>?
    @State private var preview: URL?
    /// Column order, widths and visibility. Right-click the header to show or hide columns,
    /// drag headers to reorder. Saved across launches.
    @State private var columns = TableColumnCustomization<FileEntry>()
    @AppStorage("largeFilesColumns") private var savedColumns = Data()

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HStack {
                Picker("Larger than", selection: $model.largeFileThreshold) {
                    ForEach(AppModel.largeFileThresholds, id: \.self) { Text(ByteSize.format($0)).tag($0) }
                }
                .fixedSize()
                Spacer()
                if !model.largeFiles.isEmpty {
                    Text("\(model.largeFiles.count.formatted()) files · \(ByteSize.format(model.largeFiles.reduce(0) { $0 + $1.allocatedSize }))")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            Divider()

            if model.largeFiles.isEmpty {
                EmptyResultsView(hasScanned: model.hasScanned, emptyTitle: "Nothing Large Found")
            } else {
                Table(sortedFiles, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
                    TableColumn("Name", value: \.name) { file in
                        FileNameCell(file: file)
                    }
                    .width(min: 160, ideal: 260)
                    .customizationID("name")
                    .disabledCustomizationBehavior(.visibility)
                    TableColumn("Kind") { file in
                        Text(file.kindDescription)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 80, ideal: 150)
                    .customizationID("kind")
                    TableColumn("Location", value: \.parentPath) { file in
                        Text(file.displayParentPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.parentPath)
                    }
                    .customizationID("location")
                    TableColumn("Size", value: \.allocatedSize) { file in
                        Text(ByteSize.format(file.allocatedSize)).monospacedDigit()
                    }
                    .width(min: 70, ideal: 90)
                    .customizationID("size")
                    TableColumn("Modified", value: \.modificationDate) { file in
                        Text(file.modificationDate, format: .dateTime.year().month(.abbreviated).day())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 110)
                    .customizationID("modified")
                    TableColumn("Backup") { file in
                        // Status and action are passed in: table rows can be built where the
                        // environment's AppModel isn't available.
                        BackupToggle(status: model.backupStatus[file.url]) { backUp in
                            model.setExcludedFromBackup(!backUp, for: [file.url])
                        }
                    }
                    .width(min: 50, ideal: 56, max: 70)
                    .alignment(.center)
                    .customizationID("backup")
                    .defaultVisibility(.hidden)
                }
                .contextMenu(forSelectionType: URL.self) { urls in
                    FileContextMenu(
                        urls: urls,
                        onQuickLook: { preview = sortedFiles.first { urls.contains($0.url) }?.url },
                        showsBackupOptions: showsBackupColumn,
                        onRemove: { pendingTrash = urls }
                    )
                } primaryAction: { urls in
                    model.reveal(urls)
                }
                .quickLook(selection: selection, orderedURLs: { sortedFiles.map(\.url) }, preview: $preview)
            }

            Divider()
            SelectionBar(
                count: selection.count,
                bytes: model.size(of: selection),
                onRemove: { pendingTrash = selection }
            )
        }
        .trashConfirmation(pending: $pendingTrash, bytes: model.size(of:)) { urls in
            preview = nil
            model.moveToTrash(urls)
            selection.subtract(urls)
        }
        .onAppear {
            if let saved = try? JSONDecoder().decode(TableColumnCustomization<FileEntry>.self, from: savedColumns) {
                columns = saved
            }
        }
        .onChange(of: columns) {
            savedColumns = (try? JSONEncoder().encode(columns)) ?? Data()
        }
        // Time Machine status is only looked up while its column is showing.
        .onChange(of: showsBackupColumn, initial: true) {
            model.tracksBackupStatus = showsBackupColumn
        }
    }

    private var showsBackupColumn: Bool {
        columns[visibility: "backup"] == .visible
    }

    private var sortedFiles: [FileEntry] {
        model.largeFiles.sorted(using: sortOrder)
    }
}

/// Checked while Time Machine backs the item up. Unchecking excludes it (a sticky exclusion that
/// follows the item when moved). Exclusions inherited from a folder or set in Time Machine settings
/// are shown but can't be changed here.
private struct BackupToggle: View {
    /// Nil until the status has been read.
    let status: BackupStatus?
    let onChange: (_ backUp: Bool) -> Void

    var body: some View {
        if let status {
            Toggle("Back Up with Time Machine", isOn: Binding(
                get: { !status.isExcluded },
                set: { onChange($0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!status.canToggle)
            .help(help(for: status))
        }
    }

    private func help(for status: BackupStatus) -> String {
        switch status {
        case .included:
            "Backed up by Time Machine. Uncheck to exclude it."
        case .excluded:
            "Excluded from Time Machine backups. Check to back it up again."
        case .excludedByFolder(let folder):
            "Excluded from Time Machine because its folder “\(folder.lastPathComponent)” is excluded."
        case .excludedByPath:
            "Excluded in Time Machine settings."
        case .excludedBySystem:
            "Time Machine always skips this location."
        }
    }
}
