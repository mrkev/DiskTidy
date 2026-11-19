import Foundation

public enum DirectorySize {
    /// Measures each path (file or folder tree) concurrently. Results are in input order.
    public static func measure(_ urls: [URL]) async -> [TreeSize] {
        guard !urls.isEmpty else { return [] }
        let paths = urls.map { $0.path(percentEncoded: false) }
        return await runBlocking {
            let slots = Slots<TreeSize>(count: paths.count, initial: TreeSize())
            DispatchQueue.concurrentPerform(iterations: paths.count) { index in
                slots[index] = BulkReader().measure(paths[index])
            }
            return slots.values
        }
    }
}

/// Fixed-size results array written from concurrent iterations.
private final class Slots<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T]

    init(count: Int, initial: T) {
        storage = Array(repeating: initial, count: count)
    }

    subscript(index: Int) -> T {
        get { lock.withLock { storage[index] } }
        set { lock.withLock { storage[index] = newValue } }
    }

    var values: [T] { lock.withLock { storage } }
}
