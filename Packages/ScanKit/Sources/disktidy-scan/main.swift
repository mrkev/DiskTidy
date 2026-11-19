import Foundation
import ScanKit

let usage = """
    usage: disktidy-scan large [path ...] [--min SIZE] [--top N]
           disktidy-scan dupes [path ...] [--min SIZE]

    Paths default to the current directory. SIZE examples: 500KB, 100MB, 1.5GB.
    Defaults: large --min 100MB --top 50; dupes --min 1MB.
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

let clearLine = "\r\u{1B}[K"

/// Live progress, shown only when stderr is a terminal.
func printProgress(_ text: String) {
    guard isatty(STDERR_FILENO) != 0 else { return }
    printErr(clearLine + text)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["large", "dupes"].contains(command) else {
    print(usage)
    exit(arguments.isEmpty ? 0 : 2)
}
arguments.removeFirst()

var paths: [String] = []
var minimumSize: Int64?
var top = 50
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

let scan = try await FileScanner.scan(roots: roots) { progress in
    printProgress("Scanning… \(progress.filesVisited) files")
}
printProgress("")
printErr(String(
    format: "Scanned %d files (%@) in %.1fs, %d unreadable\n\n",
    scan.files.count, ByteSize.format(scan.totalAllocatedSize), scan.elapsed, scan.errorCount
))

switch command {
case "large":
    let threshold = minimumSize ?? 100_000_000
    let files = LargeFileFinder.find(in: scan.files, minimumSize: threshold, limit: top)
    if files.isEmpty { print("No files of \(ByteSize.format(threshold)) or more.") }
    for file in files {
        print("\(pad(ByteSize.format(file.allocatedSize), 10))  \(file.path)")
    }

default:
    let options = DuplicateOptions(minimumSize: minimumSize ?? 1_000_000)
    let groups = try await DuplicateFinder.find(in: scan.files, options: options) { progress in
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
