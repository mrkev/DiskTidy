import AppKit
import ScanKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .badge(badge(for: item))
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                if !model.hasFullDiskAccess {
                    FullDiskAccessBanner()
                    Divider()
                }
                Group {
                    switch model.selection ?? .largeFiles {
                    case .largeFiles: LargeFilesView()
                    case .duplicates: DuplicatesView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar()
            }
        }
        .toolbar {
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

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .largeFiles: model.largeFiles.count
        case .duplicates: model.duplicateGroups.count
        }
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
                Text("Mail, Messages, Safari and some Library folders can't be scanned, so results may be incomplete.")
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
