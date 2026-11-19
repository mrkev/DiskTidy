import AppKit
import ScanKit
import SwiftUI
import UniformTypeIdentifiers

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

extension FileEntry {
    /// "Package · 43,419 files", "Folder · 12 files", or the file type ("MPEG-4 movie").
    var kindDescription: String {
        switch kind {
        case .package: "Package · \(fileCount.formatted()) files"
        case .folder: "Folder · \(fileCount.formatted()) files"
        case .file: UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? "Document"
        }
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
    var removeTitle = "Move to Trash…"
    let onRemove: () -> Void

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
            Button(removeTitle, role: .destructive, action: onRemove)
        }
    }
}

struct SelectionBar: View {
    let count: Int
    let bytes: Int64
    var warning: String?
    var actionTitle = "Move to Trash…"
    let onRemove: () -> Void

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
            Button(actionTitle, action: onRemove)
                .disabled(count == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct EmptyResultsView: View {
    @Environment(AppModel.self) private var model
    let hasScanned: Bool
    let emptyTitle: String
    var emptyDetail: String?

    var body: some View {
        Group {
            if model.isBusy {
                ProgressView(model.phase.description)
            } else if hasScanned {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "checkmark.circle",
                    description: emptyDetail.map { Text($0) }
                )
            } else {
                ContentUnavailableView {
                    Label("No Scan Yet", systemImage: "magnifyingglass")
                } description: {
                    Text(model.roots.count == 1
                        ? "Scan your \(model.rootsTitle) folder, choose other folders, or drop folders here."
                        : "Scan the \(model.roots.count) chosen folders, choose others, or drop folders here.")
                } actions: {
                    Button("Scan \(model.rootsTitle)") { model.startScan() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button("Choose Folders…") { model.chooseRoots() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Confirms before removing items. Set `pending` to ask.
    func trashConfirmation(
        pending: Binding<Set<URL>?>,
        actionTitle: String = "Move to Trash",
        bytes: @escaping (Set<URL>) -> Int64,
        warning: @escaping (Set<URL>) -> String? = { _ in nil },
        perform: @escaping (Set<URL>) -> Void
    ) -> some View {
        modifier(RemovalConfirmation(
            pending: pending, actionTitle: actionTitle, bytes: bytes, warning: warning, perform: perform
        ))
    }
}

private struct RemovalConfirmation: ViewModifier {
    @Binding var pending: Set<URL>?
    let actionTitle: String
    let bytes: (Set<URL>) -> Int64
    let warning: (Set<URL>) -> String?
    let perform: (Set<URL>) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "\(actionTitle) \(pending?.count ?? 0) item(s)?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { urls in
            Button(actionTitle, role: .destructive) { perform(urls) }
        } message: { urls in
            let base = "Frees up to \(ByteSize.format(bytes(urls))) once the Trash is emptied."
            Text([warning(urls), base].compactMap { $0 }.joined(separator: "\n\n"))
        }
    }
}
