import Foundation
import ScanKit

let usage = """
    usage: disktidy-scan large [path ...] [--min SIZE] [--top N] [--expand]
           disktidy-scan dupes [path ...] [--min SIZE] [--expand]
           disktidy-scan cleanup caches|developer|downloads|leftovers

    Paths default to the current directory. SIZE examples: 500KB, 100MB, 1.5GB.
    Defaults: large --min 100MB --top 50; dupes --min 1MB.
    Packages (.app, …) and developer folders (node_modules, .git, …) are reported
    as single items; --expand scans inside them instead.
    """

func printErr(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

func fail(_ message: String) -> Never {
    printErr("error: \(message)\n\n\(usage)\n")
    exit(2)
}

func pad(_ text: String, _ width: Int) -> String {
    String(repeating: " ", count: max(0, width - text.count)) + text
}

/// Live progress, shown only when stderr is a terminal.
func printProgress(_ text: String) {
    guard isatty(STDERR_FILENO) != 0 else { return }
    printErr("\r\u{1B}[K" + text)
}

func describe(_ item: FileEntry) -> String {
    switch item.kind {
    case .file: item.path
    case .package: "\(item.path)/  [package, \(item.fileCount.formatted()) files]"
    case .folder: "\(item.path)/  [folder, \(item.fileCount.formatted()) files]"
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["large", "dupes", "cleanup"].contains(command) else {
    print(usage)
    exit(arguments.isEmpty ? 0 : 2)
}
arguments.removeFirst()

if command == "cleanup" {
    guard arguments.count == 1, let category = CleanupCategory(rawValue: arguments[0]) else {
        fail("cleanup needs one of: \(CleanupCategory.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    printProgress("Measuring…")
    let context = CleanupContext(installedApps: .discover())
    let report = await CleanupScanner.scan(category, context: context)
    printProgress("")
    for group in report.groups {
        print("\(group.title) — \(ByteSize.format(group.totalSize))\(group.note.map { "  (\($0))" } ?? "")")
        for item in group.items {
            let detail = item.detail.map { "  \($0)" } ?? ""
            print("\(pad(ByteSize.format(item.allocatedSize), 12))  \(item.title)\(detail)")
        }
        print()
    }
    print("\(category.title): \(ByteSize.format(report.totalSize)) in \(report.items.count) items")
    exit(0)
}

var paths: [String] = []
var minimumSize: Int64?
var top = 50
var expand = false
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--min":
        index += 1
        guard index < arguments.count, let size = ByteSize.parse(arguments[index]) else { fail("--min needs a size") }
        minimumSize = size
    case "--top":
        index += 1
        guard index < arguments.count, let n = Int(arguments[index]), n > 0 else { fail("--top needs a positive number") }
        top = n
    case "--expand":
        expand = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        if argument.hasPrefix("-") { fail("unknown option \(argument)") }
        paths.append(argument)
    }
    index += 1
}
if paths.isEmpty { paths = [FileManager.default.currentDirectoryPath] }
let roots = paths.map { URL(fileURLWithPath: $0) }
let threshold = minimumSize ?? (command == "large" ? 100_000_000 : 1_000_000)

let options = ScanOptions(
    treatPackagesAsItems: !expand,
    groupedFolderNames: expand ? [] : ScanOptions.developerFolderNames,
    minimumRetainedSize: threshold
)
let scan = try await FileScanner.scan(roots: roots, options: options) { progress in
    printProgress("Scanning… \(progress.filesVisited) files")
}
printProgress("")
printErr(String(
    format: "Scanned %d files (%@) in %.1fs, %d unreadable\n\n",
    scan.fileCount, ByteSize.format(scan.totalAllocatedSize), scan.elapsed, scan.errorCount
))

switch command {
case "large":
    let items = LargeFileFinder.find(in: scan.items, minimumSize: threshold, limit: top)
    if items.isEmpty { print("Nothing of \(ByteSize.format(threshold)) or more.") }
    for item in items {
        print("\(pad(ByteSize.format(item.allocatedSize), 10))  \(describe(item))")
    }

default:
    let groups = try await DuplicateFinder.find(in: scan.items, options: DuplicateOptions(minimumSize: threshold)) { progress in
        let label = progress.stage == .quickPass ? "Comparing" : "Verifying"
        printProgress("\(label)… \(progress.completed)/\(progress.total)")
    }
    printProgress("")
    if groups.isEmpty { print("No duplicates found.") }
    for group in groups {
        let clones = group.sharesStorage ? "  (some copies are APFS clones)" : ""
        print("\(group.files.count) copies × \(ByteSize.format(group.fileSize)), reclaim \(ByteSize.format(group.reclaimableBytes))\(clones)")
        for file in group.files { print("    \(file.path)") }
        print()
    }
    let total = groups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
    print("\(groups.count) duplicate groups, \(ByteSize.format(total)) reclaimable")
}
