import Foundation
import Testing
@testable import ScanKit

@Suite struct CleanupTests {
    let noApps = InstalledApps(bundleIdentifiers: [:])

    @Test func cachesUseAppNamesWhenKnown() async throws {
        let home = try TempDir()
        try home.write("Library/Caches/com.example.Editor/blob", bytes(1, count: 30_000))
        try home.write("Library/Caches/SomeTool/blob", bytes(2, count: 10_000))
        try home.write("Library/Logs/thing.log", bytes(3, count: 1_000))
        try home.write(".npm/_cacache/index", bytes(4, count: 2_000))

        let apps = InstalledApps(bundleIdentifiers: ["com.example.Editor": "Editor"])
        let report = await CleanupScanner.scan(.caches, context: CleanupContext(home: home.url, installedApps: apps))

        let appCaches = try #require(report.groups.first { $0.id == "app-caches" })
        #expect(appCaches.items.map(\.title) == ["Editor", "SomeTool"])  // largest first
        #expect(appCaches.items.first?.detail == "com.example.Editor")
        #expect(report.groups.first { $0.id == "logs" }?.items.count == 1)
        #expect(report.groups.first { $0.id == "package-managers" }?.items.map(\.title) == ["npm"])
    }

    @Test func developerItems() async throws {
        let home = try TempDir()
        let dev = "Library/Developer"
        try home.write("\(dev)/Xcode/DerivedData/MyApp-abcdefghijklmnopqrstuvwxyzab/Build/x", bytes(1, count: 5_000))
        try home.write("\(dev)/Xcode/iOS DeviceSupport/17.2 (21C62)/Symbols/x", bytes(1, count: 5_000))
        let device: [String: Any] = [
            "UDID": "1234-ABCD", "name": "iPhone 15", "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-17-2",
        ]
        try home.write(
            "\(dev)/CoreSimulator/Devices/1234-ABCD/device.plist",
            PropertyListSerialization.data(fromPropertyList: device, format: .xml, options: 0)
        )
        try home.write("\(dev)/CoreSimulator/Devices/1234-ABCD/data/x", bytes(1, count: 5_000))

        let report = await CleanupScanner.scan(.developer, context: CleanupContext(home: home.url, installedApps: noApps))

        #expect(report.groups.first { $0.id == "derived-data" }?.items.first?.title == "MyApp")
        #expect(report.groups.first { $0.id == "device-support" }?.items.first?.detail == "iOS")
        let simulator = try #require(report.groups.first { $0.id == "simulators" }?.items.first)
        #expect(simulator.title == "iPhone 15")
        #expect(simulator.detail == "iOS 17.2")
        #expect(simulator.action == .deleteSimulator(udid: "1234-ABCD"))
    }

    @Test func downloadsHaveDates() async throws {
        let home = try TempDir()
        try home.write("Downloads/installer.dmg", bytes(1, count: 5_000))
        try home.write("Downloads/.DS_Store", bytes(1, count: 100))

        let report = await CleanupScanner.scan(.downloads, context: CleanupContext(home: home.url, installedApps: noApps))
        let item = try #require(report.items.first)
        #expect(report.items.count == 1)
        #expect(item.title == "installer.dmg")
        #expect(item.date != nil)
    }

    @Test func leftoversSkipInstalledVendorsAndApple() async throws {
        let home = try TempDir()
        try home.write("Library/Preferences/com.gone.App.plist", bytes(1, count: 100))
        try home.write("Library/Preferences/com.apple.finder.plist", bytes(1, count: 100))
        try home.write("Library/Preferences/com.vendor.Helper.plist", bytes(1, count: 100))
        try home.write("Library/Preferences/loginwindow.plist", bytes(1, count: 100))
        try home.write("Library/Application Support/com.gone.App/data", bytes(1, count: 100))
        try home.write("Library/Application Support/Some App/data", bytes(1, count: 100))
        try home.write("Library/Containers/com.gone.App/data", bytes(1, count: 100))

        let apps = InstalledApps(bundleIdentifiers: ["com.vendor.MainApp": "Main App"])
        let report = await CleanupScanner.scan(.leftovers, context: CleanupContext(home: home.url, installedApps: apps))

        let titles = Set(report.items.map(\.title))
        #expect(titles == ["com.gone.App.plist", "com.gone.App"])
        #expect(report.items.allSatisfy { $0.detail == "com.gone.App" })
        // Containers are only examined with Full Disk Access.
        #expect(!report.groups.contains { $0.title == "Containers" })
    }

    @Test(arguments: [
        ("com.foo.Bar.plist", "com.foo.Bar"),
        ("com.foo.Bar.savedState", "com.foo.Bar"),
        ("ABCDE12345.com.foo.Bar", "com.foo.Bar"),
        ("ABCDE12345.group.com.foo.shared", "com.foo.shared"),
        ("group.com.foo.shared", "com.foo.shared"),
        ("Google", nil),
        ("com.foo", nil),
    ] as [(String, String?)])
    func bundleIdentifierExtraction(name: String, expected: String?) {
        #expect(CleanupScanner.bundleIdentifier(fromItemName: name) == expected)
    }

    @Test func reportRemovingDropsEmptyGroups() async throws {
        let home = try TempDir()
        let file = try home.write("Downloads/a.zip", bytes(1, count: 5_000))
        let report = await CleanupScanner.scan(.downloads, context: CleanupContext(home: home.url, installedApps: noApps))
        #expect(report.items.count == 1)
        #expect(report.removing([report.items[0].url]).groups.isEmpty)
        _ = file
    }

    @Test func directorySizeMeasuresFilesAndTrees() async throws {
        let dir = try TempDir()
        let file = try dir.write("one.bin", bytes(1, count: 10_000))
        try dir.write("tree/a", bytes(1, count: 1_000))
        try dir.write("tree/sub/b", bytes(1, count: 2_000))

        let sizes = await DirectorySize.measure([file, dir.url.appending(path: "tree"), dir.url.appending(path: "missing")])
        #expect(sizes[0].logicalSize == 10_000)
        #expect(sizes[1].logicalSize == 3_000)
        #expect(sizes[1].fileCount == 2)
        #expect(sizes[2].errorCount == 1)
    }
}
