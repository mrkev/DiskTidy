# DiskTidy

macOS disk cleanup utility: finds large files and duplicate files, moves selected ones to the Trash.
Native SwiftUI, macOS 15+, distributed outside the Mac App Store (no sandbox, hardened runtime, Developer ID later).

## Layout
- `DiskTidy.xcodeproj` – thin app target. Uses Xcode 16+ synchronized folders: files added under `DiskTidy/` are picked up automatically, so don't edit `project.pbxproj` to add sources.
- `DiskTidy/` – SwiftUI app. `AppModel` (@Observable, MainActor) owns scan state; views in `Views/`.
  App target defaults to MainActor isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), Swift 6.
- `Packages/ScanKit/` – all scanning logic, no UI. Nonisolated, so its async functions run off the main actor.
  - `FileScanner` – walks folders (lstat, no symlink following, skips package contents and `/System`, `/Volumes` etc. by default; roots/exclusions canonicalized with realpath).
  - `LargeFileFinder` – threshold + sort by allocated size, hard links collapsed.
  - `DuplicateFinder` – size buckets → head/tail SHA-256 → full SHA-256; hard links aren't dupes; APFS clones counted once for "reclaimable".
  - `CloneInspector` – getattrlist ATTR_CMNEXT_CLONEID / EXT_FLAGS.
  - `Trash` – only ever moves to Trash, never deletes.
  - `disktidy-scan` – CLI for exercising ScanKit without the UI.

## Commands
```sh
# Package tests (Swift Testing)
cd Packages/ScanKit && swift test

# CLI
cd Packages/ScanKit && swift run -c release disktidy-scan large ~/Downloads --min 100MB --top 20
cd Packages/ScanKit && swift run -c release disktidy-scan dupes ~/Documents --min 1MB

# App
xcodebuild -project DiskTidy.xcodeproj -scheme DiskTidy -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/DiskTidy.app
```

## Notes
- Full Disk Access is tied to the code signature; keep signing stable (team J8ZU83TC57) or the grant is lost between builds.
- Sizes shown are allocated (on-disk) sizes, decimal units like Finder.
