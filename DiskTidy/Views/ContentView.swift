import AppKit
import ScanKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Scan") {
                    ForEach(SidebarItem.scanItems) { item in
                        Label(item.title, systemImage: item.systemImage).badge(badge(for: item))
                    }
                }
                Section("Clean Up") {
                    ForEach(SidebarItem.cleanupItems) { item in
                        Label(item.title, systemImage: item.systemImage).badge(badge(for: item))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                if !model.hasFullDiskAccess {
                    FullDiskAccessBanner()
                    Divider()
                }
                Group {
                    switch model.selection ?? .largeFiles {
                    case .largeFiles:
                        LargeFilesView()
                    case .duplicates:
                        DuplicatesView()
                    case .cleanup(let category):
                        CleanupView(category: category).id(category)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !isCleanupSelected {
                    Divider()
                    StatusBar()
                }
            }
        }
        .toolbar {
            if !isCleanupSelected {
                ToolbarItemGroup {
                    Button {
                        model.chooseRoots()
                    } label: {
                        Label(model.rootsTitle, systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                    .help(model.roots.map { $0.path(percentEncoded: false) }.joined(separator: "\n"))
                    .disabled(model.isBusy)

                    if model.isBusy {
                        Button("Stop", systemImage: "stop.fill") { model.cancelScan() }
                    } else {
                        Button("Scan", systemImage: "magnifyingglass") { model.startScan() }
                    }
                }
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.lastError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFullDiskAccess()
        }
    }

    private var isCleanupSelected: Bool {
        if case .cleanup = model.selection { return true }
        return false
    }

    private func badge(for item: SidebarItem) -> Text? {
        let text: String? = switch item {
        case .largeFiles: model.largeFiles.isEmpty ? nil : model.largeFiles.count.formatted()
        case .duplicates: model.duplicateGroups.isEmpty ? nil : model.duplicateGroups.count.formatted()
        case .cleanup(let category): model.cleanupReport(for: category).map { ByteSize.format($0.totalSize) }
        }
        return text.map { Text($0) }
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access is off").fontWeight(.semibold)
                Text("Mail, Messages, Safari, app containers and some Library folders can't be scanned, so results may be incomplete.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { FullDiskAccess.openSettings() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .idle:
                Text(model.summary ?? "Choose folders and click Scan.")
            case .scanning(let count):
                ProgressView().controlSize(.small)
                Text("Scanning… \(count.formatted()) files")
            case .comparing(let label, let fraction):
                if let fraction {
                    ProgressView(value: fraction).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(label)
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }
}
