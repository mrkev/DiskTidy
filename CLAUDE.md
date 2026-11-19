# DiskTidy

macOS disk cleanup utility: finds large files and duplicate files, moves selected ones to the Trash.
Native SwiftUI, macOS 15+, distributed outside the Mac App Store (no sandbox, hardened runtime, Developer ID later).

## Layout
- `DiskTidy.xcodeproj` – thin app target. Uses Xcode 16+ synchronized folders: files added under `DiskTidy/` are picked up automatically, so don't edit `project.pbxproj` to add sources.
- `DiskTidy/` – SwiftUI app. `AppModel` (@Observable, MainActor) owns scan state; views in `Views/`.
  App target defaults to MainActor isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), Swift 6.
- `DiskTidy/Views/` – `LargeFilesView`, `DuplicatesView`, `CleanupView` (one per cleanup category), `SettingsView`, shared rows/confirmation in `SharedViews`.
  Settings (`ScanSettings`) persist as JSON in UserDefaults.
- `Packages/ScanKit/` – all scanning logic, no UI. Nonisolated; blocking work runs on Dispatch threads (`runBlocking`), never the cooperative pool.
  - `BulkReader` – getattrlistbulk(2) directory reader, plus tree measuring. One per thread.
  - `FileScanner` – parallel walk over all cores. Packages (`.app`, …) and developer folders (`node_modules`, `.git`, …) become single `FileEntry` items (`kind`). Only items ≥ `minimumRetainedSize` are kept; totals count everything. Roots/exclusions canonicalized with realpath.
  - `LargeFileFinder` – threshold + sort by allocated size, hard links collapsed.
  - `DuplicateFinder` – files only; size buckets → head/tail SHA-256 → full SHA-256; APFS clones counted once for "reclaimable".
  - `CloneInspector` – getattrlist ATTR_CMNEXT_CLONEID / EXT_FLAGS.
  - `Cleanup/` – `CleanupScanner` lists candidates per `CleanupCategory` (caches, developer, downloads, leftovers) and sizes them with `DirectorySize`; `InstalledApps` decides leftovers (vendor prefix + LaunchServices + Steam library); `Cleaner` trashes files and deletes simulators via `xcrun simctl`.
  - `disktidy-scan` – CLI for exercising ScanKit without the UI.

## Commands
```sh
# Package tests (Swift Testing)
cd Packages/ScanKit && swift test

# CLI
cd Packages/ScanKit && swift run -c release disktidy-scan large ~/Downloads --min 100MB --top 20
cd Packages/ScanKit && swift run -c release disktidy-scan dupes ~/Documents --min 1MB
cd Packages/ScanKit && swift run -c release disktidy-scan cleanup developer   # caches|developer|downloads|leftovers

# App
xcodebuild -project DiskTidy.xcodeproj -scheme DiskTidy -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/DiskTidy.app
```

## Notes
- Full Disk Access is tied to the code signature; keep signing stable (team J8ZU83TC57) or the grant is lost between builds.
- Sizes shown are allocated (on-disk) sizes, decimal units like Finder.
- Nothing is ever deleted outright except simulators (simctl); everything else goes to the Trash.
- Leftover detection must stay conservative (false positives can delete save games/documents): Apple IDs never flagged, any installed app from the same vendor protects an ID.
- Avoid `.fixedSize(horizontal: false, vertical: true)` on wrapping text in headers: it inflates the minimum height and pushes the window layout out of frame.
