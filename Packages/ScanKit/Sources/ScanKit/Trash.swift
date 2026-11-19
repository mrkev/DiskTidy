import Foundation

public enum Trash {
    public struct Outcome: Sendable {
        public var trashed: [URL] = []
        public var failures: [URL: String] = [:]
    }

    /// Moves files to the Trash so the user can restore them. Never deletes outright.
    public static func moveToTrash(_ urls: [URL]) -> Outcome {
        var outcome = Outcome()
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                outcome.trashed.append(url)
            } catch {
                outcome.failures[url] = error.localizedDescription
            }
        }
        return outcome
    }
}
