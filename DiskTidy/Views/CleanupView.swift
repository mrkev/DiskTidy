import ScanKit
import SwiftUI

struct CleanupView: View {
    let category: CleanupCategory

    @Environment(AppModel.self) private var model
    @State private var selection = Set<URL>()
    @State private var pendingRemoval: Set<URL>?
    @State private var preview: URL?
    @AppStorage("downloadsMinimumAgeDays") private var minimumAgeDays = 90

    private static let ageChoices = [30, 90, 180, 365]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            SelectionBar(
                count: selection.count,
                bytes: bytes(of: selection),
                actionTitle: "Remove…",
                onRemove: { pendingRemoval = selection }
            )
        }
        .trashConfirmation(
            pending: $pendingRemoval,
            actionTitle: "Remove",
            bytes: bytes(of:),
            warning: warning(for:)
        ) { urls in
            preview = nil
            model.clean(urls, in: category)
            selection.subtract(urls)
        }
        .task {
            if model.cleanup[category] == nil { model.scanCleanup(category) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Capped at two lines: unbounded wrapping text makes the view's
            // minimum height huge and pushes the whole window layout out of frame.
            Text(category.summary)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if category == .downloads {
                Picker("Older than", selection: $minimumAgeDays) {
                    ForEach(Self.ageChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
                .fixedSize()
            }
            if let report = model.cleanupReport(for: category) {
                Text(ByteSize.format(groups(in: report).reduce(0) { $0 + $1.totalSize }))
                    .font(.headline)
                    .monospacedDigit()
            }
            Button("Refresh", systemImage: "arrow.clockwise") {
                selection.removeAll()
                model.scanCleanup(category)
            }
            .labelStyle(.iconOnly)
            .disabled(isScanning)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if let report = model.cleanupReport(for: category), !isScanning {
            let groups = groups(in: report)
            if groups.isEmpty {
                ContentUnavailableView("Nothing to Clean Up", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { CleanupRow(item: $0) }
                        } header: {
                            CleanupGroupHeader(group: group) {
                                selection.formUnion(group.items.map(\.url))
                            }
                        }
                    }
                }
                .contextMenu(forSelectionType: URL.self) { urls in
                    FileContextMenu(
                        urls: urls,
                        removeTitle: "Remove…",
                        onQuickLook: { preview = groups.flatMap(\.items).first { urls.contains($0.url) }?.url },
                        onRemove: { pendingRemoval = urls }
                    )
                } primaryAction: { urls in
                    model.reveal(urls)
                }
                .quickLook(
                    selection: selection,
                    orderedURLs: { groups.flatMap { $0.items.map(\.url) } },
                    preview: $preview
                )
            }
        } else {
            ProgressView("Measuring…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isScanning: Bool {
        if case .scanning = model.cleanup[category] { return true }
        return false
    }

    /// Downloads are filtered by age; other categories show everything.
    private func groups(in report: CleanupReport) -> [CleanupGroup] {
        guard category == .downloads else { return report.groups }
        let cutoff = Calendar.current.date(byAdding: .day, value: -minimumAgeDays, to: .now) ?? .now
        return report.groups.compactMap { group in
            let items = group.items.filter { ($0.date ?? .distantPast) < cutoff }
            return items.isEmpty ? nil : CleanupGroup(id: group.id, title: group.title, note: group.note, items: items)
        }
    }

    private func bytes(of urls: Set<URL>) -> Int64 {
        guard let report = model.cleanupReport(for: category) else { return 0 }
        return report.items.reduce(0) { urls.contains($1.url) ? $0 + $1.allocatedSize : $0 }
    }

    private func warning(for urls: Set<URL>) -> String? {
        guard let report = model.cleanupReport(for: category) else { return nil }
        let simulators = report.items.filter {
            if case .deleteSimulator = $0.action { return urls.contains($0.url) }
            return false
        }
        guard !simulators.isEmpty else { return nil }
        return "\(simulators.count) simulator(s) will be deleted permanently with simctl. Everything else goes to the Trash."
    }
}

struct CleanupGroupHeader: View {
    let group: CleanupGroup
    let selectAll: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                if let note = group.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(ByteSize.format(group.totalSize))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Select All", action: selectAll)
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}

struct CleanupRow: View {
    let item: CleanupItem

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(path: item.url.path(percentEncoded: false))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let date = item.date {
                Text(date, format: .dateTime.year().month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(ByteSize.format(item.allocatedSize))
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
        }
        .help(item.url.path(percentEncoded: false))
    }
}
