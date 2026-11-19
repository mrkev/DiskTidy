import CoreServices
import Foundation

/// Which apps are installed, used to decide whether app data is a leftover.
public struct InstalledApps: Sendable {
    /// Lowercased bundle identifier -> display name.
    private let names: [String: String]
    /// Lowercased first two components of every installed bundle ID ("com.google").
    private let vendors: Set<String>
    private let useLaunchServices: Bool

    public init(bundleIdentifiers: [String: String], useLaunchServices: Bool = false) {
        var names: [String: String] = [:]
        for (id, name) in bundleIdentifiers { names[id.lowercased()] = name }
        self.names = names
        self.vendors = Set(bundleIdentifiers.keys.map(Self.vendor(of:)))
        self.useLaunchServices = useLaunchServices
    }

    /// Finds apps in the standard application folders (two levels deep, for
    /// vendor subfolders) and also consults LaunchServices for apps elsewhere.
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> InstalledApps {
        let folders = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            home.appending(path: "Applications"),
        ]
        var found: [String: String] = [:]
        func visit(_ folder: URL, depth: Int) {
            let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                if child.pathExtension == "app" {
                    if let id = Bundle(url: child)?.bundleIdentifier {
                        found[id] = child.deletingPathExtension().lastPathComponent
                    }
                } else if depth > 0, (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    visit(child, depth: depth - 1)
                }
            }
        }
        for folder in folders { visit(folder, depth: 1) }
        return InstalledApps(bundleIdentifiers: found, useLaunchServices: true)
    }

    /// True if this bundle ID, or any app from the same vendor, is installed.
    /// The vendor rule is deliberately conservative: helper and updater IDs
    /// (com.google.Keystone) often differ from the app's (com.google.Chrome).
    public func isInstalled(bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        if names[id] != nil || vendors.contains(Self.vendor(of: id)) { return true }
        return useLaunchServices && !Self.launchServicesURLs(for: bundleID).isEmpty
    }

    public func displayName(forBundleID bundleID: String) -> String? {
        if let name = names[bundleID.lowercased()] { return name }
        guard useLaunchServices, let url = Self.launchServicesURLs(for: bundleID).first else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    static func vendor(of bundleID: String) -> String {
        bundleID.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    private static func launchServicesURLs(for bundleID: String) -> [URL] {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?
            .takeRetainedValue() as? [URL]
        else { return [] }
        // LaunchServices can remember apps that have since been deleted.
        return urls.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}
