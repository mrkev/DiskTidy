import Foundation

public enum CleanupScanner {
    /// Lists cleanup candidates for a category and measures them. Never modifies anything.
    public static func scan(_ category: CleanupCategory, context: CleanupContext) async -> CleanupReport {
        let specs: [GroupSpec] = switch category {
        case .caches: caches(context)
        case .developer: developer(context)
        case .downloads: downloads(context)
        case .leftovers: leftovers(context)
        }

        let candidates = specs.flatMap(\.candidates)
        let sizes = await DirectorySize.measure(candidates.map(\.url))
        var sizeByURL: [URL: TreeSize] = [:]
        for (candidate, size) in zip(candidates, sizes) { sizeByURL[candidate.url] = size }

        let groups = specs.compactMap { spec -> CleanupGroup? in
            let items = spec.candidates.compactMap { candidate -> CleanupItem? in
                guard let size = sizeByURL[candidate.url], size.allocatedSize > 0 else { return nil }
                return CleanupItem(
                    url: candidate.url,
                    title: candidate.title,
                    detail: candidate.detail,
                    allocatedSize: size.allocatedSize,
                    fileCount: size.fileCount,
                    date: candidate.date ?? size.newestModification,
                    action: candidate.action
                )
            }
            guard !items.isEmpty else { return nil }
            return CleanupGroup(
                id: spec.id,
                title: spec.title,
                note: spec.note,
                items: items.sorted { $0.allocatedSize > $1.allocatedSize }
            )
        }
        return CleanupReport(category: category, groups: groups)
    }

    // MARK: - Categories

    static func caches(_ context: CleanupContext) -> [GroupSpec] {
        let home = context.home
        let apps = context.installedApps

        func appNamed(_ url: URL) -> Candidate {
            let name = url.lastPathComponent
            if looksLikeBundleID(name), let app = apps.displayName(forBundleID: name) {
                return Candidate(url: url, title: app, detail: name)
            }
            return Candidate(url: url, title: name)
        }

        var packageManagers: [Candidate] = [
            (".npm/_cacache", "npm"),
            (".yarn/berry/cache", "Yarn"),
            (".gradle/caches", "Gradle"),
            (".m2/repository", "Maven"),
            (".cargo/registry", "Cargo registry"),
            (".cocoapods/repos", "CocoaPods specs"),
        ].compactMap { relative, title in
            let url = home.appending(path: relative)
            return exists(url) ? Candidate(url: url, title: title, detail: "~/" + relative) : nil
        }
        packageManagers += children(of: home.appending(path: ".cache")).map {
            Candidate(url: $0, title: $0.lastPathComponent, detail: "~/.cache/" + $0.lastPathComponent)
        }

        return [
            GroupSpec(
                id: "app-caches",
                title: "App Caches",
                note: "~/Library/Caches",
                candidates: children(of: home.appending(path: "Library/Caches")).map(appNamed)
            ),
            GroupSpec(
                id: "logs",
                title: "Logs",
                note: "~/Library/Logs",
                candidates: children(of: home.appending(path: "Library/Logs")).map(appNamed)
            ),
            GroupSpec(
                id: "package-managers",
                title: "Package Manager Caches",
                note: "Downloaded again on the next install.",
                candidates: packageManagers
            ),
        ]
    }

    static func developer(_ context: CleanupContext) -> [GroupSpec] {
        let developer = context.home.appending(path: "Library/Developer")
        let xcode = developer.appending(path: "Xcode")

        let derivedData = children(of: xcode.appending(path: "DerivedData")).map { url in
            let info = plist(url.appending(path: "info.plist"))
            let workspace = (info?["WorkspacePath"] as? String).map { ($0 as NSString).abbreviatingWithTildeInPath }
            return Candidate(url: url, title: derivedDataTitle(url.lastPathComponent), detail: workspace)
        }

        let archives = children(of: xcode.appending(path: "Archives"))
            .flatMap { children(of: $0) }
            .filter { $0.pathExtension == "xcarchive" }
            .map { url in
                let info = plist(url.appending(path: "Info.plist"))
                let properties = info?["ApplicationProperties"] as? [String: Any]
                let version = [
                    properties?["CFBundleShortVersionString"] as? String,
                    (properties?["CFBundleVersion"] as? String).map { "(\($0))" },
                ].compactMap { $0 }.joined(separator: " ")
                return Candidate(
                    url: url,
                    title: info?["Name"] as? String ?? url.deletingPathExtension().lastPathComponent,
                    detail: version.isEmpty ? nil : "Version \(version)",
                    date: info?["CreationDate"] as? Date
                )
            }

        let deviceSupport = ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].flatMap { (platform: String) in
            children(of: xcode.appending(path: "\(platform) DeviceSupport")).map {
                Candidate(url: $0, title: $0.lastPathComponent, detail: platform)
            }
        }

        let simulators = children(of: developer.appending(path: "CoreSimulator/Devices")).compactMap { url -> Candidate? in
            guard let device = plist(url.appending(path: "device.plist")),
                  let udid = device["UDID"] as? String
            else { return nil }
            return Candidate(
                url: url,
                title: device["name"] as? String ?? udid,
                detail: (device["runtime"] as? String).map(runtimeName),
                action: .deleteSimulator(udid: udid)
            )
        }

        let other: [Candidate] = [
            ("CoreSimulator/Caches", "Simulator caches"),
            ("Xcode/UserData/Previews", "SwiftUI preview simulators"),
            ("XCTestDevices", "Test simulators"),
        ].compactMap { relative, title in
            let url = developer.appending(path: relative)
            return exists(url) ? Candidate(url: url, title: title, detail: "~/Library/Developer/" + relative) : nil
        }

        return [
            GroupSpec(id: "derived-data", title: "DerivedData", note: "Xcode rebuilds these on the next build.", candidates: derivedData),
            GroupSpec(id: "archives", title: "Archives", note: "Needed to symbolicate crash reports for shipped builds.", candidates: archives),
            GroupSpec(id: "device-support", title: "Device Support", note: "Recreated when a device with that OS version is connected.", candidates: deviceSupport),
            GroupSpec(id: "simulators", title: "Simulators", note: "Deleted with simctl, along with their apps and data.", candidates: simulators),
            GroupSpec(id: "simulator-other", title: "Simulator Data", note: nil, candidates: other),
        ]
    }

    static func downloads(_ context: CleanupContext) -> [GroupSpec] {
        let folder = context.home.appending(path: "Downloads")
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let items = children(of: folder, keys: keys).map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return Candidate(
                url: url,
                title: url.lastPathComponent,
                date: values?.addedToDirectoryDate ?? values?.contentModificationDate
            )
        }
        return [GroupSpec(id: "downloads", title: "Downloads", note: "~/Downloads", candidates: items)]
    }

    static func leftovers(_ context: CleanupContext) -> [GroupSpec] {
        let library = context.home.appending(path: "Library")
        var locations: [(path: String, title: String)] = [
            ("Application Support", "Application Support"),
            ("Caches", "Caches"),
            ("Preferences", "Preferences"),
            ("Saved Application State", "Saved Application State"),
            ("Logs", "Logs"),
            ("HTTPStorages", "HTTP Storage"),
            ("WebKit", "WebKit Data"),
            ("LaunchAgents", "Launch Agents"),
        ]
        if context.includeAppContainers {
            locations += [("Containers", "Containers"), ("Group Containers", "Group Containers")]
        }

        return locations.map { location in
            let candidates = children(of: library.appending(path: location.path)).compactMap { url -> Candidate? in
                guard let id = bundleIdentifier(fromItemName: url.lastPathComponent),
                      !id.lowercased().hasPrefix("com.apple."),
                      !context.installedApps.isInstalled(bundleID: id)
                else { return nil }
                let title = url.lastPathComponent
                return Candidate(url: url, title: title, detail: title == id ? nil : id)
            }
            let warning = location.path == "Application Support" ? " · May include saved games or documents." : ""
            return GroupSpec(
                id: "leftovers-\(location.path)",
                title: location.title,
                note: "~/Library/" + location.path + warning,
                candidates: candidates
            )
        }
    }

    // MARK: - Helpers

    struct Candidate {
        var url: URL
        var title: String
        var detail: String? = nil
        var date: Date? = nil
        var action = CleanupAction.moveToTrash
    }

    struct GroupSpec {
        var id: String
        var title: String
        var note: String?
        var candidates: [Candidate]
    }

    private static let ignoredNames: Set<String> = [".DS_Store", ".localized"]

    static func children(of folder: URL, keys: Set<URLResourceKey> = []) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys)
        )) ?? []
        return urls.filter { !ignoredNames.contains($0.lastPathComponent) }
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static func looksLikeBundleID(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}/) != nil
    }

    /// "com.foo.App.plist" -> "com.foo.App", "ABCDE12345.group.com.foo" -> "com.foo".
    /// Nil for names that aren't reverse-DNS identifiers.
    static func bundleIdentifier(fromItemName name: String) -> String? {
        var id = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(suffix) {
            id.removeLast(suffix.count)
        }
        if let match = id.prefixMatch(of: /[A-Z0-9]{10}\./) { id.removeSubrange(match.range) }
        if id.hasPrefix("group.") { id.removeFirst("group.".count) }
        return looksLikeBundleID(id) ? id : nil
    }

    /// "MyApp-abcdefghijklmnopqrstuvwxyzab" -> "MyApp"
    static func derivedDataTitle(_ folderName: String) -> String {
        folderName.replacing(/-[a-z]{28}$/, with: "")
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-17-2" -> "iOS 17.2"
    static func runtimeName(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard let platform = parts.first, parts.count > 1 else { return String(last) }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }
}
