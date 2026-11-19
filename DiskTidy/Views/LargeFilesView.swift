import ScanKit
import SwiftUI

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<URL>()
    @State private var sortOrder = [KeyPathComparator(\FileEntry.allocatedSize, order: .reverse)]
    @State private var pendingTrash: Set<URL>?

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
                Table(model.largeFiles.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { file in
                        FileNameCell(file: file)
                    }
                    .width(min: 160, ideal: 260)
                    TableColumn("Kind") { file in
                        Text(file.kindDescription)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 80, ideal: 150)
                    TableColumn("Location", value: \.parentPath) { file in
                        Text(file.displayParentPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.parentPath)
                    }
                    TableColumn("Size", value: \.allocatedSize) { file in
                        Text(ByteSize.format(file.allocatedSize)).monospacedDigit()
                    }
                    .width(min: 70, ideal: 90)
                    TableColumn("Modified", value: \.modificationDate) { file in
                        Text(file.modificationDate, format: .dateTime.year().month(.abbreviated).day())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 110)
                }
                .contextMenu(forSelectionType: URL.self) { urls in
                    FileContextMenu(urls: urls, onRemove: { pendingTrash = urls })
                } primaryAction: { urls in
                    model.reveal(urls)
                }
            }

            Divider()
            SelectionBar(
                count: selection.count,
                bytes: model.size(of: selection),
                onRemove: { pendingTrash = selection }
            )
        }
        .trashConfirmation(pending: $pendingTrash, bytes: model.size(of:)) { urls in
            model.moveToTrash(urls)
            selection.subtract(urls)
        }
    }
}
