import ScanKit
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<URL>()
    @State private var pendingTrash: Set<URL>?
    @State private var preview: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !model.duplicateGroups.isEmpty {
                    Text("\(model.duplicateGroups.count.formatted()) groups · \(ByteSize.format(model.duplicateReclaimableBytes)) reclaimable")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select Extra Copies") { selectExtraCopies() }
                    .help("Selects every copy except the oldest in each group")
                    .disabled(model.duplicateGroups.isEmpty)
                Button("Deselect All") { selection.removeAll() }
                    .disabled(selection.isEmpty)
            }
            .padding(10)
            Divider()

            if model.duplicateGroups.isEmpty {
                EmptyResultsView(
                    hasScanned: model.hasScanned,
                    emptyTitle: "No Duplicates",
                    emptyDetail: "Files under \(ByteSize.format(model.settings.duplicateMinimumSize)) aren't compared."
                )
            } else {
                List(selection: $selection) {
                    ForEach(model.duplicateGroups) { group in
                        Section {
                            ForEach(group.files) { file in
                                FileRow(file: file)
                            }
                        } header: {
                            DuplicateGroupHeader(group: group)
                        }
                    }
                }
                .contextMenu(forSelectionType: URL.self) { urls in
                    FileContextMenu(
                        urls: urls,
                        onQuickLook: { preview = orderedURLs().first(where: urls.contains) },
                        onRemove: { pendingTrash = urls }
                    )
                } primaryAction: { urls in
                    model.reveal(urls)
                }
                .quickLook(selection: selection, orderedURLs: orderedURLs, preview: $preview)
            }

            Divider()
            SelectionBar(
                count: selection.count,
                bytes: model.size(of: selection),
                warning: fullySelectedGroupCount > 0
                    ? "Every copy is selected in \(fullySelectedGroupCount) group(s)"
                    : nil,
                onRemove: { pendingTrash = selection }
            )
        }
        .trashConfirmation(pending: $pendingTrash, bytes: model.size(of:), warning: warning(for:)) { urls in
            preview = nil
            model.moveToTrash(urls)
            selection.subtract(urls)
        }
    }

    private func orderedURLs() -> [URL] {
        model.duplicateGroups.flatMap { $0.files.map(\.url) }
    }

    private var fullySelectedGroupCount: Int {
        groupsFullyCovered(by: selection)
    }

    private func groupsFullyCovered(by urls: Set<URL>) -> Int {
        guard !urls.isEmpty else { return 0 }
        return model.duplicateGroups.count { group in group.files.allSatisfy { urls.contains($0.url) } }
    }

    private func warning(for urls: Set<URL>) -> String? {
        let count = groupsFullyCovered(by: urls)
        guard count > 0 else { return nil }
        return "This includes every copy of \(count) file(s). No copy of those will be left outside the Trash."
    }

    /// Keeps the oldest copy in each group (files are sorted oldest first).
    private func selectExtraCopies() {
        selection = Set(model.duplicateGroups.flatMap { $0.files.dropFirst().map(\.url) })
    }
}

struct DuplicateGroupHeader: View {
    let group: DuplicateGroup

    var body: some View {
        HStack(spacing: 6) {
            Text(group.files.first?.name ?? "")
            Text("· \(group.files.count) copies × \(ByteSize.format(group.fileSize))")
                .foregroundStyle(.secondary)
            if group.sharesStorage {
                Text("Clones")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help("Some copies are APFS clones that already share disk space.")
            }
            Spacer()
            Text("Reclaim \(ByteSize.format(group.reclaimableBytes))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
