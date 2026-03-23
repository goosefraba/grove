# Grove

Native macOS file browser built with Swift/AppKit. Targeting macOS 14+.

## Build & Run

```bash
./run.sh
```

## Architecture

- **AppKit-primary** with SwiftUI for leaf views (InspectorView)
- App lifecycle: `main.swift` → `AppDelegate` → `BrowserWindowController` → `MainSplitViewController`
- Three-pane split: Sidebar (NSOutlineView) | FileList (NSTableView) | Inspector (SwiftUI)
- File operations via `FileOperationService` singleton
- Directory watching via `DirectoryWatcher` (FSEvents)
- Icons via `ThumbnailCache` (NSCache-backed)

## Key Patterns

- All file metadata loaded via `URL.resourceValues(forKeys:)` into `FileItem` structs
- Sidebar uses `SidebarSection` enum + `SidebarItem` struct as outline view data
- Navigation history managed by `NavigationHistory` (back/forward stacks, capped at 100)
- Window controllers tracked in `AppDelegate.windowControllers` array with close-notification cleanup
- DirectoryWatcher uses `WatcherBox` weak-reference pattern to avoid use-after-free in FSEvents callback

## Distribution

Direct distribution (not App Store). No sandbox — needs full file system access.
