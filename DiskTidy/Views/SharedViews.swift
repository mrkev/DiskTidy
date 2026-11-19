import AppKit
import ScanKit
import SwiftUI

struct FileIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: 16, height: 16)
    }
}

struct FileNameCell: View {
    let file: FileEntry

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(path: file.path)
            Text(file.name).lineLimit(1).truncationMode(.middle)
        }
        .help(file.path)
    }
}

struct FileRow: View {
    let file: FileEntry

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(path: file.path)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text(file.displayParentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(file.modificationDate, format: .dateTime.year().month(.abbreviated).day())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(file.path)
    }
}

struct FileContextMenu: View {
    @Environment(AppModel.self) private var model
    let urls: Set<URL>
    let onTrash: () -> Void

    var body: some View {
        if !urls.isEmpty {
            Button("Show in Finder") { model.reveal(urls) }
            if urls.count == 1, let url = urls.first {
                Button("Open") { NSWorkspace.shared.open(url) }
            }
            Button("Copy Path") {
                let paths = urls.map { $0.path(percentEncoded: false) }.sorted().joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paths, forType: .string)
            }
            Divider()
            Button("Move to Trash…", role: .destructive, action: onTrash)
        }
    }
}

struct SelectionBar: View {
    let count: Int
    let bytes: Int64
    var warning: String?
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if count > 0 {
                Text("\(count.formatted()) selected · \(ByteSize.format(bytes))")
            } else {
                Text("Nothing selected").foregroundStyle(.secondary)
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Move to Trash…", action: onTrash)
                .disabled(count == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct EmptyResultsView: View {
    let hasScanned: Bool
    let emptyTitle: String
    var emptyDetail: String?

    var body: some View {
        if hasScanned {
            ContentUnavailableView(
                emptyTitle,
                systemImage: "checkmark.circle",
                description: emptyDetail.map { Text($0) }
            )
        } else {
            ContentUnavailableView(
                "No Scan Yet",
                systemImage: "magnifyingglass",
                description: Text("Choose folders in the toolbar and click Scan.")
            )
        }
    }
}

extension View {
    /// Confirms before moving files to the Trash. Set `pending` to ask.
    func trashConfirmation(
        pending: Binding<Set<URL>?>,
        warning: @escaping (Set<URL>) -> String? = { _ in nil },
        perform: @escaping (Set<URL>) -> Void
    ) -> some View {
        modifier(TrashConfirmation(pending: pending, warning: warning, perform: perform))
    }
}

private struct TrashConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var pending: Set<URL>?
    let warning: (Set<URL>) -> String?
    let perform: (Set<URL>) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Move \(pending?.count ?? 0) item(s) to the Trash?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { urls in
            Button("Move to Trash", role: .destructive) { perform(urls) }
        } message: { urls in
            let base = "Frees up to \(ByteSize.format(model.size(of: urls))) once the Trash is emptied."
            Text([warning(urls), base].compactMap { $0 }.joined(separator: "\n\n"))
        }
    }
}
