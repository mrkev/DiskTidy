import Foundation

public struct CleanupOutcome: Sendable {
    public var removed: [URL] = []
    public var failures: [URL: String] = [:]
}

public enum Trash {
    /// Moves files to the Trash so the user can restore them. Never deletes outright.
    public static func moveToTrash(_ urls: [URL]) -> CleanupOutcome {
        var outcome = CleanupOutcome()
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                outcome.removed.append(url)
            } catch {
                outcome.failures[url] = error.localizedDescription
            }
        }
        return outcome
    }
}

public enum Cleaner {
    /// Removes cleanup items: files go to the Trash, simulators are deleted with simctl.
    public static func perform(_ items: [CleanupItem]) async -> CleanupOutcome {
        await runBlocking {
            var outcome = CleanupOutcome()
            for item in items {
                switch item.action {
                case .moveToTrash:
                    let result = Trash.moveToTrash([item.url])
                    outcome.removed += result.removed
                    outcome.failures.merge(result.failures) { first, _ in first }
                case .deleteSimulator(let udid):
                    if let error = deleteSimulator(udid) {
                        outcome.failures[item.url] = error
                    } else {
                        outcome.removed.append(item.url)
                    }
                }
            }
            return outcome
        }
    }

    /// Returns an error message, or nil on success.
    private static func deleteSimulator(_ udid: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "delete", udid]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        guard process.terminationStatus != 0 else { return nil }
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "simctl exited with status \(process.terminationStatus)"
            : message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
