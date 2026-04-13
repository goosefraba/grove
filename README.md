# Grove

Grove is a native macOS file browser built with Swift and AppKit.

It aims to feel fast, direct, and keyboard-friendly rather than acting as a Finder clone or a cross-platform shell wrapped for macOS.

## What It Does

- Browse files with native macOS windows and tabs
- Navigate with list, column, icon, and gallery views
- Use an optional preview pane and dual-pane layout
- Work with favorites, mounted volumes, breadcrumbs, and Go to Folder
- Filter the current folder and run deeper search from list view
- Copy, move, duplicate, rename, batch rename, compress, and extract files
- Use Quick Look, drag and drop, context menus, and standard keyboard shortcuts
- Restore workspace state across launches

## Requirements

- macOS 14.0 or newer
- Xcode 15 or newer

## Build And Run

From the repository root:

```bash
./run.sh
```

That builds Grove into repo-local `.derivedData` and launches the resulting app bundle.

## Install Locally

To build and install Grove as a local macOS app:

```bash
./install.sh
```

By default this installs to `~/Applications/Grove.app`.

To install into `/Applications` instead:

```bash
INSTALL_DIR=/Applications ./install.sh
```

## Manual Build

```bash
xcodebuild -project Grove.xcodeproj -scheme Grove -configuration Debug -derivedDataPath .derivedData build
open .derivedData/Build/Products/Debug/Grove.app
```

## Project Structure

- `Grove/App`: app entry point and application lifecycle
- `Grove/Controllers`: AppKit window and view controllers
- `Grove/Views`: SwiftUI and AppKit view components
- `Grove/Models`: shared view and navigation models
- `Grove/Services`: file operations, search, watchers, thumbnails, and helpers

## Project Tracking

- Roadmap: [BACKLOG.md](BACKLOG.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Release process: [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, workflow, and pull request expectations.

## Distribution

Grove is currently set up for direct distribution and source builds. A notarized release pipeline is not included yet.

## License

Grove is available under the MIT License. See [LICENSE](LICENSE).
