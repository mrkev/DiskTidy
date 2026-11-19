import SwiftUI

@main
struct DiskTidyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 780, minHeight: 480)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Folders…") { model.chooseRoots() }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
                Button("Scan") { model.startScan() }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy)
            }
        }
    }
}
