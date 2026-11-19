import ScanKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedExclusions = Set<String>()

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Toggle("Include hidden files", isOn: $model.settings.includeHidden)
                Toggle("Show apps and other packages as single items", isOn: $model.settings.treatPackagesAsItems)
                Toggle(isOn: $model.settings.groupDeveloperFolders) {
                    Text("Show developer folders as single items")
                    Text(ScanOptions.developerFolderNames.sorted().joined(separator: ", "))
                }
                Picker("Ignore duplicates smaller than", selection: $model.settings.duplicateMinimumSize) {
                    ForEach(ScanSettings.duplicateSizeChoices, id: \.self) { Text(ByteSize.format($0)).tag($0) }
                }
            } footer: {
                Text("Changes apply to the next scan.").foregroundStyle(.secondary)
            }

            Section("Excluded Folders") {
                List(model.settings.excludedFolders, id: \.self, selection: $selectedExclusions) { path in
                    Label((path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                }
                .frame(minHeight: 100)
                .overlay {
                    if model.settings.excludedFolders.isEmpty {
                        Text("No excluded folders").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Add…") { model.addExcludedFolders() }
                    Button("Remove") {
                        model.settings.excludedFolders.removeAll { selectedExclusions.contains($0) }
                        selectedExclusions.removeAll()
                    }
                    .disabled(selectedExclusions.isEmpty)
                    Spacer()
                    Text("Always skipped: /System, /Volumes and other system locations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
